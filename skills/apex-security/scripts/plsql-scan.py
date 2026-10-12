#!/usr/bin/env python3
"""plsql-scan — apex-security's package scan: dynamic SQL and AUTHID in the write path.

Usage: python3 plsql-scan.py [--app <alias>] [--task <id>] <file-or-dir>...
       (.sql .pks .pkb .pls files, and the ```sql / ```plsql blocks of .apx files)

Checks (criteria.md), on the code with comments and string literals masked out:
  SEC-SQL-BIND  every EXECUTE IMMEDIATE, OPEN … FOR <text>, DBMS_SQL.PARSE and
                APEX_EXEC.OPEN_QUERY_CONTEXT(p_sql_query =>) runs a text that is
                - literal, or built only from literals and DBMS_ASSERT calls → held;
                - a value concatenated in (||) → FAIL, review comment or not: bind it;
                - not traceable here (a parameter, a function, built elsewhere) → FAIL unless
                  `-- dynamic sql review: <reason>` sits on its line or the line above.
                Variables are traced through their `:=` assignments in the same file.
  advisory      SEC-AUTHID — a package spec without an explicit AUTHID clause

Output: a security-result (scope plsql) on stdout, and with --task in
<evidenceDir>/<task>/security-<alias>-plsql.json.
Exit:   0 PASS · 1 FAIL · 2 BLOCKED (nothing to scan, unreadable, outside the repo) ·
        3 UNKNOWN (a file the lexer could not follow — an unclosed literal or comment).
"""
import argparse
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "framework", "lib"))
from apx import collect  # noqa: E402
from result import Stop, context, rel, target, write  # noqa: E402

EXTS = (".sql", ".pks", ".pkb", ".pls", ".apx")
REVIEW = re.compile(r"(?i)--.*dynamic[- ]sql[- ]review:\s*\S")
SITES = [  # (pattern up to the SQL text, what ends the text at depth 0)
    (re.compile(r"(?i)\bexecute\s+immediate\b"), r"\b(?:using|into|returning|bulk)\b|;"),
    (re.compile(r"(?i)\bopen\s+\w+\s+for\b(?!\s+(?:select|with)\b)"), r"\busing\b|;"),
    (re.compile(r"(?i)\bdbms_sql\s*\.\s*parse\s*\(\s*[\w.]+\s*,"), r",|\)"),
    (re.compile(r"(?i)\bapex_exec\s*\.\s*open_query_context\s*\([^;]*?\bp_sql_query\s*=>"), r",|\)"),
]
ASSERT = re.compile(r"(?i)^(?:sys\s*\.\s*)?dbms_assert\s*\.\s*\w+\s*\(")
LITERAL = re.compile(r"^'\s*'$")
IDENT = re.compile(r"^[A-Za-z][\w$#]*(?:\.[A-Za-z][\w$#]*)?$")
SPEC = re.compile(r"(?is)\bcreate\s+(?:or\s+replace\s+)?(?:(?:non)?editionable\s+)?package\s+(?!body\b)([\w$#.\"]+)(.*?)\b(?:as|is)\b")


class LexError(Exception):
    pass


