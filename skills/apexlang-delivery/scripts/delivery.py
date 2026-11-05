#!/usr/bin/env python3
"""delivery — apexlang-delivery's aggregator. It runs no gate: the agent runs each one with its
own skill, into one task. This reads what the task holds, gate by gate in GATES.md's order, and
writes the verification-manifest — reading each result for the destination it is named for
(GATES.md §The orchestration contract).

Usage: python3 delivery.py --task <id> [--app <alias>] [--env <name>] [--skip <gate>:<reason>]...
                          [--exit <gate>[/<producer>]:<code>]... [--page <page>[:dialog]]...

Per gate, from <evidenceDir>/<task>/ (the app's key is <alias>, or <alias>.<env>):
  architecture  architecture.json                       (evidence.py write --kind architecture)
  validation    raw/validation-<key>/validate[.exit.json] (evidence.py capture --gate validation
                … validate -- <Oracle's validate script>): PASS only on exit 0 and the compiler's
                own `Validation successful`
  package       package-<key>.json                      (pkg-check.py --task: the packages and procedures the
                .apx files name, looked up read-only in the database); required only when the app sets packageGate
  sync          sync-<key>-check-import.json            (apex-sync-check.sh check-import --task)
  runtime       runtime-<key>.json                      (evidence.py write --kind runtime) and
                sync-<key>-record-sync.json             (apex-sync-check.sh record-sync --task): the walkthrough
                speaks for the Builder only after the import was recorded, so the gate is NOT_RUN without
                the record-sync, with a result of another operation, or when the walkthrough's own verdict
                (context.timestamp, 1 s resolution) predates the record-sync's; a timestamp that cannot be
                read is UNKNOWN. record-sync PASS records a syncpoint — it does not prove the import ran.
                The sync gate stays check-import alone: that PASS is what authorizes the import.
  security      security-<alias>-{static,plsql,secrets}.json and security-<key>-runtime.json
  ui            ui-<alias>-static.json and, for each --page <page>[:dialog], ui-<key>-runtime-<page>.json
                (ux-check.py names it with the page of the URL it checked: the result must say so itself,
                and :dialog needs its UX-DIALOG-FOCUS to have PASSed). Under uiGate with no --page the
                gate is NOT_RUN: the diff cannot say which pages a change touched, the caller does. Any
                other ui-<key>-runtime-*.json in the task still counts in the gate's worst status.
Each result is validated against the core's schemas (framework/schemas/) with jsonschema, which
is REQUIRED: without it, or without the schemas, this stops BLOCKED (NO_JSONSCHEMA, NO_SCHEMAS)
and writes no manifest — there is no weaker check to fall back to. A result must also be
fresh: made for this task, on the working tree as it is now. Invalid → UNKNOWN; stale, missing
or misfiled (valid and fresh, but its operation, scope, app alias, environment or appId is
another destination's) → NOT_RUN — unless --exit says the gate's command just ran: then a result it did not
leave is BLOCKED when it exited 2 and UNKNOWN otherwise (GATES.md §The orchestration contract),
and a single producer's exit code that disagrees with its result's status is UNKNOWN (so is a PASS, in any gate, whose command exited non-zero: results an earlier run left cannot absorb a failed one) (for the
runtime gate, --exit speaks for runtime-<key>.json alone, not for record-sync). --exit <gate>/<producer>:<code> speaks for
one producer: security static|plsql|secrets|runtime, ui static|runtime-<page>, runtime walkthrough|record-sync, sync check-import,
and architecture|validation|package; the same key twice with two codes, or a key the task has no such producer for, is BAD_EXIT. A
specific exit 0 never neutralizes the gate's non-zero exit. A gate's status is the worst of its results. Package, Security and UI are required
when the app sets packageGate / securityGate / uiGate; --skip records any gate required: false, with why. A gate left out carries
excludedBy (config: the app did not opt in; skip: --skip) and stderr names it: "not evaluated: ...".

Output: the manifest on stdout and in <evidenceDir>/<task>/manifest.json; on stderr, each gate
and the next step — the gate to run, or the first required gate that is not PASS, where the
agent stops and reports (P9).
Exit:   0 PASS · 1 FAIL or CONFLICT · 2 BLOCKED · 3 UNKNOWN · 4 NOT_RUN (a required gate has
        not run yet, or its result is stale) — only 0 authorizes calling the task verified.
"""
import argparse
import glob
import hashlib
import json
import os
import re
import sys
from datetime import datetime
from urllib.parse import urlsplit

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "..", "framework", "lib"))
from result import RE_RUN, RE_TASK, Stop, context, rel, runtime_target, scrub, tree  # noqa: E402

