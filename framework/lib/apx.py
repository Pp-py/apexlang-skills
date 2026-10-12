"""apx — the canonical multi-line APEXlang (.apx) reader the static scans share
(apex-ux's ux-scan.py, apex-security's sec-scan.py): one construct per line.

  parse(lines)       component tree of one file; ParseError on anything not understood,
                     so a scan reports the file as unparsed instead of guessing
  walk(comp)         every component below comp, depth first
  prop(comp, key)    (value, line) of a property, '' when absent ("security.authorizationScheme")
  is_destructive(c)  a control or process that deletes, rejects or cancels a record —
                     one definition for UX-DESTRUCTIVE-CONFIRM and SEC-ACTION-AUTHZ
  collect(paths)     the .apx files (or other extensions) under files and directories, sorted
"""
import os
import re

RE_COMP_OPEN = re.compile(r'^(\w+)(?:\s+([\w@.$-]+|"[^"]*"))?\s*\($')  # button reject (  displayColumn (  file "a/b.png" (
RE_GROUP_OPEN = re.compile(r"^([\w-]+):?\s*\{$")                # label {   target: {
RE_PROP = re.compile(r"^([\w$-]+):\s*(.*)$")                    # key: value
RE_FENCE = re.compile(r"^```")


class ParseError(Exception):
    pass


class Comp:
    def __init__(self, kind, name, line, parent):
        self.kind, self.name, self.line, self.parent = kind, name, line, parent
        self.end = line          # the line of its closing ')'
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
            child = Comp(m.group(1), (m.group(2) or "").strip('"'), no, comp)
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
                comp.end = no
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


DESTRUCTIVE = re.compile(r"(?i)(?:^|[\s_-])(delete|remove|reject|discard|purge|revoke|deactivate)(?:$|[\s_-])")
CANCEL_RECORD = re.compile(r"(?i)^cancel[\s_-]+\w")             # "Cancel request", not "Cancel"


def is_destructive(c):
    """A button, action or process that destroys or closes a record when it runs. A button
    that only redirects, or a dynamic-action step (`action:` set), is not one."""
    if c.kind in ("button", "action"):
        if prop(c, "action")[0]:
            return False
        if "redirect" in (prop(c, "behavior.action")[0] + prop(c, "behavior.type")[0]).lower():
            return False
    elif c.kind != "process":
        return False
    words = [c.name, prop(c, "buttonName")[0], prop(c, "label")[0]]
    return (any(DESTRUCTIVE.search(w) or CANCEL_RECORD.search(w) for w in words if w)
            or prop(c, "layout.slot")[0] == "delete")


def collect(paths, exts=(".apx",)):
    files = []
    for p in paths:
        if os.path.isdir(p):
            for d, _, names in os.walk(p):
                files += [os.path.join(d, n) for n in sorted(names) if n.lower().endswith(exts)]
        elif os.path.isfile(p):
            files.append(p)
        else:
            raise FileNotFoundError(p)
    return sorted(set(files))
