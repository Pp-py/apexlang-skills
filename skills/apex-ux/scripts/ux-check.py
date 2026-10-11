#!/usr/bin/env python3
"""ux-check — the runtime half of apex-ux's FAIL criteria, in the page the agent has open.

Usage: python3 ux-check.py [--app <alias>] [--task <id>] [--dialog <selector>]... [--raw <file>]

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

Output: a ui-result (framework/schemas/ui-result.schema.json, scope runtime) on stdout, and
with --task in <evidenceDir>/<task>/ui-<alias>-runtime-<page>.json — rule, impact, selectors
and help per finding, never the node's HTML, which can hold personal data. axe's full output
goes to --raw <file> (with --task, by default <evidenceDir>/<task>/raw/ui-<alias>/axe-<page>.json),
cited in evidence with its sha256.
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
from urllib.parse import urlsplit

from ui_result import Stop, context, rel, scrub, target, write

HERE = os.path.dirname(os.path.abspath(__file__))
VENDOR = os.environ.get("UX_AXE_DIR") or os.path.join(HERE, "..", "vendor")
PW = os.path.join(HERE, "..", "..", "apex-sentinel", "scripts", "pw.sh")
TEMPLATE = os.path.join(HERE, "ux-check.js")
TAGS = ["wcag2a", "wcag2aa", "wcag21a", "wcag21aa", "wcag22aa"]
ITEM_RULES = {"label", "select-name", "aria-input-field-name"}
CONTROL_RULES = {"button-name", "link-name", "input-button-name"}
FAIL_IDS = ["UX-AXE-SERIOUS", "UX-ITEM-NAME", "UX-CONTROL-NAME", "UX-DIALOG-FOCUS"]
TIMEOUT = int(os.environ.get("UX_CHECK_TIMEOUT", "300"))


def redact(url):
    """The URL without its APEX session: the session= parameter dropped, f?p's third field emptied."""
    url = re.sub(r"([?&])session=[^&#]*&?", r"\1", url or "")
    url = re.sub(r"[?&]+(#|$)", r"\1", url)
    return re.sub(r"(f\?p=[^:&#]*:[^:&#]*:)[^:&#]*", r"\1", url)


def page_name(url):
    """A file-name part for the page: the last path segment, or f?p's page; 'page' otherwise."""
    m = re.search(r"f\?p=[^:&#]*:([^:&#]+)", url or "")
    seg = m.group(1) if m else urlsplit(url or "").path.rstrip("/").rsplit("/", 1)[-1]
    seg = re.sub(r"[^A-Za-z0-9_-]+", "-", seg).strip("-")[:40]
    return seg or "page"


def load_axe():
    try:
        with open(os.path.join(VENDOR, "axe-core.lock.json"), encoding="utf-8") as fh:
            lock = json.load(fh)
        with open(os.path.join(VENDOR, lock["file"]), "rb") as fh:
            src = fh.read()
    except (OSError, ValueError, KeyError) as e:
        raise Stop("BLOCKED", "AXE_UNVERIFIED", f"axe-core or its lock is missing or unreadable: {e.__class__.__name__}")
    if hashlib.sha256(src).hexdigest() != lock.get("sha256"):
        raise Stop("BLOCKED", "AXE_UNVERIFIED", "axe-core does not match the sha256 in its lock - never run an unverified engine")
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
            raise Stop("UNKNOWN", "TIMEOUT", f"pw.sh did not answer within {TIMEOUT}s")
        except OSError as e:
            raise Stop("BLOCKED", "PW_REFUSED", f"cannot run pw.sh: {e.__class__.__name__}")
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
        c = {"id": k, "status": "FAIL" if crit[k] else "PASS", "findings": crit[k]}
        if k == "UX-DIALOG-FOCUS" and not crit[k] and (not dialogs or blocked):
            # nothing opened, or an opener missing: not a PASS
            c["status"] = "NOT_RUN"
            c["notApplicableReason"] = ("no --dialog opener was given" if not dialogs
                                        else "dialog opener not found: " + ", ".join(blocked))
        out.append(c)
    return out, advisories, blocked