SCHEMAS = os.path.join(HERE, "..", "..", "..", "framework", "schemas")
ORDER = ["architecture", "validation", "package", "sync", "runtime", "security", "ui"]
WORST = ["FAIL", "CONFLICT", "UNKNOWN", "BLOCKED", "NOT_RUN", "PASS"]
EXIT = {"PASS": 0, "FAIL": 1, "CONFLICT": 1, "BLOCKED": 2, "UNKNOWN": 3, "NOT_RUN": 4}
HINT = {
    "architecture": "decide (apexlang-architecture), build, then evidence.py write --kind architecture --task {task}",
    "validation": "evidence.py capture --gate validation --app {alias} --task {task} validate -- <validate-apex-app.sh> <source dir>",
    "package": "pkg-check.py --app {alias}{env} --task {task} <the .apx files or directories the change touches>",
    "sync": "apex-sync-check.sh check-import --app {alias}{env} --task {task}",
    "runtime": "import (only on the Sync PASS), then apex-sync-check.sh record-sync --app {alias}{env} --task {task}, then the apex-sentinel walkthrough "
               "(after the record-sync) and evidence.py write --kind runtime --app {alias}{env} --task {task}",
    "security": "sec-scan.py, plsql-scan.py, secrets-scan.py --app {alias} --task {task}; sec-probe.py --app {alias}{env} --task {task}",
    "ui": "ux-scan.py --app {alias} --task {task}; ux-check.py --app {alias}{env} --task {task} on each page the change touched; "
          "then delivery.py again with --page <page>[:dialog] for each (<page> as in ui-<key>-runtime-<page>.json)",
}


# A page token is what page_name() makes of a URL: letters, digits, _ and -, at most 40 characters.
RE_PAGE = re.compile(r"[A-Za-z0-9_-]{1,40}")
# GAP-14 A: the producers a gate has, by the key `--exit <gate>/<key>:<code>` names them. ui also has one
# `runtime-<page>` per declared page or runtime result found: those depend on the task and are checked there.
PRODUCERS = {"architecture": ("architecture",), "validation": ("validation",), "package": ("package",),
             "sync": ("check-import",), "runtime": ("walkthrough", "record-sync"),
             "security": ("static", "plsql", "secrets", "runtime"), "ui": ("static",)}


def page_name(url):
    """A file-name part for the page: the last path segment, or f?p's page; 'page' otherwise."""
    m = re.search(r"f\?p=[^:&#]*:([^:&#]+)", url or "")
    seg = m.group(1) if m else urlsplit(url or "").path.rstrip("/").rsplit("/", 1)[-1]
    seg = re.sub(r"[^A-Za-z0-9_-]+", "-", seg).strip("-")[:40]
    return seg or "page"


def ran_without(code):
    """A gate whose command ran and left no fresh result: what GATES.md's contract reads it as."""
    return "BLOCKED" if code == 2 else "UNKNOWN"


def apply_exit(res, c, label):
    """GAP-14 A: one producer's own exit code against its own result. res = (status, cite, note), as read.
    A result the producer did not leave fresh (NOT_RUN) reads as `ran_without`: BLOCKED for exit 2, UNKNOWN otherwise
    (exit 0 included: it ran and left nothing). A result whose status disagrees with the exit is UNKNOWN: a PASS whose
    command exited non-zero is not its output. A status that matches its exit keeps its severity."""
    s, cite, note = res
    if s == "NOT_RUN":
        return ran_without(c), cite, f"{label}: ran (exit {c}) but {note}"
    if s in EXIT and EXIT[s] != c and cite:
        return "UNKNOWN", cite, f"{label}: {note}, but its command exited {c}"
    return res


