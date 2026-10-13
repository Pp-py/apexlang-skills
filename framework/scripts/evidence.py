#!/usr/bin/env python3
"""evidence — writes the two results an agent judges (runtime-result, architecture-result) and
the raw evidence they cite, so neither is hand-written JSON. Standard library only.

Usage:
  evidence.py capture --gate runtime|architecture [--app <alias>] [--env <name>] --task <id> <name> -- <command>...
      Runs the command and saves its stdout, redacted, to
      <evidenceDir>/<task>/raw/<gate>-<alias>/<name>. Prints {evidence: {kind: file, path, sha256},
      exitCode (the command's), redacted (how many values were removed)}.
  evidence.py write --kind runtime|architecture [--app <alias>] [--env <name>] --task <id> <draft.json>
      The draft holds only what the agent observed — runtime: check, backend, login, criteria,
      evidence, target; architecture: decisions, redFlags, missingInputs, evidence. The script
      adds kind, schemaVersion, app and context (method: agent), hashes every cited file (a hash
      that no longer matches is refused), DERIVES the status, and writes runtime-<alias>.json or
      architecture.json in the task dir. For an app with environments, --env is required
      for a runtime result: it names the runtime verified, and keys the files by alias.env.
  evidence.py fresh --task <id> <result.json>...
      Whether each result still speaks for now (GATES.md §Freshness): it is stale when it was
      made for another task, records no working tree (context.repo.tree), or records another
      tree than the working tree hashes to now. Prints [{path, fresh, reason}].

Redaction: session ids are stripped and local paths shortened (<repo>, ~) everywhere. In a raw
file a password assignment or a user/password@host connect string is replaced by <redacted>; in
a draft it is refused, naming the field, never the value.

Exit:  capture — 0 saved · 2 refused (bad input, outside the repo) · 3 could not run or save.
       write   — the derived status: 0 PASS · 1 FAIL · 2 BLOCKED · 3 UNKNOWN; a refused draft
       is 2 with nothing written (the message on stderr names the field).
       fresh   — 0 every result fresh · 1 one is stale · 2 one is unreadable or not a result ·
       3 git cannot hash the working tree.
"""
import hashlib
import json
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))
from result import RE_TASK, ROOT, Stop, context, rel, scrub, target, tree  # noqa: E402

NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
SESSION = [(re.compile(r"([?&])session=[0-9]+&?"), r"\1"), (re.compile(r"(f\?p=[^:\s]*:[^:\s]*:)[0-9]{6,}"), r"\1"),
           (re.compile(r"(?i)(session%3D)[0-9]+"), r"\1"),                       # the same, url-encoded
           (re.compile(r"(p_context=[^/\s&\"\\]+/[^/\s&\"\\]+/)[0-9]{6,}"), r"\1"),  # wwv_flow.accept?p_context=<app>/<page>/<session>
           (re.compile(r"(p_instance=)[0-9]{6,}"), r"\1"),
           (re.compile(r"(pageSubmissionId\\*\"\s*:\s*\\*\")[^\"]*?(\\*\")"), r"\1\2")]  # APEX's per-submit token
SECRET = [re.compile(r"(?i)(password\s*[=:]\s*)\S+"), re.compile(r"[A-Za-z0-9_$#]+/[^\s/@]+@(//)?[A-Za-z0-9][A-Za-z0-9_.-]*")]
DRAFT = {"runtime": {"check", "backend", "login", "criteria", "evidence", "target", "app"},
         "architecture": {"decisions", "redFlags", "missingInputs", "evidence", "app"}}
SKILL = {"runtime": "apex-sentinel", "architecture": "apexlang-architecture"}
LAYERS = {"A1": {"constraint"}, "A2": {"apx"}, "A3": {"entity", "flow", "integration"}, "B0": {"read"},
          "B1": {"entity"}, "B2": {"entity-sequence", "flow"}, "B3": {"integration"}}


class Refuse(Exception):
    pass


