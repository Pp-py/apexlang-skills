"""result — what the tool-produced results share (apex-ux's ui-result, apex-security's
security-result): the envelope's context, the app and its config, and where a result lands.

  scrub()     a passed-on message with the repo root and the home dir shortened
  tree()      the working tree as a git tree hash (tracked + untracked, ignored left out)
  context()   the run's context: task, repo commit, dirty flag and tree, framework version, UTC time
  target()    --app / --task → app alias, the task dir (<evidenceDir>/<task>/) and the app's
              settings from apex-sync.json, or a Stop
  write()     the result on stdout and, with --task, in the task dir (and in
              $RESULT_CAPTURE_DIR, for the contract tier)
"""
import atexit
import datetime
import json
import os
import re
import shutil
import subprocess
import sys

FRAMEWORK_VERSION = "0.8.0"   # the apexlang-skills release (.claude-plugin/plugin.json)
RE_ALIAS = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$")   # common.schema.json appAlias
RE_TASK = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")   # common.schema.json taskId
RE_CONN = re.compile(r"^[^/@\s\\\"'-][^/@\s\\\"']{0,127}$")   # common.schema.json connectionName, and no leading '-' (it would read as an option)


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


def tree():
    """The working tree as git would commit it with `git add -A` — tracked and untracked
    files, ignored ones left out — hashed through a copy of the index, so the real index is
    never touched. The same hash apex-sync-check.sh records. None when git cannot say."""
    gd = git("rev-parse", "--absolute-git-dir")
    if not gd:
        return None
    idx = os.path.join(gd, f"apex-sync-tree.{os.getpid()}.idx")
    env = dict(os.environ, GIT_INDEX_FILE=idx)
    env.pop("GIT_ATTR_NOSYSTEM", None)
    try:
        if os.path.isfile(os.path.join(gd, "index")):
            shutil.copy2(os.path.join(gd, "index"), idx)   # its mtime kept: git judges racy entries by it
        for args in (["add", "-A"], ["write-tree"]):
            p = subprocess.run(["git", "-C", ROOT] + args, capture_output=True, text=True, env=env, timeout=120)
            if p.returncode != 0:
                return None
        t = p.stdout.strip()
        return t if re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", t) else None
    except (OSError, subprocess.TimeoutExpired):
        return None
    finally:
        for f in (idx, idx + ".lock"):
            try:
                os.remove(f)
            except OSError:
                pass


RE_RUN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}")      # a run id (APEX_RUN_ID, delivery.py --run)


def context(task, skill):
    head = git("rev-parse", "HEAD")
    repo = {"commit": head if head and re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", head) else None,
            "dirty": bool(git("status", "--porcelain"))}
    t = tree()
    if t:
        repo["tree"] = t
    ctx = {"task": task,
           "repo": repo,
           "frameworkVersion": FRAMEWORK_VERSION,
           "timestamp": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
           "producer": {"skill": skill, "method": "tool"}}
    run = os.environ.get("APEX_RUN_ID", "")
    if RE_RUN.fullmatch(run):       # GAP-14: the attempt this result belongs to; an invalid id is left out, never guessed
        ctx["runId"] = run
    return ctx


def target(app, task, env=None):
    """(alias or None, task dir or None, settings). The alias: --app, else apex-sync.json's one
    app. settings: the app's own keys over the top-level defaults — and, with env, that
    environment's over both — {} when there is no config; None when the config lists several
    apps and none was named. settings["environments"] lists the app's environments, if any."""
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
    settings = app_settings(cfg, app)
    if env is not None:
        if not RE_ALIAS.match(env):
            raise Stop("BLOCKED", "BAD_ENV", f"--env must match {RE_ALIAS.pattern}")
        envs = (settings or {}).get("environments")
        if not isinstance(envs, dict) or not isinstance(envs.get(env), dict):
            raise Stop("BLOCKED", "ENV_UNKNOWN", f"apex-sync.json declares no environment '{env}' for this app")
        settings = {**settings, **envs[env]}
    if task is None:
        return app, None, settings
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
    return app, os.path.join(base, task), settings


def runtime_target(app, task, env):
    """target() for a check that ran against one Builder: (alias, task dir, settings, key) — key
    is the alias, or alias.env. An app with environments needs the one it ran against (R-1)."""
    alias, task_dir, settings = target(app, task, env)
    envs = (settings or {}).get("environments")
    if env is None and isinstance(envs, dict) and envs:
        raise Stop("BLOCKED", "ENV_REQUIRED", f"app '{alias or app}' declares environments ({', '.join(envs)}): name the one verified with --env")
    return alias, task_dir, settings, (alias + f".{env}" if alias and env else alias)


def app_settings(cfg, app):
    """The settings apex-sync.json gives one app: its own entry over the top-level defaults
    (the guard's reading, setup.md §1). A named app the file does not declare is a Stop."""
    if not isinstance(cfg, dict) or not cfg:
        return {}
    apps = cfg.get("apps")
    if not isinstance(apps, list):
        if app is not None and cfg.get("appAlias") not in (None, app):
            raise Stop("BLOCKED", "APP_UNKNOWN", f"apex-sync.json declares no app '{app}'")
        return dict(cfg)
    if app is None:
        return None
    own = [a for a in apps if isinstance(a, dict) and a.get("appAlias") == app]
    if not own:
        raise Stop("BLOCKED", "APP_UNKNOWN", f"apex-sync.json declares no app '{app}'")
    merged = {k: v for k, v in cfg.items() if k != "apps"}
    merged.update(own[0])
    return merged


