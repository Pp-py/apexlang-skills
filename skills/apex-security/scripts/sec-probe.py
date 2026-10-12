#!/usr/bin/env python3
"""sec-probe — apex-security's runtime probes, through apex-sentinel's pw.sh (never a copy).

Usage: python3 sec-probe.py [--app <alias>] [--task <id>] [--anon <url>]... [--tamper] [--role <url>]... [--xss <token>]

Run it after `pw.sh [--app X] login` and `pw.sh goto <page>`, as the test user. Each probe is
asked for; one not asked is NOT_RUN. What APEX rendered is read from the page id
(#pFlowStepId), against a CONTROL: the same URL loaded by the test user must render a page,
or the probe is UNKNOWN — never a PASS on a broken link.
  SEC-ANON-REDIRECT    --anon <url>: fetched over plain HTTP with no cookie, redirects followed;
                       PASS on a login page (a password field, /login, another host),
                       FAIL if the control's page is served
  SEC-CHECKSUM-TAMPER  --tamper: the first link with cs= on the held page, loaded in a new tab
                       intact (control), without cs, and with an item value changed: both
                       variants must not render the control's page
  SEC-ROLE-REFUSED     --role <url>: logged in as the app's lowPrivUser (apex-sync.json) in its
                       own pw.sh session, password from $APEX_TEST_PASSWORD_LOW[_<ALIAS>] — the
                       URL must not render the control's page. No lowPrivUser → NOT_RUN
  SEC-XSS-ESCAPED      --xss <token>: on the held page, an element [data-xss-probe="<token>"]
                       is FAIL, the payload shown as text is PASS, neither is NOT_RUN. The
                       agent stores the payload through the UI first and removes it after.

Output: a security-result (scope runtime) on stdout, and with --task in
<evidenceDir>/<task>/security-<alias>-runtime.json. URLs are kept without session and checksum.
Exit:   0 PASS · 1 FAIL · 2 BLOCKED (nothing asked, pw.sh refused, the low user's login failed,
        a login page held) · 3 UNKNOWN (a control did not render, dead session, no verdict).
"""
import argparse
import json
import os
import re
import ssl
import sys
import urllib.error
import urllib.request
from urllib.parse import urlsplit

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "framework", "lib"))
from pw import pw, redact, run_code  # noqa: E402
from result import Stop, context, scrub, target, write  # noqa: E402

TEMPLATE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "sec-probe.js")
TIMEOUT = int(os.environ.get("SEC_PROBE_TIMEOUT", "300"))
CRITERIA = ["SEC-ANON-REDIRECT", "SEC-CHECKSUM-TAMPER", "SEC-ROLE-REFUSED", "SEC-XSS-ESCAPED"]
STEP = re.compile(r"""id=["']pFlowStepId["'][^>]*value=["']([^"']*)["']|value=["']([^"']*)["'][^>]*id=["']pFlowStepId["']""")


def clean(url):
    """Kept in a result: no session, no checksum."""
    return re.sub(r"([?&]cs=)[^&#]*", r"\1<cs>", redact(url))


def browser(app, opts, env=None):
    with open(TEMPLATE, encoding="utf-8") as fh:
        body = fh.read()
    code = "async (page) => {\n  const OPTS = %s;\n  return (%s)(page, OPTS);\n}\n" % (json.dumps(opts), body)
    v = run_code(app, code, "sec-probe-", TIMEOUT, env)
    if v.get("verdict") == "NOT-LOGGED-IN":
        raise Stop("BLOCKED", "LOGIN_PAGE", "the session is on a login page - run pw.sh login, then goto a page")
    return v


def anonymous(url):
    """(final url, html) of a cookie-less GET, redirects followed."""
    ctx = ssl._create_unverified_context() if os.environ.get("PW_INSECURE_TLS") == "1" else None
    req = urllib.request.Request(url, headers={"User-Agent": "apex-security sec-probe"})
    try:
        with urllib.request.urlopen(req, timeout=30, context=ctx) as r:
            return r.geturl(), r.read(400000).decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.geturl() or url, e.read(400000).decode("utf-8", "replace")
    except (urllib.error.URLError, OSError, ValueError) as e:
        raise Stop("UNKNOWN", "ANON_UNREACHABLE", f"{clean(url)}: {e.__class__.__name__}")