def clean(text):
    for rx, repl in SESSION:
        text = rx.sub(repl, text)
    return scrub(text)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def where(a):
    """(alias, task dir, settings, key): key is the alias, or alias.env for an environment.
    A runtime run on an app with environments names the one it verified (R-1)."""
    alias, task_dir, settings = target(a.app, a.task, a.env)
    envs = (settings or {}).get("environments")
    if a.env is None and isinstance(envs, dict) and envs and getattr(a, "gate", None) != "architecture" \
            and getattr(a, "kind", None) != "architecture":
        raise Stop("BLOCKED", "ENV_REQUIRED", f"app '{alias}' declares environments ({', '.join(envs)}): name the one verified with --env")
    return alias, task_dir, settings, alias + (f".{a.env}" if a.env else "")


def capture(a, rest):
    if not NAME.match(a.name or ""):
        raise Stop("BLOCKED", "BAD_NAME", f"<name> must match {NAME.pattern}")
    if not rest:
        raise Stop("BLOCKED", "NO_COMMAND", "nothing to run: evidence.py capture … <name> -- <command>...")
    alias, task_dir, _, key = where(a)
    raw = os.path.join(task_dir, "raw", f"{a.gate}-{key}")
    try:
        p = subprocess.run(rest, stdout=subprocess.PIPE, timeout=600)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise Stop("UNKNOWN", "COMMAND_DID_NOT_RUN", f"the command did not run: {e.__class__.__name__}")
    text, n = clean(p.stdout.decode("utf-8", "replace")), 0
    for rx in SECRET:
        text, k = rx.subn(lambda m: (m.group(1) if m.re is SECRET[0] else "") + "<redacted>", text)
        n += k
    path = os.path.join(raw, a.name)
    try:
        os.makedirs(raw, exist_ok=True)
        with open(path + ".tmp", "w", encoding="utf-8", newline="\n") as fh:
            fh.write(text)
        os.replace(path + ".tmp", path)
    except OSError as e:
        raise Stop("UNKNOWN", "STATE_UNWRITABLE", f"could not save the evidence: {e.__class__.__name__}")
    print(json.dumps({"evidence": {"kind": "file", "path": rel(path), "sha256": sha256(path)},
                      "exitCode": p.returncode, "redacted": n}, indent=2))
    return 0


def check_strings(node, where):
    """Strip session ids and local paths from every string; refuse one that still holds a secret."""
    if isinstance(node, dict):
        return {k: check_strings(v, f"{where}.{k}") for k, v in node.items()}
    if isinstance(node, list):
        return [check_strings(v, f"{where}[{i}]") for i, v in enumerate(node)]
    if isinstance(node, str):
        node = clean(node)
        if any(rx.search(node) for rx in SECRET):
            raise Refuse(f"{where} holds a password or a connect string: remove it (the value is not shown)")
    return node


def hash_files(node, where):
    """Every {kind: file} reference: inside the repo, present, and hashed now."""
    if isinstance(node, list):
        for i, v in enumerate(node):
            hash_files(v, f"{where}[{i}]")
    elif isinstance(node, dict):
        if node.get("kind") == "file":
            path = node.get("path", "")
            full = os.path.join(ROOT, path)
            if not path or rel(full) is None or os.path.isabs(path):
                raise Refuse(f"{where}.path must be a path inside the repository")
            if not os.path.isfile(full):
                raise Refuse(f"{where}.path: {path} does not exist")
            now = sha256(full)
            if node.get("sha256") not in (None, now):
                raise Refuse(f"{where}: {path} changed since it was cited (sha256 differs): capture it again")
            node["sha256"] = now
        for k, v in node.items():
            hash_files(v, f"{where}.{k}")


def proven(c):
    return any(e.get("kind") == "file" or (e.get("kind") in ("command", "sql") and e.get("exitCode") == 0)
               for e in c.get("evidence", []))


