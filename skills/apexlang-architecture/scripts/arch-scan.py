#!/usr/bin/env python3
"""arch-scan — the red-flag scan of references/decision-record.md, for the four flags a script
can find. The other three (RULE_OUTSIDE_PACKAGE, FOREIGN_TABLE_WRITE, FLOW_WRAPS_ONE_ENTITY)
stay the agent's review: this scan says nothing about them.

Usage: python3 arch-scan.py <file-or-dir>...
       (.apx pages, and .sql .pks .pkb .pls packages)

Red flags (each with path and line), on code with comments and string literals masked out:
  AUTOMATIC_ROW_PROCESSING  a process of one of Oracle's three Automatic Row Processing types
  DML_IN_PAGE_PROCESS       an INSERT/UPDATE/DELETE/MERGE statement in a page executeCode process
  FLOW_ISSUES_DML           a DML statement in the body of a package named *_flow
  NO_VERSION_TOKEN          an UPDATE in a package body whose WHERE names no *version* column,
                            unless `-- lost update review: <reason>` sits on its line or the one above
Advisory (never a red flag):
  THIN_WRAPPER_UNMARKED     a page executeCode process without `-- thin wrapper: <reason>`
                            (KC-4: a package call is an invokeApi process)

Output: JSON on stdout — status, files, redFlags, advisories, unparsed. Copy redFlags into the
architecture-result and record this command with its exit code as evidence.
Exit:   0 no red flag · 1 red flag(s) · 2 BLOCKED (nothing to scan, unreadable, outside the
        repo) · 3 UNKNOWN (a file that could not be read as .apx or PL/SQL, and no red flag).
"""
import json
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "framework", "lib"))
from apx import ParseError, collect, parse, prop, walk  # noqa: E402
from plsql import LexError, mask  # noqa: E402
from result import rel  # noqa: E402

EXTS = (".apx", ".sql", ".pks", ".pkb", ".pls")
ARP = {"autoRowProcessing", "formAutoRowProcessing", "interactiveGridAutoRowProcessing"}
NAME = r"[\w$#\"]+(?:\.[\w$#\"]+)?"
DML = re.compile(rf"(?i)\b(?:insert\s+into|update\s+{NAME}(?:\s+\w+)?\s+set|delete\s+(?:from\s+)?{NAME}|merge\s+into)\b")
UPDATE = re.compile(rf"(?i)\bupdate\s+{NAME}(?:\s+\w+)?\s+set\b")
BODY = re.compile(rf"(?i)\bcreate\s+(?:or\s+replace\s+)?(?:(?:non)?editionable\s+)?package\s+body\s+({NAME})")
WRAPPER = re.compile(r"(?i)--\s*thin wrapper:\s*\S")
REVIEW = re.compile(r"(?i)--.*lost[- ]update[- ]review:\s*\S")


def line_of(code, pos, first=1):
    return first + code.count("\n", 0, pos)


def scan_apx(text, r, flag, advise):
    lines = text.split("\n")
    for c in walk(parse(lines)):
        if c.kind != "process":
            continue
        kind = prop(c, "type")[0]
        if kind in ARP:
            flag("AUTOMATIC_ROW_PROCESSING", r, prop(c, "type")[1], f"process {c.name}: {kind}")
        if kind != "executeCode" or "source.plsqlCode" not in c.props:
            continue
        start = prop(c, "source.plsqlCode")[1] + 1          # the ```plsql line
        end = next((k for k in range(start, len(lines)) if lines[k].strip().startswith("```")), len(lines))
        raw = "\n".join(lines[start:end])
        code = mask(raw)
        hits = list(DML.finditer(code))
        for m in hits:
            flag("DML_IN_PAGE_PROCESS", r, line_of(code, m.start(), start + 1),
                 f"process {c.name}: a DML statement, not a package call")
        if not hits and not WRAPPER.search(raw):
            advise("THIN_WRAPPER_UNMARKED", r, c.line,
                   f"process {c.name}: executeCode without `-- thin wrapper: <reason>`; a package call is an invokeApi process")


def scan_plsql(text, r, flag):
    code, lines = mask(text), text.split("\n")
    bodies = list(BODY.finditer(code))
    for i, b in enumerate(bodies):
        stop = bodies[i + 1].start() if i + 1 < len(bodies) else len(code)
        name = b.group(1).replace('"', "").split(".")[-1].lower()
        part = code[b.end():stop]
        if name.endswith("_flow"):
            for m in DML.finditer(part):
                flag("FLOW_ISSUES_DML", r, line_of(code, b.end() + m.start()),
                     f"{name}: a DML statement; a flow calls the entity packages")
        for m in UPDATE.finditer(part):
            semi = part.find(";", m.end())
            stmt = part[m.start():semi if semi >= 0 else len(part)]
            where = re.split(r"(?i)\bwhere\b", stmt, maxsplit=1)
            no = line_of(code, b.end() + m.start())
            if len(where) == 2 and re.search(r"(?i)\w*version\w*", where[1]):
                continue
            if any(REVIEW.search(x) for x in lines[max(0, no - 2):no]):
                continue
            flag("NO_VERSION_TOKEN", r, no,
                 f"{name}: an UPDATE with no version token in its WHERE and no `-- lost update review: <reason>`")


def main(argv):
    out = {"kind": "arch-scan", "status": "UNKNOWN", "files": [], "redFlags": [], "advisories": [], "unparsed": []}

    def stop(status, message):
        out["status"], out["message"] = status, message
        return finish(out, 2)

    def flag(code, r, line, detail):
        out["redFlags"].append({"code": code, "path": r, "line": line, "detail": detail})

    def advise(code, r, line, detail):
        out["advisories"].append({"code": code, "path": r, "line": line, "detail": detail})
    try:
        files = collect(argv, EXTS)
    except FileNotFoundError as e:
        return stop("BLOCKED", f"no such file or directory: {os.path.basename(str(e.args[0]))}")
    if not argv or not files:
        return stop("BLOCKED", "no .apx, .sql, .pks, .pkb or .pls file to scan")
    for f in files:
        r = rel(f)
        if r is None:
            return stop("BLOCKED", f"{os.path.basename(f)} is outside the repository: scan the repo's own source")
        out["files"].append(r)
        try:
            with open(f, encoding="utf-8") as fh:
                text = fh.read()
            if f.lower().endswith(".apx"):
                scan_apx(text, r, flag, advise)
            else:
                scan_plsql(text, r, flag)
        except (ParseError, LexError) as e:
            out["unparsed"].append({"path": r, "detail": str(e)})
        except (OSError, UnicodeDecodeError) as e:
            return stop("BLOCKED", f"{r}: {e.__class__.__name__}")
    if out["redFlags"]:
        out["status"] = "FAIL"
        return finish(out, 1)
    if out["unparsed"]:
        out["status"] = "UNKNOWN"
        return finish(out, 3)
    out["status"] = "PASS"
    return finish(out, 0)


def finish(out, rc):
    print(json.dumps(out, indent=2))
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
