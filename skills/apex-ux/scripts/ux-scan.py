#!/usr/bin/env python3
"""ux-scan — the static half of apex-ux's FAIL criteria, over APEXlang `.apx` source.

Usage: python3 ux-scan.py <file-or-dir>...   (directories are searched for *.apx)

Checks (criteria/common.md):
  UX-ITEM-NAME            every visible pageItem has a non-empty label
  UX-CONTROL-NAME         buttons have a label; link/button HTML is never icon-only
  UX-DESTRUCTIVE-CONFIRM  a delete/reject/remove/cancel-a-record button or action that
                          submits carries a `confirmation { message }`
  UX-NO-INLINE-STYLE      no style= attribute, no literal colour
  UX-NO-COMPOSED-CLASS    no class built from pieces (substitution glued into a class,
                          or 'prefix-' || ... in SQL)

Output: one JSON document on stdout (provisional until the ui-result schema, UX-5);
a one-line summary on stderr.
Exit:   0 PASS · 1 FAIL · 2 BLOCKED (nothing to scan, unreadable) · 3 UNKNOWN (a file
        the parser could not follow — no verdict on it; never read as PASS).
Runtime halves (axe-core, focus, rendered names) are UX-4: this scan never covers them.
"""
import json
import os
import re
import sys

CRITERIA = ["UX-ITEM-NAME", "UX-CONTROL-NAME", "UX-DESTRUCTIVE-CONFIRM",
            "UX-NO-INLINE-STYLE", "UX-NO-COMPOSED-CLASS"]

# --- parser: canonical multi-line .apx (one construct per line) -------------------
RE_COMP_OPEN = re.compile(r"^(\w+)(?:\s+([\w@.$-]+))?\s*\($")  # button reject (   displayColumn (
RE_GROUP_OPEN = re.compile(r"^([\w-]+):?\s*\{$")                # label {   target: {
RE_PROP = re.compile(r"^([\w$-]+):\s*(.*)$")                    # key: value
RE_FENCE = re.compile(r"^```")


class ParseError(Exception):
    pass


class Comp:
    def __init__(self, kind, name, line, parent):
        self.kind, self.name, self.line, self.parent = kind, name, line, parent
        self.props = {}          # "label.label" -> (value, line)
        self.children = []


def parse(lines):
    """Component tree of one file. Raises ParseError on anything not understood."""
    root = Comp("file", "", 0, None)
    comp, path, stack = root, [], []      # stack: ("comp"|"group", saved path)
    fence, pending, array = False, None, None   # array: (key, items) of an open `key: [`
    for no, raw in enumerate(lines, 1):
        s = raw.strip()
        if array:
            if s == "]":
                comp.props[array[0]] = (" ".join(array[1]), no)
                array = None
            elif s:
                array[1].append(s)
            continue
        if fence:
            if RE_FENCE.match(s):
                fence = False
            continue
        if not s or s.startswith("//"):
            continue
        if RE_FENCE.match(s):
            if pending is None:
                raise ParseError(f"line {no}: code fence without a property")
            fence, pending = True, None
            continue
        pending = None
        m = RE_COMP_OPEN.match(s)
        if m:
            child = Comp(m.group(1), m.group(2) or "", no, comp)
            comp.children.append(child)
            stack.append(("comp", path))
            comp, path = child, []
            continue
        m = RE_GROUP_OPEN.match(s)
        if m:
            stack.append(("group", path))
            path = path + [m.group(1)]
            continue
        if s in (")", "}"):
            if not stack or stack[-1][0] != ("comp" if s == ")" else "group"):
                raise ParseError(f"line {no}: unexpected '{s}'")
            _, path = stack.pop()
            if s == ")":
                comp = comp.parent
            continue
        m = RE_PROP.match(s)
        if m:
            key = ".".join(path + [m.group(1)])
            if m.group(2).strip() == "[":
                array = (key, [])
                continue
            comp.props[key] = (m.group(2).strip(), no)
            if not m.group(2).strip():
                pending = key          # value follows as a ``` fence
            continue
        raise ParseError(f"line {no}: not understood: {s[:60]}")
    if fence or stack or array:
        raise ParseError("end of file inside a block or a code fence")
    return root


