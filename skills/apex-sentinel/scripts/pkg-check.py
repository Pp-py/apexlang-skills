#!/usr/bin/env python3
"""pkg-check — apex-sentinel's Package gate: do the packages and procedures this change names exist,
compile, and declare what the page calls?

Usage: python3 pkg-check.py [--app <alias>] [--env <name>] [--task <id>] <file-or-dir>...
       (.apx files only: the SQL source is Security's plsql scope, and nothing here compares the
       database with it)

Reads the database, never writes it: SELECTs on apex_applications, ALL_OBJECTS, ALL_ERRORS,
ALL_PROCEDURES and ALL_SYNONYMS through the app's saved SQLcl connection (sqlclConnection, the
environment's when --env names one) — no DDL, no recompile; reading a `protected` environment is
allowed. Looked up in the app's parsing schema (apex_applications.owner):
  an `invokeApi` process or workflow activity's package.procedure · a `pkg.proc(p_x => ...)` call in a
  sql/plsql block of the .apx (Oracle's own packages, and a name the block declares, skipped).
Not looked up, and so never a PASS: an invoke.owner, a process on a remote database (source.location),
an invoke.type this reader does not know, a parsing schema the source changes (all UNKNOWN); a
standalone procedure (advisory PKG-STANDALONE); a REST Source operation (no PL/SQL).
Criteria (checks/package.md); a PASS needs all three:
  PKG-EXISTS       the package has a specification and, when it declares subprograms, a body; a code
                   block's call to a name that is no package of the schema is UNKNOWN
  PKG-COMPILED     both VALID, and ALL_ERRORS holds no error for them
  PKG-PROC-EXISTS  each procedure a file calls is declared in the specification

Output: a package-result on stdout, and with --task in <evidenceDir>/<task>/package-<alias>[.<env>].json.
Exit:   0 PASS · 1 FAIL · 2 BLOCKED (zero pairs to look up, no SQLcl, no connection, app not visible, a
        name that is no plain identifier, a file that is not .apx) · 3 UNKNOWN (INVALID with no visible
        error, not visible to the session's user, a synonym, an unparsed process, an answer that is
        incomplete or not understood, a query that did not finish).
Environment: SQLCL_BIN (default sql), PKG_CHECK_TIMEOUT (seconds, default 120).
"""
import argparse
import os
import re
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "framework", "lib"))
from apx import ParseError, code_blocks, collect, parse, prop, walk  # noqa: E402
from plsql import LexError, mask  # noqa: E402
from result import RE_CONN, Stop, context, rel, runtime_target, write  # noqa: E402

EXTS = (".apx",)
NAME = r"[A-Za-z][A-Za-z0-9_$#]{0,127}(?![A-Za-z0-9_$#])"      # a plain Oracle identifier, never longer than Oracle allows
ID = re.compile(NAME)
CALL = re.compile(rf"(?<![A-Za-z0-9_$#.:])({NAME})\s*\.\s*({NAME})\s*\(\s*{NAME}\s*=>")
ORACLE = re.compile(r"(?i)(?:apex_|dbms_|utl_|owa_|wwv_|json_|sdo_|ctx_)|(?:sys|htp|htf|xmltype)$")
_T = os.environ.get("PKG_CHECK_TIMEOUT", "")
TIMEOUT = int(_T) if _T.isascii() and _T.isdigit() and int(_T) > 0 else 120      # anything else: the default, never a crash
SQLCL = os.environ.get("SQLCL_BIN", "sql")
MAX_NAMES = 500                                    # an IN list holds 1000 at most (ORA-01795)
SECRET = re.compile(r"(?i)password\s*[=:]\s*\S+|[A-Za-z0-9_$#]+/[^\s/@]+@\S+|session=[0-9]{6,}")


def safe(text):
    """Text that came from the database (an ALL_ERRORS message, a synonym's target): no secret, at most 160 characters."""
    return SECRET.sub("<redacted>", re.sub(r'"[^"]*"', '"..."', text))[:160]