def utc(stamp):
    """A result's context.timestamp (`YYYY-MM-DDTHH:MM:SSZ`, UTC, 1 s resolution) as a datetime, or None when it is
    absent or not a real instant (the schema's pattern admits a 13th month)."""
    try:
        return datetime.strptime(stamp, "%Y-%m-%dT%H:%M:%SZ")
    except (TypeError, ValueError):
        return None


def worst(statuses):
    statuses = list(statuses)
    return min(statuses, key=WORST.index) if statuses else "NOT_RUN"


def sha256(path):
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()


def schema_checker():
    """(name, check): jsonschema against the repo's schemas. jsonschema is required — there is no
    weaker fallback, since a check that passes what the schema rejects would authorize on a
    document that is not a valid result. check(doc, kind) → None, or why the document is not one."""
    try:
        import jsonschema
        from jsonschema import Draft202012Validator
    except ImportError:
        raise Stop("BLOCKED", "NO_JSONSCHEMA", "python jsonschema is required to validate the results: "
                   "apt install python3-jsonschema, or python -m pip install jsonschema") from None
    schemas = {}
    for p in glob.glob(os.path.join(SCHEMAS, "*.schema.json")):
        with open(p, encoding="utf-8") as fh:
            schemas[os.path.basename(p)] = json.load(fh)
    # the core's schemas are the check: without them nothing can be validated, and that blocks
    # (fail closed) rather than passing or crashing.
    if not schemas:
        raise Stop("BLOCKED", "NO_SCHEMAS", f"no schemas were found in {SCHEMAS}: "
                   "install the framework core (framework/schemas/) next to the skill")
    try:
        from referencing import Registry, Resource
        from referencing.jsonschema import DRAFT202012
        reg = Registry().with_resources((s["$id"], Resource.from_contents(s, default_specification=DRAFT202012))
                                        for s in schemas.values())
        make = lambda s: Draft202012Validator(s, registry=reg)                         # noqa: E731
    except ImportError:
        store = {s["$id"]: s for s in schemas.values()}
        make = lambda s: Draft202012Validator(s, resolver=jsonschema.RefResolver.from_schema(s, store=store))  # noqa: E731
    validators = {}

    def check(doc, kind):
        if f"{kind}.schema.json" not in schemas:
            raise Stop("BLOCKED", "NO_SCHEMA", f"no {kind}.schema.json in {SCHEMAS}: the core is incomplete")
        v = validators.setdefault(kind, make(schemas[f"{kind}.schema.json"]))
        err = next(iter(v.iter_errors(doc)), None)
        return None if err is None else f"schema: {err.message[:160]}"
    return "jsonschema", check


OPTIONAL_ID = {"app.appId"}     # compared only when both the result and the config carry one


def misfiled(doc, want):
    """Why a valid, fresh result is about another destination than the one read, or "": the first
    field of want ({dotted path: expected}) it does not hold. Consistency, not proof — results are
    not signed; this catches a result copied, renamed or filed under the wrong name."""
    for path, expected in want.items():
        got = doc
        for part in path.split("."):
            got = got.get(part) if isinstance(got, dict) else None
        if path in OPTIONAL_ID and (got is None or expected is None):
            continue
        if str(got) != str(expected):
            have = f"has no {path}" if got is None else f"holds {path} {json.dumps(got)[:60]}"
            return f"it {have}, this destination needs {'it absent' if expected is None else json.dumps(expected)[:60]}"
    return ""


