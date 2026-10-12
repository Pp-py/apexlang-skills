#!/usr/bin/env python3
"""secrets-scan — apex-security's SEC-NO-SECRETS over the files git tracks.

Usage: python3 secrets-scan.py [--app <alias>] [--task <id>] [<path>...]
       (no path: every file `git ls-files` lists in the repo; binary files are skipped)

FAIL, per file and line — never the value itself:
  a tracked .env / .env.* (not .env.example, .env.sample) · a wallet or key store (cwallet.sso,
  ewallet.p12, *.jks, *.keystore, id_rsa, id_ed25519) · a PEM private key · a password, secret,
  api key or token assigned a literal · a connect string with credentials (user/pw@host,
  scheme://user:pw@host) · a token in a known format (GitHub, AWS access key, Slack)
Not a secret: a placeholder (<...>, ${VAR}, $VAR, %VAR%, ***, xxx, the word itself, empty) or a
line carrying `secrets-scan: allow <reason>`, on it or on the line above.

Output: a security-result (scope secrets) on stdout, and with --task in
<evidenceDir>/<task>/security-<alias>-secrets.json.
Exit:   0 PASS · 1 FAIL · 2 BLOCKED (not a git repo and no path, unreadable, outside the repo).
"""
import argparse
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "framework", "lib"))
from result import ROOT, Stop, context, rel, target, write  # noqa: E402

SECRET_FILES = re.compile(r"(?i)(^|/)(\.env(\.(?!example$|sample$)[^/]+)?|cwallet\.sso|ewallet\.p12|[^/]+\.jks|[^/]+\.keystore|id_rsa|id_ed25519)$")
ALLOW = re.compile(r"secrets-scan:\s*allow\s+\S")
PLACEHOLDER = re.compile(r"""(?ix)^(
    <[^>]*> | \$\{[^}]*\} | \$\w+ | %\w+% | %[sd] | \*+ | x{3,} | \.{3}
  | password | passwd | pwd | pw | secret | token | changeme | example | null | none | true | false
  | tiger | hunter2                                       # Oracle's and the web's stock examples
)$""")
VERSION = re.compile(r"(?i)^(?:v?\d[\w.]*|latest|main|master|next|stable)$")     # actions/checkout@v5
RULES = [
    ("private key", re.compile(r"-----BEGIN (?:[A-Z]+ )?PRIVATE KEY-----")),
    ("GitHub token", re.compile(r"\bgh[pousr]_[A-Za-z0-9]{36,}\b")),
    ("AWS access key", re.compile(r"\bAKIA[0-9A-Z]{16}\b")),
    ("Slack token", re.compile(r"\bxox[abprs]-[A-Za-z0-9-]{10,}\b")),
]
ASSIGN = re.compile(r"""(?ix)\b(?:password|passwd|pwd|secret|api[_-]?key|access[_-]?token|auth[_-]?token|token)\b["']?\s*(?:=|:)\s*(?:(["'])([^"'\n]*)\1|([^\s"',;]+))""")
# secrets-scan: allow the scan's own patterns (the next two lines)
CONNECT = [re.compile(r"\b[A-Za-z][\w$#]*/([^\s/@\"'<>]+)@(?://)?([A-Za-z0-9][\w.-]*)"),   # user/pw@host
           re.compile(r"\b[a-z][a-z0-9+.-]*://[^\s/:@\"']+:([^\s/@\"']+)@[\w.-]+")]      # secrets-scan: allow its pattern


def secret(value):
    value = value.strip().strip("\"'`")
    return bool(value) and not PLACEHOLDER.match(value)


def assigned(m):
    """A literal, not code or prose: quoted (4+ chars), or bare with a digit or a symbol mixed in."""
    quoted, bare = m.group(2), m.group(3)
    if quoted is not None:
        return len(quoted) >= 4 and secret(quoted) and not quoted.startswith(("$", "%", "<"))
    if not secret(bare) or len(bare) < 6 or re.search(r"[($@%{]|^\w+(\.\w+)+", bare):
        return False                              # code: a call, a variable, an attribute
    return bool(re.search(r"\d", bare) and re.search(r"[A-Za-z]", bare))


