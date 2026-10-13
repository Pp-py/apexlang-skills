#!/usr/bin/env python3
"""delivery — apexlang-delivery's aggregator. It runs no gate: the agent runs each one with its
own skill, into one task. This reads what the task holds, gate by gate in GATES.md's order, and
writes the verification-manifest — adding no rule of its own (GATES.md §The orchestration
contract).

Usage: python3 delivery.py --task <id> [--app <alias>] [--env <name>] [--skip <gate>:<reason>]...
                          [--exit <gate>:<code>]...

Per gate, from <evidenceDir>/<task>/ (the app's key is <alias>, or <alias>.<env>):
  architecture  architecture.json                       (evidence.py write --kind architecture)
  validation    raw/validation-<key>/validate[.exit.json] (evidence.py capture --gate validation
                … validate -- <Oracle's validate script>): PASS only on exit 0 and the compiler's
                own `Validation successful`
  sync          sync-<key>-check-import.json            (apex-sync-check.sh check-import --task)
  runtime       runtime-<key>.json                      (evidence.py write --kind runtime)
  security      security-<alias>-{static,plsql,secrets}.json and security-<key>-runtime.json
  ui            ui-<alias>-static.json and ui-<key>-runtime-*.json (one per page, at least one)
Each result is validated — with jsonschema when it is installed, else by this script's own
checks of the rules a verdict rests on (the manifest's schemaCheck says which) — and must be
fresh: made for this task, on the working tree as it is now. Invalid → UNKNOWN; stale or
missing → NOT_RUN — unless --exit says the gate's command just ran: then a result it did not
leave is BLOCKED when it exited 2 and UNKNOWN otherwise (GATES.md §The orchestration contract),
and a single producer's exit code that disagrees with its result's status is UNKNOWN. A gate's status is the worst of its results. Security and UI are required
when the app sets securityGate / uiGate; --skip records any gate required: false, with why.

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

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "..", "framework", "lib"))
from result import RE_TASK, Stop, context, rel, runtime_target, scrub, tree  # noqa: E402

SCHEMAS = os.path.join(HERE, "..", "..", "..", "framework", "schemas")
ORDER = ["architecture", "validation", "sync", "runtime", "security", "ui"]
WORST = ["FAIL", "CONFLICT", "UNKNOWN", "BLOCKED", "NOT_RUN", "PASS"]
EXIT = {"PASS": 0, "FAIL": 1, "CONFLICT": 1, "BLOCKED": 2, "UNKNOWN": 3, "NOT_RUN": 4}
STATUSES = {"architecture-result": {"PASS", "FAIL", "BLOCKED", "UNKNOWN"},
            "sync-result": {"PASS", "FAIL", "CONFLICT", "BLOCKED", "UNKNOWN"},
            "runtime-result": {"PASS", "FAIL", "BLOCKED", "UNKNOWN"},
            "security-result": {"PASS", "FAIL", "BLOCKED", "UNKNOWN"},
            "ui-result": {"PASS", "FAIL", "BLOCKED", "UNKNOWN"}}
HINT = {
    "architecture": "decide (apexlang-architecture), build, then evidence.py write --kind architecture --task {task}",
    "validation": "evidence.py capture --gate validation --app {alias} --task {task} validate -- <validate-apex-app.sh> <source dir>",
    "sync": "apex-sync-check.sh check-import --app {alias}{env} --task {task}",
    "runtime": "import (only on the Sync PASS), record-sync, then the apex-sentinel walkthrough and evidence.py write --kind runtime --app {alias}{env} --task {task}",
    "security": "sec-scan.py, plsql-scan.py, secrets-scan.py --app {alias} --task {task}; sec-probe.py --app {alias}{env} --task {task}",
    "ui": "ux-scan.py --app {alias} --task {task}; ux-check.py --app {alias}{env} --task {task} on each page the change touched",
}


def ran_without(code):
    """A gate whose command ran and left no fresh result: what GATES.md's contract reads it as."""
    return "BLOCKED" if code == 2 else "UNKNOWN"


def worst(statuses):
    statuses = list(statuses)
    return min(statuses, key=WORST.index) if statuses else "NOT_RUN"


def sha256(path):
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()


def schema_checker():
    """(name, check): jsonschema against the repo's schemas when it is installed, else this
    script's own checks. check(doc, kind) → None, or why the document is not a valid result."""
    try:
        import jsonschema
        from jsonschema import Draft202012Validator
        schemas = {}
        for p in glob.glob(os.path.join(SCHEMAS, "*.schema.json")):
            with open(p, encoding="utf-8") as fh:
                schemas[os.path.basename(p)] = json.load(fh)
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
            v = validators.setdefault(kind, make(schemas[f"{kind}.schema.json"]))
            err = next(iter(v.iter_errors(doc)), None)
            return None if err is None else f"schema: {err.message[:160]}"
        return "jsonschema", check
    except ImportError:
        return "structural", structural