class Reader:
    def __init__(self, task, task_dir, check, run=None):
        self.task, self.dir, self.check, self.now, self.run = task, task_dir, check, tree(), run
        self.doc = {}                      # file name -> the result, once valid, fresh and this destination's

    def result(self, name, kind, want=None, also=None):
        """(status, cite or None, note): one result file of the task, judged. want = {field: expected}:
        the identity the destination needs (see misfiled). also(doc) → "" or why a valid, fresh result
        still is not this destination's PASS (read as NOT_RUN). It runs on a PASS only: any other
        status already authorizes nothing, and must keep its own severity."""
        path = os.path.join(self.dir, name)
        if not os.path.isfile(path):
            return "NOT_RUN", None, f"{name}: not in the task"
        cite = {"kind": kind, "path": rel(path), "sha256": sha256(path)}
        try:
            with open(path, encoding="utf-8") as fh:
                doc = json.load(fh)
        except (OSError, ValueError):
            return "UNKNOWN", cite, f"{name}: not readable JSON"
        why = self.check(doc, kind)
        if why:
            return "UNKNOWN", cite, f"{name}: invalid — {why}"
        ctx = doc["context"]
        then = ctx.get("repo", {}).get("tree")
        got_run = ctx.get("runId")
        stale = (f"made for task {ctx.get('task')}" if ctx.get("task") != self.task
                 else f"made in run {got_run}, this is run {self.run}" if self.run and got_run and got_run != self.run
                 else f"records no run, this is run {self.run}" if self.run and not got_run
                 else "records no working tree" if not then
                 else "the working tree changed since" if then != self.now else "")
        if stale:
            return "NOT_RUN", cite, f"{name}: stale — {stale}; run it again"
        wrong = misfiled(doc, want or {})
        if wrong:
            return "NOT_RUN", cite, f"{name}: misfiled — {wrong}; it is not this destination's result, run the gate for it"
        self.doc[name] = doc
        more = also(doc) if also and doc["status"] == "PASS" else ""     # only a PASS needs more than it says
        if more:
            return "NOT_RUN", cite, f"{name}: {more}"
        return doc["status"], cite, f"{name}: {doc['status']}"


def page_check(token, dialog):
    """also() for a --page: the result's own runtimeUrl must name the page its file name claims (a copy
    of another page's result, or one of another app's, is not this page's), and a :dialog page needs the
    dialog criterion exercised — ux-check.py writes PASS with UX-DIALOG-FOCUS NOT_RUN when no opener was given."""
    def check(doc):
        url = (doc["context"].get("target") or {}).get("runtimeUrl")
        if not url:
            return f"misfiled — it records no runtimeUrl, so it names no page; run ux-check.py on page {token}"
        got = page_name(url)
        if got != token:
            return (f"misfiled — its runtimeUrl names page {got}, this destination is page {token}; "
                    f"it is not this page's result, run ux-check.py on it")
        if dialog:
            crit = next((c for c in doc.get("criteria", []) if c.get("id") == "UX-DIALOG-FOCUS"), None)
            if not crit or crit.get("status") != "PASS":
                return (f"page {token} was declared :dialog but UX-DIALOG-FOCUS was not exercised; run ux-check.py "
                        f"--dialog <selector> on the control that opens it")
        return ""
    return check


def after_record_sync(reader, runtime, record, got):
    """The Runtime gate's order rule (GATES.md §The orchestration contract): the walkthrough's verdict must not
    predate the record-sync that follows the import. got = [(status, cite, note)] for [runtime, record-sync], as
    read. Judged only when both PASS: any other status already authorizes nothing and keeps its own severity. The
    runtime is the stale one (record-sync is the newer fact); a timestamp that is not a real instant is UNKNOWN."""
    (rs, rc, rn), (ss, sc, sn) = got
    if rs != "PASS" or ss != "PASS":
        return got
    at = lambda n: reader.doc[n]["context"].get("timestamp")                      # noqa: E731
    unreadable = "its context.timestamp is not a UTC time, so it cannot be ordered against {}"
    if utc(at(runtime)) is None:
        return [("UNKNOWN", rc, f"{runtime}: " + unreadable.format("record-sync")), (ss, sc, sn)]
    if utc(at(record)) is None:
        return [(rs, rc, rn), ("UNKNOWN", sc, f"{record}: " + unreadable.format("the runtime verdict"))]
    if reader.doc[record].get("basis") == "forced":      # the user's --force (P9): recorded, not judged
        sn += " (basis forced: recorded by hand, the user's call; not judged here)"
    if utc(at(runtime)) < utc(at(record)):
        return [("NOT_RUN", rc, f"{runtime}: stale — its verdict ({at(runtime)}) predates record-sync ({at(record)}); "
                                "run the walkthrough again after the import"), (ss, sc, sn)]
    return [(rs, rc, rn), (ss, sc, sn)]