def runtime_status(d, settings):
    for i, c in enumerate(d.get("criteria", [])):
        st = c.get("status")
        if st not in ("PASS", "FAIL", "BLOCKED", "UNKNOWN", "NOT_RUN") or not isinstance(c.get("required"), bool) or not c.get("id"):
            raise Refuse(f"criteria[{i}] needs id, required (true/false) and a status other than CONFLICT")
        if st == "PASS" and not (c.get("observed") and proven(c)):
            raise Refuse(f"criteria[{i}] ({c['id']}) is PASS without observed and evidence (a file, or a command or query that exited 0)")
        if st == "NOT_RUN" and not c.get("notApplicableReason"):
            raise Refuse(f"criteria[{i}] ({c['id']}) is NOT_RUN without notApplicableReason")
    if not isinstance(d.get("backend"), dict) or not isinstance(d.get("login"), dict) or not d.get("check"):
        raise Refuse("a runtime draft needs check, backend {kind} and login {user, status}")
    if d["backend"].get("kind") == "none":
        return "BLOCKED", "NO_BROWSER", "no browser could be driven: nothing was verified"
    if d["login"].get("status") != "PASS":
        return "BLOCKED", "LOGIN_UNVERIFIED", "the test user's login was not verified (pw.sh login did not exit 0)"
    req = [c for c in d.get("criteria", []) if c["required"]]
    failed = [c["id"] for c in req if c["status"] == "FAIL"]
    if failed or all(c["status"] == "PASS" for c in req) and req:
        url = (d.get("target") or {}).get("runtimeUrl") or (settings or {}).get("runtimeUrl")
        if not url:
            raise Refuse("a PASS or FAIL names the runtime: target.runtimeUrl in the draft, or runtimeUrl in apex-sync.json")
        d.setdefault("target", {})["runtimeUrl"] = clean(url)
    if failed:
        return "FAIL", "REQUIRED_CRITERIA_FAILED", f"failed: {', '.join(failed)}"
    if req and all(c["status"] == "PASS" for c in req):
        return "PASS", "REQUIRED_CRITERIA_PASSED", f"{len(req)} required criteria passed: {', '.join(c['id'] for c in req)}"
    if not req:
        return "UNKNOWN", "NO_REQUIRED_CRITERIA", "no required criterion was recorded"
    open_ = [c["id"] for c in req if c["status"] != "PASS"]
    st = "BLOCKED" if all(c["status"] == "BLOCKED" for c in req if c["status"] != "PASS") else "UNKNOWN"
    return st, "REQUIRED_CRITERIA_OPEN", f"not passed: {', '.join(open_)}"


def architecture_status(d):
    for k in ("decisions", "redFlags", "missingInputs"):
        d.setdefault(k, [])
    for i, x in enumerate(d["decisions"]):
        if x.get("layer") not in LAYERS.get(x.get("branch"), ()) or x.get("type") != ("rule" if str(x.get("branch")).startswith("A") else "operation"):
            raise Refuse(f"decisions[{i}]: type, branch and layer do not agree (decision-record.md)")
        if x["layer"] in ("entity", "flow", "integration") and not x.get("package"):
            raise Refuse(f"decisions[{i}]: a {x['layer']} decision names its package")
        if not x.get("evidence") or not x.get("subject"):
            raise Refuse(f"decisions[{i}] needs a subject and evidence")
    if d["missingInputs"]:
        return "BLOCKED", "MISSING_INPUTS", f"{len(d['missingInputs'])} input(s) nobody has given"
    if d["redFlags"]:
        return "FAIL", "RED_FLAGS", ", ".join(sorted({f.get('code', '?') for f in d["redFlags"]}))
    scanned = any(e.get("kind") == "command" and e.get("exitCode") in (0, 1) for e in d.get("evidence", []))
    if not scanned:
        return "UNKNOWN", "NO_SCAN", "no red-flag scan in evidence (arch-scan.py, with its exit code)"
    if not d["decisions"]:
        return "UNKNOWN", "NO_DECISIONS", "no decision recorded"
    return "PASS", "DECISIONS_ON_EVIDENCE", f"{len(d['decisions'])} decision(s) on evidence; the red-flag scan found nothing"


