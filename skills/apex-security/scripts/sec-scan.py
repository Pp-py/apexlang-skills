#!/usr/bin/env python3
"""sec-scan — the static half of apex-security's FAIL criteria, over APEXlang `.apx` source.

Usage: python3 sec-scan.py [--app <alias>] [--task <id>] <file-or-dir>...
       (directories are searched for *.apx; pass the app's tree to cover application.apx)

Checks (criteria.md). Page 0 is left out of the page checks, the login page (alias LOGIN,
page 9999, or "login" in its name or title) out of the authorization ones:
  SEC-PAGE-AUTHZ       a page that is not public declares security.authorizationScheme
  SEC-PUBLIC-DECLARED  a public page carries a `public page review: <reason>` comment AND is in
                       the app's publicPages (apex-sync.json); a listed page is public
  SEC-PAGE-CHECKSUM    pageAccessProtection is not unrestricted — set, or left to its version's
                       default: argumentsMustHaveChecksum from APEXlang 26.2, unrestricted in 26.1
                       (the version from the app's .apex/apexlang.json; unknown is read as 26.1)
  SEC-APP-SSP          application.apx does not disable Session State Protection (enabled: false);
                       no block means enabled, the default in 26.1 and 26.2 (NOT_RUN without the file)
  SEC-ITEM-SSP         hidden and key-named items declare sessionStateProtection
  SEC-ESCAPE-COLUMN    no escapeSpecialChars: false
  SEC-ESCAPE-SUBST     no bare &X. substitution inside HTML
  SEC-URL-SAFE         no javascript:/data:/protocol-relative/http:// link
  SEC-ACTION-AUTHZ     a destructive button, action or process is under a role scheme (@<id>)
  advisories           SEC-SESSION-TIMEOUTS, SEC-SESSION-REJOIN
SEC-SQL-BIND and SEC-AUTHID belong to the package scan (SEC-3), secrets to SEC-5.

Output: a security-result (framework/schemas/security-result.schema.json, scope static) on
stdout, and with --task in <evidenceDir>/<task>/security-<alias>-static.json.
Exit:   0 PASS · 1 FAIL · 2 BLOCKED (nothing to scan, unreadable, outside the repo, several
        apps and no --app) · 3 UNKNOWN (a file the parser could not follow — never a PASS).
"""
import argparse
import json
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "framework", "lib"))
from apx import RE_FENCE, ParseError, collect, is_destructive, parse, prop, walk  # noqa: E402
from result import ROOT, Stop, context, rel, target, write  # noqa: E402

CRITERIA = ["SEC-PAGE-AUTHZ", "SEC-PUBLIC-DECLARED", "SEC-PAGE-CHECKSUM", "SEC-APP-SSP",
            "SEC-ITEM-SSP", "SEC-ESCAPE-COLUMN", "SEC-ESCAPE-SUBST", "SEC-URL-SAFE", "SEC-ACTION-AUTHZ"]
KEY_ITEM = re.compile(r"^P\d+_\w*_(ID|PK|KEY|ROWID)$", re.I)
REVIEW = re.compile(r"(?i)^\s*//.*public[- ]page[- ]review:\s*\S")
OWNER_DA = re.compile(r"(?i)^\s*//.*dynamic action")
BUILTIN = {"APP_ID", "APP_PAGE_ID", "SESSION", "DEBUG", "APP_TITLE", "IMAGE_PREFIX", "APP_IMAGES",
           "WORKSPACE_IMAGES", "THEME_IMAGES", "APEX_FILES"}
BARE_SUBST = re.compile(r"&([A-Za-z][\w$#]*)\.")             # &X. — &X!HTML. never matches
HTML_PROP = re.compile(r"^\s*(\w*(?:html|Html|HTML)\w*|linkText|linkAttributes|text)\s*:\s*(.*)$")
UNSAFE_URL = [
    (re.compile(r"(?i)javascript:"), "javascript: URL"),
    (re.compile(r"""(?i)(?:href|src|url|target)\s*[=:]\s*["']?data:"""), "data: URL"),
    (re.compile(r"""(?i)(?:href|src|url)\s*[=:]\s*["']?//[\w.-]"""), "protocol-relative URL"),
    (re.compile(r"""(?i)(?:href|src|url)\s*[=:]\s*["']?http://"""), "plain-http URL"),
]
COMMENT = re.compile(r"^\s*(--|//|/\*|\*)")
LOGIN = re.compile(r"(?i)login|log in")


MMD = {}