def validation(reader, keys):
    """Oracle's compiler through evidence.py capture: exit 0 and its own words, or nothing.
    The capture is keyed by the alias (the source compiles the same for every environment), or
    by alias.env when it was given one."""
    found = [os.path.join(reader.dir, "raw", f"validation-{k}", "validate") for k in keys]
    found = [o for o in found if os.path.isfile(o) and os.path.isfile(o + ".exit.json")]
    if not found:
        return "NOT_RUN", [], f"raw/validation-{keys[0]}/validate: not in the task"
    out = max(found, key=os.path.getmtime)
    meta = out + ".exit.json"
    try:
        with open(meta, encoding="utf-8") as fh:
            m = json.load(fh)
        with open(out, encoding="utf-8") as fh:
            text = fh.read()
        rc, cmd = int(m["exitCode"]), str(m["command"]) or "validate"
    except (OSError, ValueError, KeyError, TypeError):
        return "UNKNOWN", [], "the Validation capture is unreadable"
    if m.get("sha256") and m["sha256"] != sha256(out):      # GAP-14 B: output and metadata are one unit (metadata is published last)
        return "UNKNOWN", [], "the Validation capture does not match its metadata (incomplete or changed since): run it again"
    stale = (f"made for task {m.get('task')}" if m.get("task") != reader.task
             else f"made in run {m.get('runId')}, this is run {reader.run}" if reader.run and m.get("runId") and m.get("runId") != reader.run
             else f"records no run, this is run {reader.run}" if reader.run and not m.get("runId")
             else "records no working tree" if not m.get("tree")
             else "the working tree changed since" if m.get("tree") != reader.now else "")
    if stale:
        return "NOT_RUN", [], f"the Validation capture is stale — {stale}; run it again"
    ev = [{"kind": "file", "path": rel(out), "sha256": sha256(out)}]
    ok = rc == 0 and re.search(r"(?m)^\s*(compiler: PASS — )?Validation successful\b", text)
    line = "Validation successful" if ok else next(
        (ln.strip() for ln in text.splitlines() if re.search(r"(?i)error|not supported|failed", ln)), "")[:200]
    ev.insert(0, {"kind": "command", "command": cmd[:300], "exitCode": rc, **({"output": line} if line else {})})
    if ok:
        return "PASS", ev, "Validation successful"
    if re.search(r"not supported by this SQLcl", text):
        return "BLOCKED", ev, "this SQLcl cannot read the source's APEXlang version (UP-2)"
    if rc != 0 or re.search(r"Compile Errors", text):
        return "FAIL", ev, f"exit {rc}: the compiler did not validate the source"
    return "UNKNOWN", ev, "exit 0 without `Validation successful` (a Spanish JVM? UP-1) — never read as PASS"