def mask(text):
    """The text with comments blanked and literal contents blanked (quotes kept, a q'[…]'
    becomes '   '); same length, newlines kept, so offsets map to the original lines."""
    out, i, n = list(text), 0, len(text)

    def blank(a, b):
        for k in range(a, b):
            if out[k] != "\n":
                out[k] = " "
    while i < n:
        c, two = text[i], text[i:i + 2]
        if two == "--":
            j = text.find("\n", i)
            j = n if j < 0 else j
            blank(i, j)
            i = j
        elif two == "/*":
            j = text.find("*/", i + 2)
            if j < 0:
                raise LexError(f"line {text.count(chr(10), 0, i) + 1}: unclosed comment")
            blank(i, j + 2)
            i = j + 2
        elif c in "qQ" and text[i + 1:i + 2] == "'" and (i == 0 or not (text[i - 1].isalnum() or text[i - 1] == "_")):
            close = {"[": "]", "(": ")", "{": "}", "<": ">"}.get(text[i + 2:i + 3], text[i + 2:i + 3])
            j = text.find(close + "'", i + 3)
            if j < 0:
                raise LexError(f"line {text.count(chr(10), 0, i) + 1}: unclosed q-quoted literal")
            blank(i, j + 2)
            out[i + 1], out[j + 1] = "'", "'"
            i = j + 2
        elif c == "'":
            j = i + 1
            while True:
                j = text.find("'", j)
                if j < 0:
                    raise LexError(f"line {text.count(chr(10), 0, i) + 1}: unclosed literal")
                if text[j + 1:j + 2] == "'":
                    j += 2
                    continue
                break
            blank(i + 1, j)
            i = j + 1
        else:
            i += 1
    return "".join(out)


def split_top(expr, sep):
    parts, depth, cur, i = [], 0, "", 0
    while i < len(expr):
        if expr[i] in "(":
            depth += 1
        elif expr[i] == ")":
            depth -= 1
        if depth == 0 and expr.startswith(sep, i):
            parts.append(cur)
            cur, i = "", i + len(sep)
            continue
        cur += expr[i]
        i += 1
    return parts + [cur]


def text_at(code, start, stop):
    """The SQL-text expression from start to the first `stop` at parenthesis depth 0."""
    depth, rx = 0, re.compile(stop, re.I)
    for k in range(start, len(code)):
        if code[k] == "(":
            depth += 1
        elif code[k] == ")":
            if depth == 0 and rx.match(code, k):
                return code[start:k]
            depth -= 1
        elif depth == 0 and rx.match(code, k):
            return code[start:k]
    return code[start:]


def wraps(expr):
    """True when the first '(' closes at the last character: (a || b), not (a) || (b)."""
    depth = 0
    for k, ch in enumerate(expr):
        depth += ch == "("
        depth -= ch == ")"
        if depth == 0 and k < len(expr) - 1:
            return False
    return True


def judge(expr, code, seen=()):
    """'safe' · 'concat' (a value concatenated in) · 'untraced'."""
    expr = expr.strip()
    while expr.startswith("(") and expr.endswith(")") and wraps(expr):
        expr = expr[1:-1].strip()
    ops = [o.strip() for o in split_top(expr, "||")]
    if len(ops) == 1:
        o = ops[0]
        if LITERAL.match(o) or ASSERT.match(o):
            return "safe"
        if IDENT.match(o) and o.lower() not in seen:
            # `x := …;`, and a declaration `x [CONSTANT] VARCHAR2(n) := | DEFAULT …;`
            decl = r"(?:\s+(?:constant\s+)?[\w.$#%]+(?:\s*\([^)]*\))?)?\s*(?::=|\bdefault\b)"
            values = [m.group(1) for m in re.finditer(rf"(?i)\b{re.escape(o)}\b{decl}\s*([^;]*);", code)]
            if values:
                verdicts = [judge(v, code, seen + (o.lower(),)) for v in values]
                return "concat" if "concat" in verdicts else "untraced" if "untraced" in verdicts else "safe"
        return "untraced"
    return "safe" if all(judge(o, code, seen) == "safe" for o in ops) else "concat"


def blocks(path, text):
    """(first line, code) of each piece of SQL or PL/SQL in a file."""
    if not path.lower().endswith(".apx"):
        return [(1, text)]
    out, lines, cur = [], text.split("\n"), None
    for no, ln in enumerate(lines, 1):
        s = ln.strip()
        if cur is None and re.match(r"(?i)^```\s*(sql|plsql)\b", s):
            cur = (no + 1, [])
        elif cur is not None and s.startswith("```"):
            out.append((cur[0], "\n".join(cur[1])))
            cur = None
        elif cur is not None:
            cur[1].append(ln)
    return out