def mmd_version(path):
    """(major, minor) of the APEXlang version the file's app declares in .apex/apexlang.json,
    looked up from the file's directory up to the repo root; None when there is none."""
    d, chain, v = os.path.dirname(os.path.abspath(path)), [], None
    while d not in MMD:
        chain.append(d)
        f = os.path.join(d, ".apex", "apexlang.json")
        if os.path.isfile(f):
            try:
                with open(f, encoding="utf-8") as fh:
                    m = re.match(r"(\d+)\.(\d+)", str(json.load(fh).get("mmdVersion", "")))
                v = (int(m.group(1)), int(m.group(2))) if m else None
            except (OSError, ValueError, AttributeError):
                v = None
            break
        if d == ROOT or os.path.dirname(d) == d:
            break
        d = os.path.dirname(d)
    else:
        v = MMD[d]
    for c in chain:
        MMD[c] = v
    return v


def is_login(page):
    return (page.name == "9999" or prop(page, "alias")[0].upper() == "LOGIN"
            or bool(LOGIN.search(prop(page, "name")[0] + " " + prop(page, "title")[0])))


def scan_page(page, lines, public_pages, add, seen_pages, mmd):
    no = int(page.name) if page.name.isdigit() else None
    if no == 0:
        return                                   # the global page: Oracle's minimal skeleton
    seen_pages.add(no)
    public = prop(page, "security.authentication")[0] == "public"
    login = is_login(page)
    scheme = prop(page, "security.authorizationScheme")[0]
    if public and not login:
        marker = any(REVIEW.match(ln) for ln in lines)          # one page per file: anywhere in it
        if not marker:
            add("SEC-PUBLIC-DECLARED", page.line, f"page {page.name}", "public page without a `public page review: <reason>` comment")
        if no not in public_pages:
            add("SEC-PUBLIC-DECLARED", page.line, f"page {page.name}", "public page not listed in publicPages (apex-sync.json)")
    elif no in public_pages:
        add("SEC-PUBLIC-DECLARED", page.line, f"page {page.name}", "listed in publicPages but not public")
    if not public and not login and not scheme:
        add("SEC-PAGE-AUTHZ", page.line, f"page {page.name}", "no security.authorizationScheme")
    # An export leaves out a property at its default, and the default moved: 26.1 = unrestricted,
    # 26.2 = argumentsMustHaveChecksum (Oracle's inventory; the 26.2 Builder confirmed it, R-8).
    pap = prop(page, "security.pageAccessProtection")[0]
    if pap == "unrestricted" or (not pap and (mmd or (26, 1)) < (26, 2)):
        add("SEC-PAGE-CHECKSUM", page.line, f"page {page.name}",
            "pageAccessProtection is unrestricted" if pap else
            "no security.pageAccessProtection: " + ("unrestricted, the 26.1 default" if mmd else
                                                    "no .apex/apexlang.json, so read as 26.1, whose default is unrestricted"))
    strict = scheme.startswith("@")             # a role scheme on the page covers its actions
    for c in walk(page):
        if c.kind == "pageItem" and (prop(c, "type")[0] == "hidden" or KEY_ITEM.match(c.name)):
            ssp = prop(c, "security.sessionStateProtection")[0]
            owned = any(OWNER_DA.match(ln) for ln in lines[c.line - 1:c.end])
            if not ssp or (ssp == "unrestricted" and not owned):
                add("SEC-ITEM-SSP", c.line, f"pageItem {c.name}",
                    "sessionStateProtection unrestricted with no dynamic-action comment" if ssp
                    else "no security.sessionStateProtection")
        if is_destructive(c) and not strict and not prop(c, "security.authorizationScheme")[0].startswith("@"):
            add("SEC-ACTION-AUTHZ", c.line, f"{c.kind} {c.name}", "destructive, with no role scheme (@<static-id>) on it or its page")


def scan_app(app, add, advise):
    # no block = enabled (the default in 26.1 and 26.2; an export leaves it out)
    if prop(app, "sessionStateProtection.enabled")[0] == "false":
        add("SEC-APP-SSP", app.line, f"app {app.name}", "Session State Protection is disabled (enabled: false)")
    for key, limit in (("maxSessionIdleTime", 3600), ("maxSessionLength", 28800)):
        v = prop(app, f"sessionManagement.{key}")[0]
        if not v.isdigit() or int(v) > limit:
            advise("SEC-SESSION-TIMEOUTS", app.line, f"app {app.name}", f"{key} is {v or 'not set'} (at most {limit})")
    rejoin = prop(app, "sessionManagement.rejoinSessions")[0]
    if rejoin and rejoin != "false":
        advise("SEC-SESSION-REJOIN", app.line, f"app {app.name}", f"rejoinSessions is {rejoin}")