def main(argv):
    for stream in (sys.stdout, sys.stderr):     # Windows defaults to cp1252: the report is UTF-8
        try:
            stream.reconfigure(encoding="utf-8")
        except (AttributeError, ValueError):
            pass
    ap = argparse.ArgumentParser(description="apexlang-delivery: the task's gates, as a verification-manifest")
    ap.add_argument("--task", required=True)
    ap.add_argument("--app")
    ap.add_argument("--env")
    ap.add_argument("--skip", action="append", default=[], metavar="GATE:REASON")
    ap.add_argument("--exit", action="append", default=[], metavar="GATE[/PRODUCER]:CODE", dest="exits")
    ap.add_argument("--run", default=os.environ.get("APEX_RUN_ID") or None, metavar="ID",
                    help="read only the results written in this run (context.runId; default $APEX_RUN_ID): GAP-14")
    ap.add_argument("--page", action="append", default=[], metavar="PAGE[:dialog]",
                    help="a page the change touched, as in ui-<key>-runtime-<page>.json; :dialog if it opens a dialog")
    a = ap.parse_args(argv)
    manifest = {"kind": "verification-manifest", "schemaVersion": 1, "status": "UNKNOWN",
                "context": context(a.task, "apexlang-delivery"), "gates": []}
    try:
        if not RE_TASK.match(a.task):
            raise Stop("BLOCKED", "BAD_TASK", f"--task must match {RE_TASK.pattern}")
        if a.run is not None and not RE_RUN.fullmatch(a.run):
            raise Stop("BLOCKED", "BAD_RUN", "--run (or APEX_RUN_ID) must be 1-64 letters, digits, '.', '_' or '-', starting with a letter or digit")
        if a.run:
            manifest["context"]["runId"] = a.run
        skips = {}
        for s in a.skip:
            g, sep, why = s.partition(":")
            if g not in ORDER or not sep or not why.strip():
                raise Stop("BLOCKED", "BAD_SKIP", f"--skip takes <gate>:<reason>, gate one of {', '.join(ORDER)}")
            skips[g] = why.strip()
        exits, pexits = {}, {}          # the gate's exit; one producer's, by (gate, key)
        for s in a.exits:
            spec, sep, code = s.rpartition(":")
            g, slash, prod = spec.partition("/")
            if not sep or g not in ORDER or not re.fullmatch(r"-?[0-9]{1,3}", code.strip()) or (slash and not prod):
                raise Stop("BLOCKED", "BAD_EXIT", f"--exit takes <gate>[/<producer>]:<exit code>, gate one of {', '.join(ORDER)}")
            if slash:
                fixed = PRODUCERS[g]
                if prod not in fixed and not (g == "ui" and prod.startswith("runtime-") and RE_PAGE.fullmatch(prod[8:])):
                    raise Stop("BLOCKED", "BAD_EXIT", f"--exit {g}/{prod[:40]}: {g} has the producers {', '.join(fixed)}"
                               + (" and runtime-<page>" if g == "ui" else ""))
                if pexits.setdefault((g, prod), int(code)) != int(code):
                    raise Stop("BLOCKED", "BAD_EXIT", f"--exit {g}/{prod} is given with two different codes")
            else:
                exits[g] = int(code)
        pages = {}
        for s in a.page:
            token, sep, mod = s.partition(":")
            if not RE_PAGE.fullmatch(token) or (sep and mod != "dialog"):
                raise Stop("BLOCKED", "BAD_PAGE", f"--page takes <page>[:dialog] (the <page> of ui-<key>-runtime-<page>.json: "
                           f"letters, digits, _ and -, up to 40), not {json.dumps(s[:40])}")
            if token in pages:
                raise Stop("BLOCKED", "BAD_PAGE", f"--page {token} is given twice: declare each page once, with :dialog if it opens one")
            pages[token] = bool(sep)
        alias, task_dir, settings, key = runtime_target(a.app, a.task, a.env)
        if not alias or not task_dir:
            raise Stop("BLOCKED", "APP_REQUIRED", "name the app (--app) or keep one app in apex-sync.json")
        if not settings:        # additive note, no change of status or exit: the aggregator reads files and never imports
            print("delivery: apex-sync.json not found: Sync, Validation and Runtime cannot PASS; run apex-sync-check.sh apps",
                  file=sys.stderr)
        name, check = schema_checker()
        manifest["schemaCheck"] = name
        reader = Reader(a.task, task_dir, check, a.run)
        if not reader.now:
            raise Stop("UNKNOWN", "NO_TREE", "git cannot hash the working tree here: no result can be proven fresh")
        opt = {"package": "packageGate", "security": "securityGate", "ui": "uiGate"}
        notes = []
        for gate in ORDER:
            entry = {"gate": gate}
            if gate != "architecture":
                entry["app"] = alias
            if gate in skips:
                entry.update(required=False, status="NOT_RUN", notApplicableReason=skips[gate], excludedBy="skip")
            elif gate in opt and (settings or {}).get(opt[gate]) is not True:
                entry.update(required=False, status="NOT_RUN", excludedBy="config",
                             notApplicableReason=f"{opt[gate]} is not set for {alias} (opt-in until 1.0.0)")
            else:
                entry["required"] = True
                if gate == "validation":
                    st, ev, note = validation(reader, list(dict.fromkeys([alias, key])))
                    # the gate's exit, and the producer's own (validation/validation): either one that failed counts
                    for c in [x for x in (exits.get(gate), pexits.get((gate, "validation"))) if x is not None]:
                        if st == "NOT_RUN":
                            st, note = ran_without(c), f"the capture ran (exit {c}) but {note}"
                        elif st == "PASS" and c != 0:     # a capture left by an earlier run, a command that failed since
                            st, note = "UNKNOWN", f"{note}, but its command exited {c}"
                    entry["status"] = st
                    if ev:
                        entry["evidence"] = ev
                    seen = [note]
                else:
                    # What each file must say about itself. A result tied to a Builder also names its
                    # environment (absent only without --env) and appId (when both it and the config have
                    # one); the source scans are shared by the environments; the architecture decision
                    # is the task's, not an app's, so it is read for any app.
                    # The UI pages: the ones the caller declared (--page), each read as that page; then every
                    # other runtime result in the task, which still counts in the worst status.
                    page_checks = {f"ui-{key}-runtime-{t}.json": page_check(t, d) for t, d in pages.items()}
                    others = [os.path.basename(p) for p in sorted(glob.glob(os.path.join(task_dir, f"ui-{glob.escape(key)}-runtime-*.json")))]
                    ui_pages = list(page_checks) + [n for n in others if n not in page_checks]
                    who = {"app.appAlias": alias}
                    bound = {**who, "app.environment": a.env, "app.appId": (settings or {}).get("appId")}
                    pre = f"ui-{key}-runtime-"
                    files = {
                        "architecture": [("architecture.json", "architecture-result", {}, "architecture")],
                        "package": [(f"package-{key}.json", "package-result", bound, "package")],
                        "sync": [(f"sync-{key}-check-import.json", "sync-result", {"operation": "check-import", **bound}, "check-import")],
                        "runtime": [(f"runtime-{key}.json", "runtime-result", bound, "walkthrough"),
                                    (f"sync-{key}-record-sync.json", "sync-result", {"operation": "record-sync", **bound}, "record-sync")],
                        "security": [(f"security-{alias}-{s}.json", "security-result", {"scope": s, **who}, s) for s in ("static", "plsql", "secrets")]
                                    + [(f"security-{key}-runtime.json", "security-result", {"scope": "runtime", **bound}, "runtime")],
                        "ui": [(f"ui-{alias}-static.json", "ui-result", {"scope": "static", **who}, "static")]
                              + [(n, "ui-result", {"scope": "runtime", **bound}, "runtime-" + n[len(pre):-5]) for n in ui_pages],
                    }[gate]
                    for g_, k_ in pexits:        # a producer key must name one this task has (a declared page counts without its file)
                        if g_ == gate and k_ not in [f[3] for f in files]:
                            raise Stop("BLOCKED", "BAD_EXIT", f"--exit {g_}/{k_}: no such producer in this task; {g_} has "
                                       + ", ".join(f[3] for f in files))
                    got = [reader.result(n, k, w, page_checks.get(n)) for n, k, w, _ in files]
                    got = [apply_exit(r, pexits[(gate, f[3])], f"{gate}/{f[3]}") if (gate, f[3]) in pexits else r
                           for r, f in zip(got, files)]
                    if gate == "runtime":      # record-sync is the import's second half: the walkthrough comes after it
                        got = after_record_sync(reader, files[0][0], files[1][0], got)
                    if gate == "ui" and not pages:
                        got.append(("NOT_RUN", None, "no page declared: pass --page <page>[:dialog] for each page the change touched "
                                                     f"(<page> is the part of ui-{key}-runtime-<page>.json)"))
                    if gate in exits:
                        # the command that ran is the gate's producer: for runtime that is the walkthrough, whose result is
                        # the first; record-sync is another command's, so its absence is not this command's missing result
                        c, own = exits[gate], (lambda i: gate != "runtime" or i == 0)   # noqa: E731
                        got = [(ran_without(c), cite, f"ran (exit {c}) but {note}") if s == "NOT_RUN" and own(i) else (s, cite, note)
                               for i, (s, cite, note) in enumerate(got)]
                        if (len(got) == 1 or gate == "runtime") and got[0][0] in EXIT and EXIT[got[0][0]] != c and got[0][1]:
                            got[0] = ("UNKNOWN", got[0][1], f"{got[0][2]}, but its command exited {c}")
                    if exits.get(gate, 0) != 0 and all(s == "PASS" for s, _, _ in got):
                        # one exit code for the gate's producers (security has four, ui one per page): if every result
                        # reads PASS, a producer that failed without leaving a result is indistinguishable from the
                        # results an earlier run left. It cannot be PASS (R2-01, R2-02).
                        got.append(("UNKNOWN", None, f"ran (exit {exits[gate]}) but every result reads PASS: a failed run cannot be "
                                                     "told apart from the results an earlier run left; run the producers again"))
                    entry["status"] = worst(s for s, _, _ in got)
                    cites = [c for _, c, _ in got if c]
                    if cites:
                        entry["results"] = cites
                    seen = [n for _, _, n in got]
            if gate == "ui" and pages and not entry["required"]:       # the whole gate is out: no page is read
                print("delivery: --page ignored: the ui gate is not required (skipped, or uiGate is not set)", file=sys.stderr)
            manifest["gates"].append(entry)
            notes.append((gate, entry, seen if entry["required"] else [entry["notApplicableReason"]]))
        required = [g["status"] for g in manifest["gates"] if g["required"]]
        manifest["status"] = worst(required)
        report(notes, a, alias)
    except Stop as s:                            # no manifest: nothing was read
        print(f"delivery: {s.status} ({s.code}) — {s.message}", file=sys.stderr)
        return EXIT[s.status]
    doc = json.dumps(manifest, indent=2)
    print(doc)
    for d in (task_dir, os.environ.get("RESULT_CAPTURE_DIR")):
        if not d:
            continue
        f = os.path.join(d, "manifest.json" if d == task_dir else f"{os.getpid()}-manifest.json")
        try:
            with open(f + ".tmp", "w", encoding="utf-8") as fh:
                fh.write(doc + "\n")
            os.replace(f + ".tmp", f)
        except OSError as e:
            print(f"delivery: could not write {scrub(f)}: {e.__class__.__name__}", file=sys.stderr)
            if d == task_dir:
                return 3                         # a manifest not on disk is no record
    return EXIT[manifest["status"]]