_HELD = {}              # lock path -> the destination it guards, while this process holds it
_REFUSED = set()        # destinations this process was refused: write() must not put its own result there


def _alive(pid):
    """Is a process with this pid running? (os.kill(pid, 0) would terminate it on Windows.)"""
    if os.name == "nt":
        import ctypes
        h = ctypes.windll.kernel32.OpenProcess(0x1000, False, pid)      # PROCESS_QUERY_LIMITED_INFORMATION
        if h:
            ctypes.windll.kernel32.CloseHandle(h)
        return bool(h)
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def release(lock=None):
    """Remove the lock(s) this process holds (all of them, or one)."""
    for path in [lock] if lock else list(_HELD):
        if _HELD.pop(path, None) is not None:
            try:
                os.remove(path)
            except OSError:
                pass


atexit.register(release)


def claim(task_dir, name, companions=()):
    """GAP-14 B. Before the work that can fail, a producer takes its destination <task_dir>/<name>: it creates
    <name>.lock exclusively (pid and run id) and moves the current result to <name>.prev. A producer that dies
    afterwards leaves no file that reads as fresh. A live lock, or one that cannot be judged, is BLOCKED
    CLAIM_HELD (never guessed); a lock whose pid is gone is replaced, with a note on stderr. If the old result
    cannot be moved the producer stops BLOCKED STATE_UNWRITABLE — it never goes on as if it had been invalidated.
    `companions` are suffixes of files published with it (an `.exit.json`): moved the same way.
    The lock is removed by write() and at exit. Local to one machine. A producer with no task dir has nothing to claim."""
    if not task_dir:
        return
    dest = os.path.join(task_dir, name)
    lock = dest + ".lock"
    refuse = lambda code, msg: (_REFUSED.add(dest), (_ for _ in ()).throw(Stop("BLOCKED", code, msg)))      # noqa: E731
    me = f"{os.getpid()} {os.environ.get('APEX_RUN_ID', '-')}\n"
    for attempt in (0, 1):
        try:
            fd = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
            break
        except FileExistsError:
            try:
                with open(lock, encoding="utf-8") as fh:
                    pid = int(fh.read().split()[0])
            except (OSError, ValueError, IndexError):
                refuse("CLAIM_HELD", f"{name}.lock exists and cannot be read: another producer may be writing {name}; "
                                     f"remove the lock only when no producer is running")
            if pid != os.getpid() and _alive(pid):
                refuse("CLAIM_HELD", f"{name}.lock is held by a running producer (pid {pid}): wait for it, or stop it")
            if attempt:
                refuse("CLAIM_HELD", f"{name}.lock could not be replaced")
            print(f"claim: stale lock of pid {pid} (not running) on {name}: replaced", file=sys.stderr)
            try:
                os.remove(lock)
            except OSError as e:
                refuse("STATE_UNWRITABLE", f"cannot replace the stale {name}.lock: {e.__class__.__name__}")
        except OSError as e:
            refuse("STATE_UNWRITABLE", f"cannot create {name}.lock: {e.__class__.__name__}")
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(me)
    _HELD[lock] = dest
    try:
        for suffix in ("",) + tuple(companions):
            if os.path.exists(dest + suffix):
                os.replace(dest + suffix, dest + suffix + ".prev")
    except OSError as e:
        release(lock)
        refuse("STATE_UNWRITABLE", f"cannot move the previous {name} out of the way ({e.__class__.__name__}): "
                                   f"not going on as if it were invalidated")


def write(result, task_dir, name):
    """stdout always; the task dir and the capture dir when set. Returns the exit code."""
    doc = json.dumps(result, indent=2)
    print(doc)
    for d in (task_dir, os.environ.get("RESULT_CAPTURE_DIR")):
        if not d:
            continue
        if d == task_dir and os.path.join(task_dir, name) in _REFUSED:    # refused a claim: the other producer's file stays
            print(f"{result['kind']}: {name} is not written: this producer was refused its destination", file=sys.stderr)
            continue
        f = os.path.join(d, name if d == task_dir else f"{os.getpid()}-{name}")
        try:
            with open(f + ".tmp", "w", encoding="utf-8") as fh:
                fh.write(doc + "\n")
            os.replace(f + ".tmp", f)
        except OSError as e:
            print(f"{result['kind']}: could not write {scrub(f)}: {e.__class__.__name__}", file=sys.stderr)
            if d == task_dir:
                return 3                    # a gate whose result is not on disk has no verdict
    if task_dir:
        release(os.path.join(task_dir, name) + ".lock")        # the result is published: the claim ends
    failed = [c["id"] for c in result["criteria"] if c["status"] == "FAIL"]
    print(f"{result.get('scope') or result['kind']}: {result['status']}"
          + (f"; FAIL {', '.join(failed)}" if failed else "")
          + f"; {result['reasons'][0]['message']}", file=sys.stderr)
    return {"PASS": 0, "FAIL": 1, "BLOCKED": 2}.get(result["status"], 3)