def structural(doc, kind):
    """What a verdict rests on, without jsonschema: the kind, the status vocabulary, the task,
    and that the status agrees with the criteria it summarises."""
    if not isinstance(doc, dict) or doc.get("kind") != kind or doc.get("schemaVersion") != 1:
        return f"not a {kind} (schemaVersion 1)"
    status = doc.get("status")
    if status not in STATUSES[kind]:
        return f"status {status!r} is not one a {kind} may carry"
    ctx = doc.get("context")
    if not isinstance(ctx, dict) or not isinstance(ctx.get("repo"), dict) or "task" not in ctx:
        return "no context (task, repo)"
    crit = doc.get("criteria")
    if kind in ("runtime-result", "security-result", "ui-result"):
        if not isinstance(crit, list) or not all(isinstance(c, dict) for c in crit):
            return "no criteria list"
        states = [c.get("status") for c in crit]
        if any(s not in ("PASS", "FAIL", "NOT_RUN") for s in states):
            return "a criterion status that is not PASS, FAIL or NOT_RUN"
        if status == "PASS" and ("FAIL" in states or "PASS" not in states):
            return "a PASS over a FAIL criterion, or with no criterion that held"
        if status == "FAIL" and "FAIL" not in states:
            return "a FAIL with no failed criterion"
    if kind == "architecture-result" and status == "PASS" and doc.get("redFlags"):
        return "a PASS with red flags"
    return None


class Reader:
    def __init__(self, task, task_dir, check):
        self.task, self.dir, self.check, self.now = task, task_dir, check, tree()

    def result(self, name, kind):
        """(status, cite or None, note): one result file of the task, judged."""
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
        stale = (f"made for task {ctx.get('task')}" if ctx.get("task") != self.task
                 else "records no working tree" if not then
                 else "the working tree changed since" if then != self.now else "")
        if stale:
            return "NOT_RUN", cite, f"{name}: stale — {stale}; run it again"
        return doc["status"], cite, f"{name}: {doc['status']}"


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
    stale = (f"made for task {m.get('task')}" if m.get("task") != reader.task
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
    ap.add_argument("--exit", action="append", default=[], metavar="GATE:CODE", dest="exits")
    a = ap.parse_args(argv)
    manifest = {"kind": "verification-manifest", "schemaVersion": 1, "status": "UNKNOWN",
                "context": context(a.task, "apexlang-delivery"), "gates": []}
    try:
        if not RE_TASK.match(a.task):
            raise Stop("BLOCKED", "BAD_TASK", f"--task must match {RE_TASK.pattern}")
        skips = {}
        for s in a.skip:
            g, sep, why = s.partition(":")
            if g not in ORDER or not sep or not why.strip():
                raise Stop("BLOCKED", "BAD_SKIP", f"--skip takes <gate>:<reason>, gate one of {', '.join(ORDER)}")
            skips[g] = why.strip()
        exits = {}
        for s in a.exits:
            g, sep, code = s.partition(":")
            if g not in ORDER or not re.fullmatch(r"-?[0-9]{1,3}", code.strip()):
                raise Stop("BLOCKED", "BAD_EXIT", f"--exit takes <gate>:<exit code>, gate one of {', '.join(ORDER)}")
            exits[g] = int(code)
        alias, task_dir, settings, key = runtime_target(a.app, a.task, a.env)
        if not alias or not task_dir:
            raise Stop("BLOCKED", "APP_REQUIRED", "name the app (--app) or keep one app in apex-sync.json")
        name, check = schema_checker()
        manifest["schemaCheck"] = name
        reader = Reader(a.task, task_dir, check)
        if not reader.now:
            raise Stop("UNKNOWN", "NO_TREE", "git cannot hash the working tree here: no result can be proven fresh")
        opt = {"security": "securityGate", "ui": "uiGate"}
        notes = []
        for gate in ORDER:
            entry = {"gate": gate}
            if gate != "architecture":
                entry["app"] = alias
            if gate in skips:
                entry.update(required=False, status="NOT_RUN", notApplicableReason=skips[gate])
            elif gate in opt and (settings or {}).get(opt[gate]) is not True:
                entry.update(required=False, status="NOT_RUN",
                             notApplicableReason=f"{opt[gate]} is not set for {alias} (opt-in until 1.0.0)")
            else:
                entry["required"] = True
                if gate == "validation":
                    st, ev, note = validation(reader, list(dict.fromkeys([alias, key])))
                    if st == "NOT_RUN" and gate in exits:
                        st, note = ran_without(exits[gate]), f"the capture ran (exit {exits[gate]}) but {note}"
                    entry["status"] = st
                    if ev:
                        entry["evidence"] = ev
                    seen = [note]
                else:
                    files = {
                        "architecture": [("architecture.json", "architecture-result")],
                        "sync": [(f"sync-{key}-check-import.json", "sync-result")],
                        "runtime": [(f"runtime-{key}.json", "runtime-result")],
                        "security": [(f"security-{alias}-{s}.json", "security-result") for s in ("static", "plsql", "secrets")]
                                    + [(f"security-{key}-runtime.json", "security-result")],
                        "ui": [(f"ui-{alias}-static.json", "ui-result")]
                              + ([(os.path.basename(p), "ui-result") for p in sorted(glob.glob(os.path.join(task_dir, f"ui-{glob.escape(key)}-runtime-*.json")))]
                                 or [(f"ui-{key}-runtime-<page>.json", "ui-result")]),
                    }[gate]
                    got = [reader.result(n, k) for n, k in files]
                    if gate in exits:
                        c = exits[gate]
                        got = [(ran_without(c), cite, f"ran (exit {c}) but {note}") if s == "NOT_RUN" else (s, cite, note)
                               for s, cite, note in got]
                        if len(got) == 1 and got[0][0] in EXIT and EXIT[got[0][0]] != c and got[0][1]:
                            got = [("UNKNOWN", got[0][1], f"{got[0][2]}, but its command exited {c}")]
                    entry["status"] = worst(s for s, _, _ in got)
                    cites = [c for _, c, _ in got if c]
                    if cites:
                        entry["results"] = cites
                    seen = [n for _, _, n in got]
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