def scan_text(lines, add):
    """Line checks: escaping off, bare substitutions in HTML, unsafe URLs."""
    fence = None                                 # the language of an open ``` fence
    for no, raw in enumerate(lines, 1):
        s = raw.strip()
        if RE_FENCE.match(s):
            fence = None if fence is not None else (s[3:].strip().lower() or "text")
            continue
        if COMMENT.match(raw):
            continue
        if re.match(r"^\s*escapeSpecialChars:\s*false\s*$", raw):
            add("SEC-ESCAPE-COLUMN", no, "", "escapeSpecialChars: false")
        m = HTML_PROP.match(raw)
        html = fence == "html" or (fence is None and (m or "<" in raw))
        if html and fence not in ("sql", "plsql", "javascript", "js", "css"):
            for name in BARE_SUBST.findall(raw):
                if name.upper() not in BUILTIN:
                    add("SEC-ESCAPE-SUBST", no, "", f"&{name}. in HTML without !HTML")
        if fence in ("javascript", "js", "sql", "plsql", "css"):
            continue
        for rx, what in UNSAFE_URL:
            if rx.search(raw):
                add("SEC-URL-SAFE", no, "", what)


def scan(paths, public_pages):
    try:
        files = collect(paths)
    except FileNotFoundError as e:               # never a home path in the message
        raise Stop("BLOCKED", "NOTHING_TO_SCAN", f"no such file or directory: {rel(str(e.args[0])) or os.path.basename(str(e.args[0]))}")
    if not files:
        raise Stop("BLOCKED", "NOTHING_TO_SCAN", "no .apx file to scan")
    out = {"files": [], "unparsed": [], "advisories": []}
    for f in files:
        r = rel(f)
        if r is None:
            raise Stop("BLOCKED", "OUTSIDE_REPO", f"{os.path.basename(f)} is outside the repository: scan the repo's own .apx")
        out["files"].append(r)
    findings, apps, seen_pages = {k: [] for k in CRITERIA}, 0, set()
    for f, r in zip(files, out["files"]):
        try:
            with open(f, encoding="utf-8") as fh:
                lines = fh.read().splitlines()
        except (OSError, UnicodeDecodeError) as e:
            raise Stop("BLOCKED", "UNREADABLE", f"{r}: {e.__class__.__name__}")

        def add(cid, line, component, detail, r=r):
            findings[cid].append({"path": r, "line": line, "component": component, "detail": detail}
                                 if component else {"path": r, "line": line, "detail": detail})

        def advise(cid, line, component, detail, r=r):
            out["advisories"].append({"id": cid, "path": r, "line": line, "component": component, "detail": detail})
        try:
            for top in parse(lines).children:
                if top.kind == "page":
                    scan_page(top, lines, public_pages, add, seen_pages, mmd_version(f))
                elif top.kind == "app":
                    apps += 1
                    scan_app(top, add, advise)
        except ParseError as e:
            out["unparsed"].append({"path": r, "detail": str(e)})
        scan_text(lines, add)
    out["criteria"] = []
    for cid in CRITERIA:
        c = {"id": cid, "status": "FAIL" if findings[cid] else "PASS", "findings": findings[cid]}
        if cid == "SEC-APP-SSP" and not apps:
            c.update(status="NOT_RUN", notApplicableReason="no application.apx among the scanned files")
        out["criteria"].append(c)
    failed = [c["id"] for c in out["criteria"] if c["status"] == "FAIL"]
    n = len(out["files"])
    if failed:
        out["status"], out["reasons"] = "FAIL", [{"code": "SECURITY_CRITERIA_FAILED",
                                                  "message": f"{n} file(s) scanned; findings in {len(failed)} criteria"}]
    elif out["unparsed"]:
        out["status"], out["reasons"] = "UNKNOWN", [{"code": "UNPARSED",
            "message": "a file could not be parsed: its page and item checks did not run - read it by hand"}]
    else:
        out["status"], out["reasons"] = "PASS", [{"code": "SECURITY_CRITERIA_HELD",
            "message": f"{n} file(s); the static FAIL criteria held"}]
    return out


def main(argv):
    ap = argparse.ArgumentParser(description="apex-security static scan over .apx files")
    ap.add_argument("--app")
    ap.add_argument("--task")
    ap.add_argument("paths", nargs="*")
    a = ap.parse_args(argv)
    result = {"kind": "security-result", "schemaVersion": 1, "status": "UNKNOWN", "reasons": [],
              "context": context(a.task, "apex-security"), "scope": "static", "files": [], "unparsed": [],
              "criteria": [], "advisories": []}
    task_dir = None
    try:
        alias, task_dir, settings = target(a.app, a.task)
        if alias:
            result["app"] = {"appAlias": alias}
        if settings is None:
            raise Stop("BLOCKED", "APP_REQUIRED", "apex-sync.json lists several apps: pass --app <alias> (its publicPages apply)")
        pages = settings.get("publicPages", [])
        if not isinstance(pages, list) or not all(isinstance(p, int) and not isinstance(p, bool) for p in pages):
            raise Stop("BLOCKED", "BAD_CONFIG", "apex-sync.json: publicPages must be an array of page numbers")
        result.update(scan(a.paths, set(pages)))
    except Stop as s:
        result["status"], result["reasons"] = s.status, [{"code": s.code, "message": s.message}]
    return write(result, task_dir, f"security-{result.get('app', {}).get('appAlias', 'app')}-static.json")


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