def walk(comp):
    for c in comp.children:
        yield c
        yield from walk(c)


def prop(comp, key):
    return comp.props.get(key, ("", comp.line))


# --- checks -----------------------------------------------------------------------
DESTRUCTIVE = re.compile(r"(?i)(?:^|[\s_-])(delete|remove|reject|discard|purge|revoke|deactivate)(?:$|[\s_-])")
CANCEL_RECORD = re.compile(r"(?i)^cancel[\s_-]+\w")             # "Cancel request", not "Cancel"
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
        if c.kind not in ("button", "action") or prop(c, "action")[0]:
            continue                       # `action:` set = a dynamic-action step, not a control
        words = [c.name, prop(c, "buttonName")[0], prop(c, "label")[0]]
        destructive = any(DESTRUCTIVE.search(w) or CANCEL_RECORD.search(w) for w in words if w)
        destructive = destructive or prop(c, "layout.slot")[0] == "delete"
        redirect = "redirect" in (prop(c, "behavior.action")[0] + prop(c, "behavior.type")[0]).lower()
        if destructive and not redirect and not prop(c, "confirmation.message")[0]:
            add("UX-DESTRUCTIVE-CONFIRM", c.line, f"{c.kind} {c.name} submits without a confirmation message")


def collect(paths):
    files = []
    for p in paths:
        if os.path.isdir(p):
            for d, _, names in os.walk(p):
                files += [os.path.join(d, n) for n in sorted(names) if n.endswith(".apx")]
        elif os.path.isfile(p):
            files.append(p)
        else:
            raise OSError(f"no such file or directory: {p}")
    return sorted(set(files))


def main(argv):
    result = {"tool": "ux-scan", "format": "provisional-1", "scope": "static",
              "status": "BLOCKED", "files": [], "criteria": [], "unparsed": [], "reason": ""}
    try:
        files = collect(argv)
    except OSError as e:
        files, result["reason"] = [], str(e)
    if not argv or not files:
        result["reason"] = result["reason"] or "no .apx file to scan"
        return emit(result, 2)
    findings = {k: [] for k in CRITERIA}
    for f in files:
        try:
            with open(f, encoding="utf-8") as fh:
                lines = fh.read().splitlines()
        except (OSError, UnicodeDecodeError) as e:
            result["reason"] = f"{f}: {e}"
            return emit(result, 2)
        result["files"].append(f)

        def add(cid, line, detail, f=f):
            findings[cid].append({"file": f, "line": line, "detail": detail})
        try:
            scan_tree(parse(lines), add)
        except ParseError as e:
            result["unparsed"].append({"file": f, "detail": str(e)})
        scan_text(lines, add)
    for cid in CRITERIA:
        result["criteria"].append({"id": cid, "status": "FAIL" if findings[cid] else "PASS",
                                   "findings": findings[cid]})
    if any(findings.values()):
        result["status"], rc = "FAIL", 1
    elif result["unparsed"]:
        result["status"], rc = "UNKNOWN", 3
        result["reason"] = "a file could not be parsed: its item/button checks did not run"
    else:
        result["status"], rc = "PASS", 0
    return emit(result, rc)


def emit(result, rc):
    print(json.dumps(result, indent=2))
    failed = [c["id"] for c in result["criteria"] if c["status"] == "FAIL"]
    print(f"ux-scan: {result['status']} - {len(result['files'])} file(s)"
          + (f"; FAIL {', '.join(failed)}" if failed else "")
          + (f"; {result['reason']}" if result["reason"] else ""), file=sys.stderr)
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