def declared(code, name):
    """True when a PL/SQL block declares `name` as a variable: `l_rec t_rec;` / `l_rec t_rec := ...`."""
    return re.search(rf"(?i)\b{re.escape(name)}\s+(?:constant\s+)?[A-Za-z][\w.$#%]*(?:\s*\([^)]*\))?\s*(?::=|;|\bdefault\b|\bnot\s+null\b)", code) is not None


def read_sources(files, result, pairs, owners):
    """pairs {(PKG, PROC): [(path, line, how)]} from the .apx; what cannot be looked up goes to unparsed."""
    for f in files:
        r = rel(f)
        if r is None:
            raise Stop("BLOCKED", "OUTSIDE_REPO", f"{os.path.basename(f)} is outside the repository: name the repo's own source")
        if not f.lower().endswith(".apx"):
            raise Stop("BLOCKED", "NOT_APX", f"{r}: the Package gate reads .apx files only")
        result["files"].append(r)

        def skip(c, why):
            result["unparsed"].append({"path": r, "detail": f"line {c.line}: {why}: not looked up"})
        try:
            with open(f, encoding="utf-8") as fh:
                text = fh.read()
            for c in walk(parse(text.split("\n"))):
                if c.kind == "app" and prop(c, "databaseSession.parsingSchema")[0]:      # the schema the SOURCE says it parses as
                    if ID.fullmatch(prop(c, "databaseSession.parsingSchema")[0]):
                        owners.add(prop(c, "databaseSession.parsingSchema")[0].upper())
                    else:
                        skip(c, "databaseSession.parsingSchema is no plain identifier")
                if prop(c, "type")[0] != "invokeApi":          # a page process, a workflow activity
                    continue
                kind = prop(c, "invoke.type")[0] or "plsqlPackage"
                if kind == "restSource":                       # a REST Source operation: no PL/SQL
                    continue
                names = [prop(c, "invoke.package")[0], prop(c, "invoke.procedureOrFunction")[0]]
                if kind not in ("plsqlPackage", "plsqlProcedureOrFunction"):
                    skip(c, "invoke.type is not one this gate knows")
                elif prop(c, "source.location")[0] not in ("", "localDatabase"):
                    skip(c, "the process runs on a remote database (source.location)")
                elif kind == "plsqlProcedureOrFunction" or (not names[0] and ID.fullmatch(names[1])):   # standalone: not looked up
                    result["advisories"].append({"id": "PKG-STANDALONE", "path": r, "line": c.line,
                                                 "detail": "an invokeApi process names a standalone procedure or function: not looked up"})
                elif prop(c, "invoke.owner")[0]:
                    skip(c, "the process names an owner: only the parsing schema is looked in")
                else:
                    if not all(ID.fullmatch(n) for n in names):     # never reaches a query
                        raise Stop("BLOCKED", "BAD_IDENTIFIER", f"{r}:{c.line}: an invokeApi package or procedure name is not a plain Oracle identifier")
                    pairs.setdefault(tuple(n.upper() for n in names), []).append((r, c.line, "invokeApi"))
            for first, raw in code_blocks(text):
                code = mask(raw)
                for m in CALL.finditer(code):
                    if not ORACLE.match(m.group(1)) and not declared(code, m.group(1)):
                        pairs.setdefault((m.group(1).upper(), m.group(2).upper()), []).append((r, first + code.count("\n", 0, m.start()), "code"))
        except (ParseError, LexError) as e:
            result["unparsed"].append({"path": r, "detail": safe(str(e))})
        except (OSError, UnicodeDecodeError) as e:
            raise Stop("BLOCKED", "UNREADABLE", f"{r}: {e.__class__.__name__}")