def write(a):
    alias, task_dir, settings, key = where(a)
    try:
        with open(a.draft, encoding="utf-8") as fh:
            d = json.load(fh)
    except (OSError, ValueError) as e:
        raise Refuse(f"the draft is not readable JSON: {e.__class__.__name__}")
    if not isinstance(d, dict):
        raise Refuse("the draft is a JSON object")
    extra = set(d) - DRAFT[a.kind]
    if extra:
        raise Refuse(f"not a draft field: {', '.join(sorted(extra))} (kind, status, reasons and context are the script's)")
    d = check_strings(d, "draft")
    hash_files(d, "draft")
    status, code, msg = runtime_status(d, settings) if a.kind == "runtime" else architecture_status(d)
    ctx = context(a.task, SKILL[a.kind])
    ctx["producer"]["method"] = "agent"
    if d.get("target"):
        ctx["target"] = d.pop("target")
    app = {"appAlias": alias, **{k: v for k, v in (d.pop("app", None) or {}).items() if k in ("appId", "mmdVersion")}}
    if a.env:
        app["environment"] = a.env
    if "appId" not in app and isinstance((settings or {}).get("appId"), int):
        app["appId"] = settings["appId"]
    out = {"kind": f"{a.kind}-result", "schemaVersion": 1, "status": status,
           "reasons": [{"code": code, "message": msg}], "app": app, "context": ctx, **d}
    name = f"runtime-{key}.json" if a.kind == "runtime" else "architecture.json"
    doc = json.dumps(out, indent=2)
    for dest in (task_dir, os.environ.get("RESULT_CAPTURE_DIR")):
        if dest:
            f = os.path.join(dest, name if dest == task_dir else f"{os.getpid()}-{name}")
            try:
                with open(f + ".tmp", "w", encoding="utf-8", newline="\n") as fh:
                    fh.write(doc + "\n")
                os.replace(f + ".tmp", f)
            except OSError as e:
                if dest == task_dir:
                    raise Stop("UNKNOWN", "STATE_UNWRITABLE", f"could not write the result: {e.__class__.__name__}")
    print(doc)
    print(f"{a.kind}: {status}; {msg}", file=sys.stderr)
    return {"PASS": 0, "FAIL": 1, "BLOCKED": 2}.get(status, 3)


def fresh(a):
    if not RE_TASK.match(a.task):
        raise Stop("BLOCKED", "BAD_TASK", f"--task must match {RE_TASK.pattern}")
    now = tree()
    if not now:
        raise Stop("UNKNOWN", "NO_TREE", "git cannot hash the working tree here, so no result can be proven fresh")
    out, rc = [], 0
    for f in a.results:
        try:
            with open(f, encoding="utf-8") as fh:
                ctx = json.load(fh)["context"]
            task, then = ctx["task"], ctx["repo"].get("tree")
        except (OSError, ValueError, KeyError, TypeError, AttributeError):
            raise Stop("BLOCKED", "NOT_A_RESULT", f"{os.path.basename(f)} is not a readable result with a context")
        reason = (f"made for task {task}, not {a.task}" if task != a.task
                  else "records no working tree: it cannot be proven fresh" if not then
                  else "the working tree changed since it was made" if then != now else "")
        out.append({"path": rel(f) or os.path.basename(f), "fresh": not reason, **({"reason": reason} if reason else {})})
        rc = rc or (1 if reason else 0)
    print(json.dumps(out, indent=2))
    return rc


def main(argv):
    import argparse
    rest = []
    if "--" in argv:
        i = argv.index("--")
        argv, rest = argv[:i], argv[i + 1:]
    ap = argparse.ArgumentParser(description="write the runtime and architecture results, and their raw evidence")
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("capture")
    c.add_argument("--gate", required=True, choices=["runtime", "architecture"])
    c.add_argument("--app")
    c.add_argument("--env")
    c.add_argument("--task", required=True)
    c.add_argument("name")
    w = sub.add_parser("write")
    w.add_argument("--kind", required=True, choices=["runtime", "architecture"])
    w.add_argument("--app")
    w.add_argument("--env")
    w.add_argument("--task", required=True)
    w.add_argument("draft")
    f = sub.add_parser("fresh")
    f.add_argument("--task", required=True)
    f.add_argument("results", nargs="+")
    a = ap.parse_args(argv)
    try:
        return capture(a, rest) if a.cmd == "capture" else write(a) if a.cmd == "write" else fresh(a)
    except Refuse as e:
        print(f"evidence: refused — {e}; nothing written", file=sys.stderr)
        return 2
    except Stop as s:
        print(f"evidence: {s.status} ({s.code}) — {s.message}", file=sys.stderr)
        return {"BLOCKED": 2}.get(s.status, 3)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