def report(notes, a, alias):
    """Each gate on stderr, then the next step: run the first required gate not yet run, or
    stop at the first required gate whose result is not PASS."""
    nxt = None
    for gate, entry, seen in notes:
        req = "required" if entry["required"] else "not required"
        print(f"  {entry['status']:<8} {gate:<12} ({req}) " + "; ".join(seen), file=sys.stderr)
        if nxt is None and entry["required"] and entry["status"] != "PASS":
            nxt = (gate, entry["status"])
    out = [f"{gate} ({entry['excludedBy']})" for gate, entry, _ in notes if entry.get("excludedBy")]
    if out:        # a gate left out says nothing about the change, on every branch below
        print(f"delivery: not evaluated: {', '.join(out)} - not a statement about them", file=sys.stderr)
    if nxt is None:
        print("delivery: every required gate PASSes on fresh results.", file=sys.stderr)
    elif nxt[1] == "NOT_RUN":
        hint = HINT[nxt[0]].format(task=a.task, alias=alias, env=f" --env {a.env}" if a.env else "")
        print(f"delivery: next — run the {nxt[0]} gate: {hint}", file=sys.stderr)
    else:
        print(f"delivery: stop — the {nxt[0]} gate is {nxt[1]}. Report it; what happens next is the user's call (P9).",
              file=sys.stderr)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