def scan_file(path, r, add):
    if SECRET_FILES.search(r):
        add(r, 1, "a secret file is tracked: remove it from git and rotate what it held")
        return
    with open(path, "rb") as fh:
        data = fh.read()
    if b"\0" in data[:8000]:
        return                                    # binary
    lines = data.decode("utf-8", "replace").splitlines()
    for no, ln in enumerate(lines, 1):
        if ALLOW.search(ln) or (no > 1 and ALLOW.search(lines[no - 2])):
            continue
        hits = [what for what, rx in RULES if rx.search(ln)]
        hits += ["password or token assigned a literal" for m in ASSIGN.finditer(ln) if assigned(m)][:1]
        hits += ["connect string with credentials" for rx in CONNECT for m in rx.finditer(ln)
                 if secret(m.group(1)) and not (m.lastindex > 1 and VERSION.match(m.group(2)))][:1]
        for what in dict.fromkeys(hits):
            add(r, no, what)


def tracked():
    try:
        p = subprocess.run(["git", "-C", ROOT, "ls-files", "-z"], capture_output=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired):
        p = None
    if not p or p.returncode != 0:
        raise Stop("BLOCKED", "NOT_A_REPO", "not a git repository, and no path given")
    return [os.path.join(ROOT, f) for f in p.stdout.decode("utf-8", "replace").split("\0") if f]


def main(argv):
    ap = argparse.ArgumentParser(description="apex-security secrets scan over tracked files")
    ap.add_argument("--app")
    ap.add_argument("--task")
    ap.add_argument("paths", nargs="*")
    a = ap.parse_args(argv)
    result = {"kind": "security-result", "schemaVersion": 1, "status": "UNKNOWN", "reasons": [],
              "context": context(a.task, "apex-security"), "scope": "secrets", "files": [], "unparsed": [],
              "criteria": [], "advisories": []}
    task_dir = None
    try:
        alias, task_dir, _ = target(a.app, a.task)
        if alias:
            result["app"] = {"appAlias": alias}
        files = []
        for p in a.paths or [None]:
            if p is None:
                files = tracked()
            elif os.path.isdir(p):
                files += [os.path.join(d, n) for d, _, ns in os.walk(p) for n in sorted(ns)]
            elif os.path.isfile(p):
                files.append(p)
            else:
                raise Stop("BLOCKED", "NOTHING_TO_SCAN", f"no such file or directory: {rel(p) or os.path.basename(p)}")
        findings = []
        for f in sorted(set(files)):
            if not os.path.isfile(f):
                continue                          # tracked but deleted in the working tree
            r = rel(f)
            if r is None:
                raise Stop("BLOCKED", "OUTSIDE_REPO", f"{os.path.basename(f)} is outside the repository")
            result["files"].append(r)
            try:
                scan_file(f, r, lambda r, no, what: findings.append({"path": r, "line": no, "detail": what}))
            except OSError as e:
                raise Stop("BLOCKED", "UNREADABLE", f"{r}: {e.__class__.__name__}")
        if not result["files"]:
            raise Stop("BLOCKED", "NOTHING_TO_SCAN", "no file to scan")
        result["criteria"] = [{"id": "SEC-NO-SECRETS", "status": "FAIL" if findings else "PASS", "findings": findings}]
        n = len(result["files"])
        result["status"], result["reasons"] = ("FAIL", [{"code": "SECURITY_CRITERIA_FAILED", "message": f"{n} file(s) scanned; {len(findings)} possible secret(s)"}]) \
            if findings else ("PASS", [{"code": "SECURITY_CRITERIA_HELD", "message": f"{n} file(s); no secret found"}])
    except Stop as s:
        result["status"], result["reasons"] = s.status, [{"code": s.code, "message": s.message}]
    return write(result, task_dir, f"security-{result.get('app', {}).get('appAlias', 'app')}-secrets.json")


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
