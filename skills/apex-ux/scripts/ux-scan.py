#!/usr/bin/env python3
"""ux-scan — the static half of apex-ux's FAIL criteria, over APEXlang `.apx` source.

Usage: python3 ux-scan.py [--app <alias>] [--task <id>] <file-or-dir>...
       (directories are searched for *.apx)

Checks (criteria/common.md):
  UX-ITEM-NAME            every visible pageItem has a non-empty label
  UX-CONTROL-NAME         buttons have a label; link/button HTML is never icon-only
  UX-DESTRUCTIVE-CONFIRM  a delete/reject/remove/cancel-a-record button or action that
                          submits carries a `confirmation { message }`
  UX-NO-INLINE-STYLE      no style= attribute, no literal colour
  UX-NO-COMPOSED-CLASS    no class built from pieces (substitution glued into a class,
                          or 'prefix-' || ... in SQL)

Output: a ui-result (framework/schemas/ui-result.schema.json, scope static) on stdout,
and with --task in <evidenceDir>/<task>/ui-<alias>-static.json; a one-line summary on stderr.
Exit:   0 PASS · 1 FAIL · 2 BLOCKED (nothing to scan, unreadable, outside the repo) · 3 UNKNOWN (a file
        the parser could not follow — no verdict on it; never read as PASS).
Runtime halves (axe-core, focus, rendered names) are ux-check.py's: this scan never covers them.
"""
import argparse
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "framework", "lib"))
from apx import RE_FENCE, RE_PROP, ParseError, collect, is_destructive, parse, prop, walk  # noqa: E402
from result import Stop, context, rel, target, write  # noqa: E402

CRITERIA = ["UX-ITEM-NAME", "UX-CONTROL-NAME", "UX-DESTRUCTIVE-CONFIRM",
            "UX-NO-INLINE-STYLE", "UX-NO-COMPOSED-CLASS"]

# --- checks -----------------------------------------------------------------------
VISIBLE_NAME = re.compile(r"(?i)aria-label(?:ledby)?\s*=|u-VisuallyHidden")
RE_A = re.compile(r"(?is)<(a|button)\b([^>]*)>(.*?)</\1>")
RE_TAG = re.compile(r"(?s)<[^>]*>")
RE_STYLE = re.compile(r"(?i)\bstyle\s*=")
RE_HEX = re.compile(r"(?<![\w#&])#(?:[0-9a-fA-F]{3,4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})(?![\w#])")
RE_FUNC_COLOUR = re.compile(r"(?i)\b(?:rgba?|hsla?)\s*\(")
RE_CSS_NAMED = re.compile(r"(?i)\b(?:color|background(?:-color)?|border(?:-color)?|fill|stroke)\s*:\s*"
                          r"(?!var\b|inherit\b|initial\b|unset\b|transparent\b|currentcolor\b|none\b)[a-z]+\b")
RE_CLASS_ATTR = re.compile(r"""(?i)\bclass\s*=\s*(["'])(.*?)\1""")
RE_SUBST = re.compile(r"&[\w$]+\.|#[\w$]+#")
RE_SQL_CONCAT = re.compile(r"'[a-z][\w-]*-'\s*\|\||\|\|\s*'-[a-z][\w-]*'")
COMMENT = re.compile(r"^\s*(--|//|/\*|\*)")
CSS_JS_FENCE = re.compile(r"^```\s*(css|javascript|js|html)\b", re.I)


def composed(token):
    return bool(RE_SUBST.search(token)) and RE_SUBST.fullmatch(token) is None


def scan_text(lines, add):
    """Line checks over the raw source: inline style, colours, composed classes, icon-only links."""
    fence_lang = None
    for no, raw in enumerate(lines, 1):
        s = raw.strip()
        if RE_FENCE.match(s):
            m = CSS_JS_FENCE.match(s)
            fence_lang = None if fence_lang is not None else (m.group(1).lower() if m else "")
            continue
        if COMMENT.match(raw):
            continue
        if RE_STYLE.search(raw):
            add("UX-NO-INLINE-STYLE", no, "style= attribute")
        if RE_HEX.search(raw) or RE_FUNC_COLOUR.search(raw):
            add("UX-NO-INLINE-STYLE", no, "literal colour")
        elif (fence_lang or "<" in raw) and RE_CSS_NAMED.search(raw):
            add("UX-NO-INLINE-STYLE", no, "named colour in CSS")
        for _, cls in RE_CLASS_ATTR.findall(raw):
            if any(composed(t) for t in cls.split()):
                add("UX-NO-COMPOSED-CLASS", no, f'class="{cls}"')
        m = RE_PROP.match(s)
        if m and "css" in m.group(1).lower() and any(composed(t) for t in m.group(2).split()):
            add("UX-NO-COMPOSED-CLASS", no, f"{m.group(1)}: {m.group(2)}")
        if RE_SQL_CONCAT.search(raw):
            add("UX-NO-COMPOSED-CLASS", no, "class concatenated in SQL")
        for _, attrs, inner in RE_A.findall(raw):
            if not VISIBLE_NAME.search(attrs + inner) and not RE_TAG.sub("", inner).replace("&nbsp;", "").strip():
                add("UX-CONTROL-NAME", no, "icon-only link or button with no accessible name")
        if m and m.group(1) == "linkText":
            text = m.group(2)
            if not VISIBLE_NAME.search(text) and not RE_TAG.sub("", text).replace("&nbsp;", "").strip():
                add("UX-CONTROL-NAME", no, "icon-only linkText with no accessible name")