def refused(control, probe):
    """None when the control rendered no page (UNKNOWN), else whether the probe was refused."""
    if not control or control.get("step") in (None, "") or control.get("login"):
        return None
    return probe is not None and probe.get("step") != control["step"]


def low_env(alias, user):
    sfx = "_" + re.sub(r"[^A-Z0-9]", "_", (alias or "").upper()) if alias else ""
    pwd = os.environ.get(f"APEX_TEST_PASSWORD_LOW{sfx}") or os.environ.get("APEX_TEST_PASSWORD_LOW")
    if not pwd:
        return None
    env = dict(os.environ, PW_SESSION=os.environ.get("PW_SESSION", "apex") + "-low")
    for k in {"APEX_TEST_USER", f"APEX_TEST_USER{sfx}"}:
        env[k] = user
    for k in {"APEX_TEST_PASSWORD", f"APEX_TEST_PASSWORD{sfx}"}:
        env[k] = pwd                                   # through the environment, never argv
    return env


def probe(a, alias, settings, crit, add):
    controls = list(dict.fromkeys(a.anon + a.role))
    main = None
    if controls or a.tamper or a.xss:
        main = browser(a.app, {"open": controls, "tamper": a.tamper, "xss": a.xss})
    ctl = {c["url"]: c for c in (main or {}).get("open", [])}
    for url in a.anon:
        final, html = anonymous(url)
        m = STEP.search(html)
        served = (m.group(1) or m.group(2)) if m else None
        login = bool(re.search(r"""type=["']?password""", html, re.I)) or "/login" in urlsplit(final).path.lower() \
            or urlsplit(final).netloc != urlsplit(url).netloc
        r = refused(ctl.get(url), {"step": served})
        if r is None:
            add("SEC-ANON-REDIRECT", None, f"{clean(url)}: the control (as the test user) rendered no page")
        elif served and not r:
            add("SEC-ANON-REDIRECT", False, f"{clean(url)}: served page {served} with no login")
        elif not login:
            add("SEC-ANON-REDIRECT", None, f"{clean(url)}: ended on {clean(final)}, neither the page nor a login")
        else:
            add("SEC-ANON-REDIRECT", True, None)
    if a.tamper:
        t = main.get("tamper") or {}
        if not t.get("link"):
            crit["SEC-CHECKSUM-TAMPER"] = "no link with a checksum (cs=) on the held page"
        else:
            for name in ("noChecksum", "altered"):
                if t.get(name) is None:
                    continue
                r = refused(t.get("control"), t[name])
                what = f"{clean(t['link'])} ({'checksum removed' if name == 'noChecksum' else 'item value changed'})"
                add("SEC-CHECKSUM-TAMPER", r, None if r else what + (": the control rendered no page" if r is None else ": rendered"))
    if a.role:
        user = (settings or {}).get("lowPrivUser")
        # the alias pw.sh keys the password on: --app, else the config's one app
        env = low_env(alias or (settings or {}).get("appAlias"), user) if user else None
        if not env:
            crit["SEC-ROLE-REFUSED"] = ("no lowPrivUser for the app in apex-sync.json" if not user
                                        else "no $APEX_TEST_PASSWORD_LOW for the low-privilege user")
        else:
            p = pw(a.app, ["login"], env, TIMEOUT)
            if p.returncode != 0:
                last = ((p.stderr or p.stdout or "").strip().splitlines() or [""])[-1]
                raise Stop("BLOCKED", "LOW_LOGIN", "the low-privilege user's login was not verified: " + scrub(redact(last))[:200])
            try:
                low = browser(a.app, {"open": a.role, "tamper": False, "xss": None}, env)
            finally:
                pw(a.app, ["close"], env, 60)          # the low session never outlives the probe
            for got in low.get("open", []):
                r = refused(ctl.get(got["url"]), got)
                add("SEC-ROLE-REFUSED", r, None if r else
                    f"{clean(got['url'])}: " + ("the control rendered no page" if r is None else f"rendered for {user}"))
    if a.xss:
        x = main.get("xss") or {}
        if x.get("elements"):
            add("SEC-XSS-ESCAPED", False, f"the payload rendered as markup ({x['elements']} element(s))")
        elif x.get("text"):
            add("SEC-XSS-ESCAPED", True, None)
        else:
            crit["SEC-XSS-ESCAPED"] = "the payload is not on the held page"
    return main


