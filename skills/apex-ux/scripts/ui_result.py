"""ui_result — what ux-scan.py and ux-check.py share: the ui-result envelope
(framework/schemas/ui-result.schema.json) and where it lands.

  scrub()     a passed-on message with the repo root and the home dir shortened
  context()   the run's context: task, repo commit and dirty flag, framework version, UTC time
  target()    --app / --task → app alias and the task dir (<evidenceDir>/<task>/), or a Stop
  write()     the result on stdout and, with --task, in the task dir (and in
              $UX_RESULT_CAPTURE_DIR, for the contract tier)
"""
import datetime
import json
import os
import re
import subprocess
import sys

FRAMEWORK_VERSION = "0.6.1"   # the apexlang-skills release (.claude-plugin/plugin.json)
RE_ALIAS = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$")   # common.schema.json appAlias
RE_TASK = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")   # common.schema.json taskId


class Stop(Exception):
    """A run that ends without a verdict on the criteria: status, reason code, message."""
    def __init__(self, status, code, message):
        super().__init__(message)
        self.status, self.code, self.message = status, code, message


def git(*args):
    try:
        p = subprocess.run(["git"] + list(args), capture_output=True, text=True, timeout=30)
        return p.stdout.strip() if p.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired):
        return None


ROOT = os.path.abspath(git("rev-parse", "--show-toplevel") or os.getcwd())


def rel(path):
    """path relative to the repo root, forward slashes — None when it lies outside it."""
    try:
        r = os.path.relpath(os.path.abspath(path), ROOT).replace("\\", "/")
    except ValueError:                      # another drive, on Windows
        return None
    return None if r == ".." or r.startswith("../") or os.path.isabs(r) else r


def scrub(text):
    """A message passed on from another tool, with local paths shortened as the guard does:
    the repo root to <repo>, the home dir to ~ (in both the native and the forward-slash form)."""
    home = os.path.expanduser("~")
    for prefix, short in ((ROOT, "<repo>"), (home, "~")):
        if prefix and prefix not in ("/", "~"):
            for form in {prefix, prefix.replace("\\", "/")}:
                text = text.replace(form, short)
    return text


def context(task):
    head = git("rev-parse", "HEAD")
    return {"task": task,
            "repo": {"commit": head if head and re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", head) else None,
                     "dirty": bool(git("status", "--porcelain"))},
            "frameworkVersion": FRAMEWORK_VERSION,
            "timestamp": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "producer": {"skill": "apex-ux", "method": "tool"}}


def target(app, task):
    """(alias or None, task dir or None). The alias: --app, else apex-sync.json's one app."""
    if task is not None and not RE_TASK.match(task):
        raise Stop("BLOCKED", "BAD_TASK", f"--task must match {RE_TASK.pattern}")
    if app is not None and not RE_ALIAS.match(app):
        raise Stop("BLOCKED", "BAD_APP", f"--app must match {RE_ALIAS.pattern}")
    cfg, path = {}, os.path.join(ROOT, "apex-sync.json")
    if os.path.isfile(path):
        try:
            with open(path, encoding="utf-8") as fh:
                cfg = json.load(fh)
        except OSError as e:
            raise Stop("BLOCKED", "BAD_CONFIG", f"apex-sync.json is unreadable: {e.__class__.__name__}")
        except ValueError as e:             # json's message: line and column, no path
            raise Stop("BLOCKED", "BAD_CONFIG", f"apex-sync.json is not valid JSON: {e}")
    if task is None:
        return app, None
    if app is None:
        if cfg.get("apps"):
            raise Stop("BLOCKED", "APP_REQUIRED", "apex-sync.json lists several apps: pass --app <alias>")
        app = cfg.get("appAlias")
        if not isinstance(app, str) or not RE_ALIAS.match(app):
            raise Stop("BLOCKED", "APP_REQUIRED", "--task needs --app <alias> (or an apex-sync.json naming the app)")
    ev = cfg.get("evidenceDir", ".apex-evidence")
    if not isinstance(ev, str) or not ev or ev.startswith("/") or "\\" in ev or ":" in ev or ".." in ev.split("/"):
        raise Stop("BLOCKED", "BAD_CONFIG", "apex-sync.json: evidenceDir must be a relative directory below the repo root")
    base = os.path.join(ROOT, ev)
    try:
        os.makedirs(os.path.join(base, task), exist_ok=True)
        gi = os.path.join(base, ".gitignore")
        if not os.path.exists(gi):          # evidence is never committed by accident
            with open(gi, "w", encoding="utf-8") as fh:
                fh.write("*\n")
    except OSError as e:
        raise Stop("BLOCKED", "STATE_UNWRITABLE", f"cannot create the evidence dir {ev}: {e.__class__.__name__}")
    return app, os.path.join(base, task)


def write(result, task_dir, name):
    """stdout always; the task dir and the capture dir when set. Returns the exit code."""
    doc = json.dumps(result, indent=2)
    print(doc)
    for d in (task_dir, os.environ.get("UX_RESULT_CAPTURE_DIR")):
        if not d:
            continue
        f = os.path.join(d, name if d == task_dir else f"{os.getpid()}-{name}")
        try:
            with open(f + ".tmp", "w", encoding="utf-8") as fh:
                fh.write(doc + "\n")
            os.replace(f + ".tmp", f)
        except OSError as e:
            print(f"ui-result: could not write {f}: {e}", file=sys.stderr)
            if d == task_dir:
                return 3                    # a gate whose result is not on disk has no verdict
    failed = [c["id"] for c in result["criteria"] if c["status"] == "FAIL"]
    print(f"{result['scope']}: {result['status']}"
          + (f"; FAIL {', '.join(failed)}" if failed else "")
          + f"; {result['reasons'][0]['message']}", file=sys.stderr)
    return {"PASS": 0, "FAIL": 1, "BLOCKED": 2}.get(result["status"], 3)