def scan_tree(root, add):
    for c in walk(root):
        if c.kind == "pageItem":
            if prop(c, "type")[0] != "hidden" and not prop(c, "label.label")[0]:
                add("UX-ITEM-NAME", c.line, f"pageItem {c.name} has no label")
        elif c.kind == "button" and not prop(c, "label")[0]:
            add("UX-CONTROL-NAME", c.line, f"button {c.name} has no label")
        # a control the user clicks: a process has no confirmation of its own
        if c.kind in ("button", "action") and is_destructive(c) and not prop(c, "confirmation.message")[0]:
            add("UX-DESTRUCTIVE-CONFIRM", c.line, f"{c.kind} {c.name} submits without a confirmation message")


def main(argv):
    ap = argparse.ArgumentParser(description="apex-ux static scan over .apx files")
    ap.add_argument("--app")
    ap.add_argument("--task")
    ap.add_argument("paths", nargs="*")
    a = ap.parse_args(argv)
    result = {"kind": "ui-result", "schemaVersion": 1, "status": "UNKNOWN", "reasons": [],
              "context": context(a.task, "apex-ux"), "scope": "static", "files": [], "unparsed": [],
              "criteria": [], "advisories": []}
    task_dir = None
    try:
        alias, task_dir, _ = target(a.app, a.task)
        if alias:
            result["app"] = {"appAlias": alias}
        result.update(scan(a.paths))
    except Stop as s:
        result["status"], result["reasons"] = s.status, [{"code": s.code, "message": s.message}]
    return write(result, task_dir, f"ui-{result.get('app', {}).get('appAlias', 'app')}-static.json")


def scan(paths):
    try:
        files = collect(paths)
    except FileNotFoundError as e:             # never a home path in the message
        raise Stop("BLOCKED", "NOTHING_TO_SCAN", f"no such file or directory: {rel(str(e.args[0])) or os.path.basename(str(e.args[0]))}")
    if not files:
        raise Stop("BLOCKED", "NOTHING_TO_SCAN", "no .apx file to scan")
    out = {"files": [], "unparsed": []}
    for f in files:
        r = rel(f)
        if r is None:
            raise Stop("BLOCKED", "OUTSIDE_REPO", f"{os.path.basename(f)} is outside the repository: scan the repo's own .apx")
        out["files"].append(r)
    findings = {k: [] for k in CRITERIA}
    for f, r in zip(files, out["files"]):
        try:
            with open(f, encoding="utf-8") as fh:
                lines = fh.read().splitlines()
        except (OSError, UnicodeDecodeError) as e:
            raise Stop("BLOCKED", "UNREADABLE", f"{r}: {e.__class__.__name__}")

        def add(cid, line, detail, r=r):
            findings[cid].append({"path": r, "line": line, "detail": detail})
        try:
            scan_tree(parse(lines), add)
        except ParseError as e:
            out["unparsed"].append({"path": r, "detail": str(e)})
        scan_text(lines, add)
    out["criteria"] = [{"id": cid, "status": "FAIL" if findings[cid] else "PASS", "findings": findings[cid]}
                       for cid in CRITERIA]
    n = len(out["files"])
    if any(findings.values()):
        failed = [c for c in CRITERIA if findings[c]]
        out["status"], out["reasons"] = "FAIL", [{"code": "UI_CRITERIA_FAILED",
                                                  "message": f"{n} file(s) scanned; findings in {len(failed)} criteria"}]
    elif out["unparsed"]:
        out["status"], out["reasons"] = "UNKNOWN", [{"code": "UNPARSED",
            "message": "a file could not be parsed: its item and button checks did not run - read it by hand"}]
    else:
        out["status"], out["reasons"] = "PASS", [{"code": "UI_CRITERIA_HELD",
            "message": f"{n} file(s); the five static FAIL criteria held"}]
    return out


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