def main(argv):
    ap = argparse.ArgumentParser(description="apex-security runtime probes through pw.sh")
    ap.add_argument("--app")
    ap.add_argument("--task")
    ap.add_argument("--anon", action="append", default=[])
    ap.add_argument("--tamper", action="store_true")
    ap.add_argument("--role", action="append", default=[])
    ap.add_argument("--xss")
    a = ap.parse_args(argv)
    result = {"kind": "security-result", "schemaVersion": 1, "status": "UNKNOWN", "reasons": [],
              "context": context(a.task, "apex-security"), "scope": "runtime", "criteria": [], "advisories": []}
    task_dir = None
    asked = {"SEC-ANON-REDIRECT": a.anon, "SEC-CHECKSUM-TAMPER": a.tamper, "SEC-ROLE-REFUSED": a.role, "SEC-XSS-ESCAPED": a.xss}
    crit = {k: None if v else "not asked for (no --" + {"SEC-ANON-REDIRECT": "anon", "SEC-CHECKSUM-TAMPER": "tamper",
            "SEC-ROLE-REFUSED": "role", "SEC-XSS-ESCAPED": "xss"}[k] + ")" for k, v in asked.items()}
    outcomes = {k: [] for k in CRITERIA}           # (held: True/False/None, detail)
    try:
        if a.xss is not None and not re.fullmatch(r"[A-Za-z0-9_-]{4,40}", a.xss):
            raise Stop("BLOCKED", "BAD_TOKEN", "--xss takes a token of 4-40 letters, digits, '_' or '-'")
        alias, task_dir, settings = target(a.app, a.task)
        if alias:
            result["app"] = {"appAlias": alias}
        if not any(asked.values()):
            raise Stop("BLOCKED", "NOTHING_TO_PROBE", "ask for at least one probe: --anon, --tamper, --role, --xss")
        m = probe(a, alias, settings, crit, lambda cid, held, detail: outcomes[cid].append((held, detail)))
        url = clean((m or {}).get("url", ""))
        if re.match(r"^https?://\S+$", url):
            result["context"]["target"] = {"runtimeUrl": re.sub(r"[?&]cs=<cs>", "", url)}
        unknown = [d for k in CRITERIA for h, d in outcomes[k] if h is None]
        for k in CRITERIA:
            fails = [{"detail": d} for h, d in outcomes[k] if h is False]
            c = {"id": k, "status": "FAIL" if fails else "PASS", "findings": fails}
            if not fails and (crit[k] or not outcomes[k] or any(h is None for h, _ in outcomes[k])):
                c.update(status="NOT_RUN", notApplicableReason=crit[k] or "; ".join(d for h, d in outcomes[k] if h is None)[:500])
            result["criteria"].append(c)
        failed = [c["id"] for c in result["criteria"] if c["status"] == "FAIL"]
        if failed:
            result["status"], result["reasons"] = "FAIL", [{"code": "SECURITY_CRITERIA_FAILED", "message": f"not refused or not escaped: {', '.join(failed)}"}]
        elif unknown:
            result["status"], result["reasons"] = "UNKNOWN", [{"code": "NO_CONTROL", "message": unknown[0][:300]}]
        elif any(c["status"] == "PASS" for c in result["criteria"]):
            result["status"], result["reasons"] = "PASS", [{"code": "SECURITY_CRITERIA_HELD", "message": "every probe asked for was refused or escaped"}]
        else:
            result["status"], result["reasons"] = "UNKNOWN", [{"code": "NOTHING_EXERCISED", "message": "no probe found anything to exercise"}]
    except Stop as s:
        result["status"], result["reasons"] = s.status, [{"code": s.code, "message": s.message}]
    return write(result, task_dir, f"security-{result.get('app', {}).get('appAlias', 'app')}-runtime.json")


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