def scan_file(path, r, add, advise):
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    for first, raw in blocks(path, text):
        code = mask(raw)
        lines = raw.split("\n")
        for rx, stop in SITES:
            for m in rx.finditer(code):
                line = code.count("\n", 0, m.start())
                verdict = judge(text_at(code, m.end(), stop), code)
                if verdict == "concat":
                    add(r, first + line, "a value concatenated into dynamic SQL: bind it (USING) or DBMS_ASSERT it")
                elif verdict == "untraced" and not any(REVIEW.search(x) for x in lines[max(0, line - 1):line + 1]):
                    add(r, first + line, "dynamic SQL whose text is not traceable here, with no `-- dynamic sql review: <reason>`")
        for m in SPEC.finditer(code):
            if not re.search(r"(?i)\bauthid\b", m.group(2)):
                advise(r, first + code.count("\n", 0, m.start()), f"package {m.group(1)} states no AUTHID")


def main(argv):
    ap = argparse.ArgumentParser(description="apex-security scan of PL/SQL packages and .apx code blocks")
    ap.add_argument("--app")
    ap.add_argument("--task")
    ap.add_argument("paths", nargs="*")
    a = ap.parse_args(argv)
    result = {"kind": "security-result", "schemaVersion": 1, "status": "UNKNOWN", "reasons": [],
              "context": context(a.task, "apex-security"), "scope": "plsql", "files": [], "unparsed": [],
              "criteria": [], "advisories": []}
    task_dir = None
    try:
        alias, task_dir, _ = target(a.app, a.task)
        if alias:
            result["app"] = {"appAlias": alias}
        try:
            files = collect(a.paths, EXTS)
        except FileNotFoundError as e:
            raise Stop("BLOCKED", "NOTHING_TO_SCAN", f"no such file or directory: {rel(str(e.args[0])) or os.path.basename(str(e.args[0]))}")
        if not a.paths or not files:
            raise Stop("BLOCKED", "NOTHING_TO_SCAN", "no .sql, .pks, .pkb, .pls or .apx file to scan")
        findings = []

        def add(r, line, detail):
            findings.append({"path": r, "line": line, "detail": detail})

        def advise(r, line, detail):
            result["advisories"].append({"id": "SEC-AUTHID", "path": r, "line": line, "detail": detail})
        for f in files:
            r = rel(f)
            if r is None:
                raise Stop("BLOCKED", "OUTSIDE_REPO", f"{os.path.basename(f)} is outside the repository: scan the repo's own source")
            result["files"].append(r)
            try:
                scan_file(f, r, add, advise)
            except LexError as e:
                result["unparsed"].append({"path": r, "detail": str(e)})
            except (OSError, UnicodeDecodeError) as e:
                raise Stop("BLOCKED", "UNREADABLE", f"{r}: {e.__class__.__name__}")
        result["criteria"] = [{"id": "SEC-SQL-BIND", "status": "FAIL" if findings else "PASS", "findings": findings}]
        n = len(files)
        if findings:
            result["status"], result["reasons"] = "FAIL", [{"code": "SECURITY_CRITERIA_FAILED", "message": f"{n} file(s) scanned; {len(findings)} dynamic SQL finding(s)"}]
        elif result["unparsed"]:
            result["status"], result["reasons"] = "UNKNOWN", [{"code": "UNPARSED", "message": "a file could not be read as SQL: its dynamic SQL was not checked - read it by hand"}]
        else:
            result["status"], result["reasons"] = "PASS", [{"code": "SECURITY_CRITERIA_HELD", "message": f"{n} file(s); no unbound dynamic SQL"}]
    except Stop as s:
        result["status"], result["reasons"] = s.status, [{"code": s.code, "message": s.message}]
    return write(result, task_dir, f"security-{result.get('app', {}).get('appAlias', 'app')}-plsql.json")


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
