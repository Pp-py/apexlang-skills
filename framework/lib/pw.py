"""pw — how the runtime checks drive the browser: through apex-sentinel's pw.sh, never a copy.

  redact(url)              the URL without its APEX session (session= dropped, f?p's field emptied)
  pw(app, args, env)       run pw.sh [--app X] [--env E] <args>; the CompletedProcess, or a Stop
  run_code(app, code, …)   pw.sh run-code --raw --filename <a mode-600 snippet, deleted after>;
                           the JSON verdict the snippet returned, or a Stop (pw.sh exit 2 →
                           BLOCKED, 3 → UNKNOWN: it reopened a dead session, logged out)
"""
import json
import os
import re
import shutil
import subprocess
import tempfile

from result import Stop, scrub

PW = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "skills", "apex-sentinel", "scripts", "pw.sh")


def redact(url):
    url = re.sub(r"([?&])session=[^&#]*&?", r"\1", url or "")
    url = re.sub(r"[?&]+(#|$)", r"\1", url)
    return re.sub(r"(f\?p=[^:&#]*:[^:&#]*:)[^:&#]*", r"\1", url)


ENV = None   # the environment the checks run against (R-1): set from --env by the caller


def pw(app, args, env=None, timeout=300):
    # bash from PATH, never a bare name Windows would resolve to System32's WSL launcher;
    # forward slashes, which Git Bash and node both read
    cmd = ([shutil.which("bash") or "bash", PW.replace("\\", "/")] + (["--app", app] if app else [])
           + (["--env", ENV] if ENV else []) + list(args))
    try:
        return subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace",
                              timeout=timeout, env=env)
    except subprocess.TimeoutExpired:
        raise Stop("UNKNOWN", "TIMEOUT", f"pw.sh did not answer within {timeout}s")
    except OSError as e:
        raise Stop("BLOCKED", "PW_REFUSED", f"cannot run pw.sh: {e.__class__.__name__}")


def run_code(app, code, prefix, timeout=300, env=None):
    fd, snip = tempfile.mkstemp(prefix=prefix, suffix=".js")   # mode 600
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(code)
        p = pw(app, ["run-code", "--raw", "--filename", snip.replace("\\", "/")], env, timeout)
    finally:
        try:
            os.remove(snip)
        except OSError:
            pass
    tail = (p.stderr or p.stdout or "").strip().splitlines()[-1:] or [""]
    if p.returncode == 2:
        raise Stop("BLOCKED", "PW_REFUSED", "pw.sh refused: " + scrub(redact(tail[0]))[:200])
    if p.returncode == 3:
        raise Stop("UNKNOWN", "DEAD_SESSION", "pw.sh reopened a dead session: the page is logged out - log in, navigate, re-run")
    if p.returncode != 0:
        raise Stop("UNKNOWN", "PW_ERROR", f"pw.sh exit {p.returncode}: " + scrub(redact(tail[0]))[:200])
    lines = [ln.strip() for ln in p.stdout.splitlines() if ln.strip()]
    try:
        v = json.loads(lines[-1])
        if isinstance(v, str):                 # the CLI may print the returned string quoted
            v = json.loads(v)
        if not isinstance(v, dict) or "verdict" not in v:
            raise ValueError("no verdict")
    except (IndexError, ValueError):
        raise Stop("UNKNOWN", "NO_VERDICT", "the browser returned no verdict")
    return v