def ask(conn, app_id, names):
    """One SQLcl session, SELECTs only → {tag: [row fields]}, and the statements for the evidence."""
    own = f"(select owner from apex_applications where application_id = {int(app_id)})"
    lst = ",".join(f"'{n}'" for n in sorted(names))      # names matched ID: nothing else gets in
    q = {"ctx": f"select 'pkgchk|ctx|' || sys_context('USERENV','SESSION_USER') || '|' || nvl({own}, '-') from dual;",
         "obj": f"select 'pkgchk|obj|' || object_name || '|' || object_type || '|' || status from all_objects where owner = {own} and object_type in ('PACKAGE','PACKAGE BODY') and object_name in ({lst});",
         "err": f"select 'pkgchk|err|' || name || '|' || type || '|' || line || ':' || position || '|' || substr(replace(replace(text, chr(10), ' '), chr(13), ' '), 1, 160) from all_errors where owner = {own} and type in ('PACKAGE','PACKAGE BODY') and name in ({lst}) and attribute = 'ERROR' order by name, type, sequence;",
         "proc": f"select 'pkgchk|proc|' || object_name || '|' || procedure_name from all_procedures where owner = {own} and object_type = 'PACKAGE' and procedure_name is not null and object_name in ({lst});",
         "syn": f"select 'pkgchk|syn|' || synonym_name || '|' || table_owner || '.' || table_name || nvl2(db_link, '@' || db_link, '') from all_synonyms where owner in ({own}, 'PUBLIC') and synonym_name in ({lst});"}
    script = ("set heading off feedback off pagesize 0 verify off trimspool on define off linesize 1000\nwhenever sqlerror exit 1\n"
              + "\n".join(q.values()) + "\nselect 'pkgchk|end' from dual;\nexit\n")
    # bash, as the guard runs SQLcl (Git Bash on Windows resolves sql.exe / sql.bat); the connection NAME is
    # the only argument — the credentials stay in SQLcl's store — and the script goes in on stdin as bytes.
    cmd = [shutil.which("bash") or "bash", "-c", 'command -v "$2" >/dev/null 2>&1 || exit 127; exec "$2" -S -name "$1"', "pkg-check", conn, SQLCL]
    try:
        p = subprocess.run(cmd, input=script.encode("utf-8"), capture_output=True, timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        raise Stop("UNKNOWN", "TIMEOUT", f"SQLcl did not finish within {TIMEOUT}s")
    except OSError as e:
        raise Stop("BLOCKED", "NO_BASH", f"cannot run bash to reach SQLcl: {e.__class__.__name__}")
    if p.returncode == 127:
        raise Stop("BLOCKED", "NO_SQLCL", "SQLcl (sql) is required on PATH, or SQLCL_BIN")
    # SQLcl pads each line to the width of its widest column (seen live: the closing tag arrives as "pkgchk|end" + spaces):
    # padding is not content, so each line is stripped at both ends before it is read, and so is each field's tag
    out = [ln.strip() for ln in p.stdout.decode("utf-8", "replace").replace("\r", "").split("\n")]
    rows = [[f if i > 1 else f.strip() for i, f in enumerate(ln.split("|", 5))] for ln in out if ln.startswith("pkgchk|")]
    arity = {"ctx": 4, "obj": 5, "err": 6, "proc": 4, "syn": 4, "end": 2}      # fields a row of each tag has
    if any(len(r) < arity.get(r[1], 99) for r in rows):
        raise Stop("UNKNOWN", "BAD_ANSWER", "SQLcl answered with a row this reader does not understand: the answer is not trusted")
    tags = {}
    for r in rows:
        tags.setdefault(r[1], []).append(r)
    if "ctx" not in tags:                                   # exit code of a SQLcl that never answered: only that is kept
        raise Stop("BLOCKED", "NO_ANSWER", f"SQLcl exited {p.returncode} before answering (the connection, a privilege, or a view): apex-sync-check.sh doctor")
    if p.returncode != 0 or "end" not in tags or any(re.match(r"(ORA|SP2|SQL)-|Error (starting|report)", ln) for ln in out):
        raise Stop("UNKNOWN", "QUERY_FAILED", f"SQLcl exited {p.returncode} before the last query: the answer is incomplete")
    ev = [{"kind": "sql", "statement": " ".join(s.split())[:1500], "exitCode": p.returncode, "result": f"{len(tags.get(t, []))} row(s)"} for t, s in q.items()]
    return tags, ev


def main(argv):
    ap = argparse.ArgumentParser(description="apex-sentinel's Package gate: the packages and procedures a change names, looked up read-only")
    ap.add_argument("--app")
    ap.add_argument("--env")
    ap.add_argument("--task")
    ap.add_argument("paths", nargs="*")
    a = ap.parse_args(argv)
    result = {"kind": "package-result", "schemaVersion": 1, "status": "UNKNOWN", "reasons": [],
              "context": context(a.task, "apex-sentinel"), "files": [], "unparsed": [], "criteria": [], "advisories": []}
    task_dir, name = None, "package-app.json"
    try:
        alias, task_dir, settings, key = runtime_target(a.app, a.task, a.env)
        if settings is None:
            raise Stop("BLOCKED", "APP_REQUIRED", "apex-sync.json lists several apps: pass --app <alias>")
        name = f"package-{key}.json"
        app_id, conn = settings.get("appId"), settings.get("sqlclConnection")
        result["app"] = {k: v for k, v in (("appAlias", alias), ("environment", a.env)) if v}
        if isinstance(app_id, int) and not isinstance(app_id, bool) and 1 <= app_id <= 9999999999:
            result["app"]["appId"] = app_id
        else:
            raise Stop("BLOCKED", "NO_APP_ID", "apex-sync.json gives this app no appId: the parsing schema is read from it")
        if not isinstance(conn, str) or not RE_CONN.fullmatch(conn):
            raise Stop("BLOCKED", "NO_CONNECTION", "apex-sync.json gives this app (or environment) no valid sqlclConnection")
        result["context"]["target"] = {"connectionName": conn}
        try:
            files = collect(a.paths, EXTS)
        except FileNotFoundError as e:
            raise Stop("BLOCKED", "NOTHING_TO_SCAN", f"no such file or directory: {rel(str(e.args[0])) or os.path.basename(str(e.args[0]))}")
        if not a.paths or not files:
            raise Stop("BLOCKED", "NOTHING_TO_SCAN", "no .apx file to read")
        pairs, owners = {}, set()
        read_sources(files, result, pairs, owners)
        names = {p for p, _ in pairs}
        if not names:
            if result["unparsed"]:
                raise Stop("UNKNOWN", "UNPARSED", "a process or file could not be followed: what it names was not looked up")
            raise Stop("BLOCKED", "NO_PAIRS", f"no package and procedure to look up ({len(result['advisories'])} standalone call(s) advised): nothing to check")
        if len(names) > MAX_NAMES:
            raise Stop("BLOCKED", "TOO_MANY", f"{len(names)} packages: more than one query can name ({MAX_NAMES})")
        tags, result["evidence"] = ask(conn, app_id, names)
        session, owner = tags["ctx"][0][2], tags["ctx"][0][3]
        if owner == "-":
            raise Stop("BLOCKED", "APP_NOT_VISIBLE", f"app {app_id} is not visible through this connection (not imported yet, wrong workspace or appId): apex-sync-check.sh doctor")
        if not all(re.fullmatch(r"[A-Z][A-Z0-9_$#]{0,127}", v) for v in (session, owner)):
            raise Stop("UNKNOWN", "ODD_SCHEMA", "the session's user or the parsing schema is not a plain upper-case identifier: not looked up")
        if owners - {owner}:
            raise Stop("UNKNOWN", "PARSING_SCHEMA", f"the source declares parsing schema {', '.join(sorted(owners))} and the database says {owner}: the names were looked up in {owner}")
        result["database"] = {"owner": owner, "sessionUser": session}
        auth = session == owner                             # the owner sees every one of its objects: absent means absent
        objs = {(r[2], r[3]): r[4] for r in tags.get("obj", [])}
        errs, procs = {}, {}
        for r in tags.get("err", []):
            errs.setdefault(r[2], []).append(safe(f"{r[3]} {r[4]} {r[5]}"))
        for r in tags.get("proc", []):
            procs.setdefault(r[2], set()).add(r[3])
        syns = {r[2]: safe(r[3]) for r in tags.get("syn", [])}
        hits = {"PKG-EXISTS": [], "PKG-COMPILED": [], "PKG-PROC-EXISTS": []}   # (status, finding)
        strict = {p for (p, _), o in pairs.items() if any(h == "invokeApi" for *_, h in o)}
        found = set()

        def hit(cid, status, pkg, detail, proc=None, at=None):
            at = at or ([(p, ln) for (k, _), o in pairs.items() if k == pkg for p, ln, _ in o][:1] or [None])[0]
            hits[cid].append((status, {"package": pkg, **({"procedure": proc} if proc else {}),
                                       **({"path": at[0], "line": at[1]} if at else {}), "detail": detail}))
        for pkg in sorted(names):
            spec, body = objs.get((pkg, "PACKAGE")), objs.get((pkg, "PACKAGE BODY"))
            if spec is None:
                if pkg in syns:
                    hit("PKG-EXISTS", "UNKNOWN", pkg, f"{pkg} resolves through a synonym to {syns[pkg]}: synonyms are not followed")
                elif pkg not in strict:
                    hit("PKG-EXISTS", "UNKNOWN", pkg, f"a named-notation call in a code block names no package visible in {owner}: a missing package, or an object this reader cannot tell from one")
                elif auth:
                    hit("PKG-EXISTS", "FAIL", pkg, f"no package {pkg} in {owner}")
                else:
                    hit("PKG-EXISTS", "UNKNOWN", pkg, f"{pkg} is not visible to {session}: absent, or no EXECUTE grant")
                continue
            found.add(pkg)
            if procs.get(pkg) and body is None:
                hit("PKG-EXISTS", "FAIL" if auth else "UNKNOWN", pkg, "the specification declares subprograms and no package body is visible")
            if errs.get(pkg):
                hit("PKG-COMPILED", "FAIL", pkg, "; ".join(errs[pkg][:3]))
            elif {spec, body} - {"VALID", None}:
                hit("PKG-COMPILED", "UNKNOWN", pkg, "INVALID and ALL_ERRORS holds nothing visible for it (invalidated by a dependency, or errors this user cannot read); not recompiled")
        called = {(p, q) for (p, q) in pairs if p in found}
        for pkg, proc in sorted(called):
            if proc not in procs.get(pkg, ()):
                hit("PKG-PROC-EXISTS", "FAIL", pkg, "not declared in the package specification", proc, pairs[(pkg, proc)][0][:2])

        def crit(cid, exercised, why):
            st = [s for s, _ in hits[cid]]
            status = "FAIL" if "FAIL" in st else "UNKNOWN" if st else "PASS" if exercised else "NOT_RUN"
            c = {"id": cid, "status": status, "findings": [f for _, f in hits[cid]]}
            if status == "NOT_RUN":
                c["notApplicableReason"] = why
            return c
        result["criteria"] = [crit("PKG-EXISTS", found, "no package of this schema was found"),
                              crit("PKG-COMPILED", found, "no package of this schema was found"),
                              crit("PKG-PROC-EXISTS", called, "no file calls a procedure of a package that was found")]
        st = {c["status"] for c in result["criteria"]}
        n = f"{len(found)} package(s) and {len(called)} procedure call(s)"
        if "FAIL" in st:
            result["status"], result["reasons"] = "FAIL", [{"code": "PACKAGE_CRITERIA_FAILED", "message": f"{n} looked up in {owner}; {sum(len(v) for v in hits.values())} finding(s)"}]
        elif "UNKNOWN" in st or result["unparsed"]:
            why = [m for m, on in (("an answer reads neither as held nor as failed", "UNKNOWN" in st), ("a file was not read", result["unparsed"])) if on]
            result["status"], result["reasons"] = "UNKNOWN", [{"code": "UNVERIFIED", "message": f"{n} looked up in {owner}; " + " and ".join(why)}]
        elif st == {"PASS"}:
            result["status"], result["reasons"] = "PASS", [{"code": "PACKAGE_CRITERIA_HELD", "message": f"{n} found VALID in {owner}"}]
        else:
            raise Stop("BLOCKED", "NO_PAIRS", f"no criterion held on a package and a procedure of {owner}: nothing was resolved")
    except Stop as s:
        result["status"], result["reasons"] = s.status, [{"code": s.code, "message": s.message}]
    return write(result, task_dir, name)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
