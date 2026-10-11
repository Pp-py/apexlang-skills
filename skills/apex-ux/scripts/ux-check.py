#!/usr/bin/env python3
"""ux-check — the runtime half of apex-ux's FAIL criteria, in the page the agent has open.

Usage: python3 ux-check.py [--app <alias>] [--dialog <selector>]... [--raw <file>]

Run it after `pw.sh [--app X] login` and `pw.sh goto <page>`: it checks the page the
session already holds, through apex-sentinel's pw.sh (never a copy of it).

Checks (criteria/common.md), with the vendored axe-core (vendor/axe-core.lock.json):
  UX-AXE-SERIOUS    no serious/critical violation of a WCAG 2.x A/AA rule — on the page,
                    and with each --dialog open, in every frame
  UX-ITEM-NAME      axe's naming rules for fields (label, select-name, aria-input-field-name)
  UX-CONTROL-NAME   axe's naming rules for controls (button-name, link-name, input-button-name)
  UX-DIALOG-FOCUS   per --dialog opener: focus moves in, Tab and Shift+Tab stay in, Esc
                    closes, focus returns to the opener. No --dialog → NOT_RUN.
  advisories        UX-AXE-MINOR (moderate/minor), UX-AXE-REVIEW (axe "incomplete")

Output: one JSON document on stdout (provisional until the ui-result schema, UX-5) with
rule, impact, selectors and help per finding — never the node's HTML, which can hold
personal data. --raw <file> keeps axe's full output, its sha256 in the result.
Exit:   0 PASS · 1 FAIL · 2 BLOCKED (axe missing or not matching its lock, pw.sh refused,
        a --dialog selector not found, the page is a login page) · 3 UNKNOWN (pw.sh
        reopened a dead session, no verdict, timeout) — never read 3 as PASS.
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
VENDOR = os.environ.get("UX_AXE_DIR") or os.path.join(HERE, "..", "vendor")
PW = os.path.join(HERE, "..", "..", "apex-sentinel", "scripts", "pw.sh")
TEMPLATE = os.path.join(HERE, "ux-check.js")
TAGS = ["wcag2a", "wcag2aa", "wcag21a", "wcag21aa", "wcag22aa"]
ITEM_RULES = {"label", "select-name", "aria-input-field-name"}
CONTROL_RULES = {"button-name", "link-name", "input-button-name"}
FAIL_IDS = ["UX-AXE-SERIOUS", "UX-ITEM-NAME", "UX-CONTROL-NAME", "UX-DIALOG-FOCUS"]
TIMEOUT = int(os.environ.get("UX_CHECK_TIMEOUT", "300"))


class Stop(Exception):
    """A run that ends without a verdict on the criteria: status and reason."""
    def __init__(self, status, reason):
        super().__init__(reason)
        self.status, self.reason = status, reason


def redact(url):
    url = re.sub(r"([?&]session=)[^&#]*", r"\1<redacted>", url or "")
    return re.sub(r"(f\?p=[^:]*:[^:]*:)[^:&#]+", r"\1<redacted>", url)


def load_axe():
    try:
        with open(os.path.join(VENDOR, "axe-core.lock.json"), encoding="utf-8") as fh:
            lock = json.load(fh)
        with open(os.path.join(VENDOR, lock["file"]), "rb") as fh:
            src = fh.read()
    except (OSError, ValueError, KeyError) as e:
        raise Stop("BLOCKED", f"axe-core or its lock is missing or unreadable: {e}")
    if hashlib.sha256(src).hexdigest() != lock.get("sha256"):
        raise Stop("BLOCKED", "axe-core does not match the sha256 in its lock — never run an unverified engine")
    return src.decode("utf-8"), lock


def run_page(app, axe_src, dialogs):
    with open(TEMPLATE, encoding="utf-8") as fh:
        body = fh.read()
    opts = {"tags": TAGS, "dialogs": dialogs}
    code = ("async (page) => {\n  const AXE = %s;\n  const OPTS = %s;\n  return (%s)(page, AXE, OPTS);\n}\n"
            % (json.dumps(axe_src), json.dumps(opts), body))
    fd, snip = tempfile.mkstemp(prefix="ux-check-", suffix=".js")   # mode 600
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(code)
        # bash from PATH, never a bare name Windows would resolve to System32's WSL launcher;
        # forward slashes, which Git Bash and node both read
        cmd = ([shutil.which("bash") or "bash", PW.replace("\\", "/")] + (["--app", app] if app else [])
               + ["run-code", "--raw", "--filename", snip.replace("\\", "/")])
        try:
            p = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8",
                               errors="replace", timeout=TIMEOUT)
        except subprocess.TimeoutExpired:
            raise Stop("UNKNOWN", f"pw.sh did not answer within {TIMEOUT}s")
        except OSError as e:
            raise Stop("BLOCKED", f"cannot run pw.sh: {e}")
    finally:
        try:
            os.remove(snip)
        except OSError:
            pass
    tail = (p.stderr or p.stdout or "").strip().splitlines()[-1:] or [""]
    if p.returncode == 2:
        raise Stop("BLOCKED", "pw.sh refused: " + tail[0][:200])
    if p.returncode == 3:
        raise Stop("UNKNOWN", "pw.sh reopened a dead session: the page is logged out — log in, navigate, re-run")
    if p.returncode != 0:
        raise Stop("UNKNOWN", f"pw.sh exit {p.returncode}: " + tail[0][:200])
    lines = [ln.strip() for ln in p.stdout.splitlines() if ln.strip()]
    try:
        v = json.loads(lines[-1])
        if isinstance(v, str):                 # the CLI may print the returned string quoted
            v = json.loads(v)
        if not isinstance(v, dict) or "verdict" not in v:
            raise ValueError("no verdict")
    except (IndexError, ValueError):
        raise Stop("UNKNOWN", "the browser returned no verdict")
    return v


def evaluate(v, dialogs):
    crit = {k: [] for k in FAIL_IDS}
    advisories, blocked, seen = [], [], set()
    for run in v.get("runs", []):
        where = run.get("where", "page")
        for viol in run.get("violations", []):
            f = {"rule": viol.get("id"), "impact": viol.get("impact"), "where": where,
                 "frame": redact(run.get("frame")), "count": len(viol.get("nodes", [])),
                 "targets": [" ".join(map(str, n.get("target", []))) for n in viol.get("nodes", [])][:10],
                 "help": viol.get("helpUrl")}
            key = (f["rule"], f["frame"], tuple(f["targets"]))
            if key in seen:            # the page's own defect, seen again with a dialog open
                continue
            seen.add(key)
            if f["rule"] in ITEM_RULES:
                crit["UX-ITEM-NAME"].append(f)
            if f["rule"] in CONTROL_RULES:
                crit["UX-CONTROL-NAME"].append(f)
            if f["impact"] in ("serious", "critical"):
                crit["UX-AXE-SERIOUS"].append(f)
            elif f["rule"] not in ITEM_RULES | CONTROL_RULES:
                advisories.append(dict(f, id="UX-AXE-MINOR"))
        for inc in run.get("incomplete", []):
            advisories.append({"id": "UX-AXE-REVIEW", "rule": inc.get("id"), "impact": inc.get("impact"),
                               "where": where, "count": len(inc.get("nodes", [])), "help": inc.get("helpUrl")})
    for d in v.get("dialogs", []):
        if not d.get("found"):
            blocked.append(d.get("selector"))
            continue
        failed = [k for k in ("opened", "focusIn", "tabStays", "shiftTabStays", "escCloses", "focusReturns")
                  if not d.get(k)]
        if failed:
            crit["UX-DIALOG-FOCUS"].append({"selector": d.get("selector"), "failed": failed})
    out = []
    for k in FAIL_IDS:
        status = "FAIL" if crit[k] else "PASS"
        if k == "UX-DIALOG-FOCUS" and (not dialogs or (blocked and not crit[k])):
            status = "NOT_RUN"         # nothing opened, or an opener missing: not a PASS
        out.append({"id": k, "status": status, "findings": crit[k]})
    return out, advisories, blocked


def main(argv):
    ap = argparse.ArgumentParser(description="apex-ux runtime checks on the page pw.sh holds")
    ap.add_argument("--app")
    ap.add_argument("--dialog", action="append", default=[], help="selector of a control that opens a dialog")
    ap.add_argument("--raw", help="write axe's full output here (evidence dir)")
    a = ap.parse_args(argv)
    result = {"tool": "ux-check", "format": "provisional-1", "scope": "runtime", "status": "UNKNOWN",
              "url": "", "engine": None, "criteria": [], "advisories": [], "errors": [], "reason": ""}
    try:
        axe_src, lock = load_axe()
        result["engine"] = {"axe-core": lock.get("version"), "sha256": lock.get("sha256")}
        v = run_page(a.app, axe_src, a.dialog)
        result["url"] = redact(v.get("url"))
        if v["verdict"] == "NOT-LOGGED-IN":
            raise Stop("BLOCKED", "the session is on a login page — run pw.sh login, then goto the page")
        if v["verdict"] != "OK":
            raise Stop("UNKNOWN", f"unexpected verdict {v['verdict']!r}")
        result["errors"] = [dict(e, frame=redact(e.get("frame"))) for e in v.get("errors", [])]
        if not v.get("runs"):
            raise Stop("UNKNOWN", "axe ran in no frame")
        if a.raw:
            data = json.dumps(v, indent=1).encode("utf-8")
            with open(a.raw, "wb") as fh:
                fh.write(data)
            result["raw"] = {"path": a.raw, "sha256": hashlib.sha256(data).hexdigest()}
        result["criteria"], result["advisories"], blocked = evaluate(v, a.dialog)
        if blocked:
            raise Stop("BLOCKED", "dialog opener not found: " + ", ".join(blocked))
        failed = [c["id"] for c in result["criteria"] if c["status"] == "FAIL"]
        result["status"] = "FAIL" if failed else "PASS"
    except Stop as s:
        result["status"], result["reason"] = s.status, s.reason
    return emit(result)


def emit(result):
    print(json.dumps(result, indent=2))
    failed = [c["id"] for c in result["criteria"] if c["status"] == "FAIL"]
    print(f"ux-check: {result['status']}"
          + (f"; FAIL {', '.join(failed)}" if failed else "")
          + (f"; {result['reason']}" if result["reason"] else ""), file=sys.stderr)
    return {"PASS": 0, "FAIL": 1, "BLOCKED": 2}.get(result["status"], 3)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