def main(argv):
    ap = argparse.ArgumentParser(description="apex-ux runtime checks on the page pw.sh holds")
    ap.add_argument("--app")
    ap.add_argument("--task")
    ap.add_argument("--dialog", action="append", default=[], help="selector of a control that opens a dialog")
    ap.add_argument("--raw", help="write axe's full output here (default with --task: the task's raw dir)")
    a = ap.parse_args(argv)
    result = {"kind": "ui-result", "schemaVersion": 1, "status": "UNKNOWN", "reasons": [],
              "context": context(a.task), "scope": "runtime", "criteria": [], "advisories": []}
    task_dir, page = None, "page"
    try:
        alias, task_dir = target(a.app, a.task)
        if alias:
            result["app"] = {"appAlias": alias}
        axe_src, lock = load_axe()
        result["engine"] = {"name": "axe-core", "version": lock.get("version"), "sha256": lock.get("sha256")}
        v = run_page(a.app, axe_src, a.dialog)
        url = redact(v.get("url"))
        page = page_name(url)
        if re.match(r"^https?://\S+$", url):
            result["context"]["target"] = {"runtimeUrl": url}
        if v["verdict"] == "NOT-LOGGED-IN":
            raise Stop("BLOCKED", "LOGIN_PAGE", "the session is on a login page - run pw.sh login, then goto the page")
        if v["verdict"] != "OK":
            raise Stop("UNKNOWN", "NO_VERDICT", "unexpected verdict from the browser")
        result["errors"] = [{"where": str(e.get("where", "")), "frame": redact(e.get("frame")),
                             "error": scrub(redact(str(e.get("error", ""))))[:300]} for e in v.get("errors", [])]
        if not v.get("runs"):
            raise Stop("UNKNOWN", "NO_FRAME", "axe ran in no frame")
        raw = a.raw or (task_dir and os.path.join(task_dir, "raw", f"ui-{alias}", f"axe-{page}.json"))
        if raw:
            data = json.dumps(v, indent=1).encode("utf-8")
            os.makedirs(os.path.dirname(os.path.abspath(raw)), exist_ok=True)
            with open(raw, "wb") as fh:
                fh.write(data)
            if rel(raw):
                result["evidence"] = [{"kind": "file", "path": rel(raw), "sha256": hashlib.sha256(data).hexdigest(),
                                       "description": "axe-core's full output, node HTML included - never share it"}]
            else:
                print(f"ux-check: {raw} is outside the repository; not cited in the result", file=sys.stderr)
        result["criteria"], result["advisories"], blocked = evaluate(v, a.dialog)
        if blocked:
            raise Stop("BLOCKED", "OPENER_NOT_FOUND", "dialog opener not found: " + ", ".join(blocked))
        failed = [c["id"] for c in result["criteria"] if c["status"] == "FAIL"]
        result["status"] = "FAIL" if failed else "PASS"
        result["reasons"] = [{"code": "UI_CRITERIA_FAILED" if failed else "UI_CRITERIA_HELD",
                              "message": f"{len(v['runs'])} axe run(s), {len(a.dialog)} dialog(s)"}]
    except Stop as s:
        result["status"], result["reasons"] = s.status, [{"code": s.code, "message": s.message}]
        if s.status == "BLOCKED" and s.code == "OPENER_NOT_FOUND" and any(c["status"] == "FAIL" for c in result["criteria"]):
            result["status"] = "FAIL"      # a defect found stands; the missing opener is reported with it
    except OSError as e:
        result["status"], result["reasons"] = "UNKNOWN", [{"code": "RAW_UNWRITABLE", "message": f"cannot write the raw output: {e.__class__.__name__}"}]
    return write(result, task_dir, f"ui-{result.get('app', {}).get('appAlias', 'app')}-runtime-{page}.json")


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
