#!/usr/bin/env bash
# apex-security's secrets scan (skills/apex-security/scripts/secrets-scan.py) in a scratch repo:
#   placeholders, code, prose, stock examples and an allowed line → no finding
#   each kind of secret → a finding on its line, never its value; a bare `allow` excuses nothing
#   a tracked .env → FAIL; .env.example with placeholders, a binary, an untracked file → none
#   no git and no path → BLOCKED; --task writes the result; this repo itself → PASS
# The secrets are assembled at run time, so this file never holds one for the scan to find.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
SCAN="$REPO/skills/apex-security/scripts/secrets-scan.py"
PY=$(command -v python3 || command -v python || true)
[[ -n "$PY" ]] || { echo "secrets-scan: BLOCKED — python3 is required" >&2; exit 2; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/secrets-scan-XXXXXX")
trap 'rm -rf "$WORK"' EXIT
P="$WORK/proj"; mkdir -p "$P"; git -C "$P" init -q

K=pass; K=${K}word; V=S3cr3t; V=${V}V4lue        # a key and a value, never side by side here
cat > "$P/clean.txt" <<CLEAN
$K=<your-$K>
$K: \${DB_PASS}
token=\$TOKEN
pwd = getpass.getpass()
$K = "x"
sql scott/tiger@db
uses: actions/checkout@v5
the token: is described in the docs
$K=$V   # secrets-scan: allow a rotated sandbox credential
CLEAN
{
  printf '%s = "%s"\n' "$K" "$V"                                     # 1
  printf 'url=jdbc:oracle:thin:app/%s@dbhost:1521/svc\n' "$V"        # 2
  printf -- '-----BEGIN RSA PRIVATE %s-----\n' KEY                   # 3
  printf 'gh_token: ghp_%s\n' "$(printf 'a%.0s' $(seq 36))"           # 4
  printf 'aws=AKIA%s\n' ABCDEFGHIJKLMNOP                             # 5
  printf 'https://admin:%s@example.com/x\n' "$V"                     # 6
  printf '%s=%s   # secrets-scan: allow\n' "$K" "$V"                 # 7: no reason, no excuse
} > "$P/leaky.txt"
printf '%s=%s\n' "$K" "$V" > "$P/.env"
printf '%s=<your-%s>\n' "$K" "$K" > "$P/.env.example"      # an example file holds placeholders
printf '%s=%s\0binary\n' "$K" "$V" > "$P/blob.bin"
git -C "$P" add clean.txt leaky.txt .env .env.example blob.bin
printf '%s=%s\n' "$K" "$V" > "$P/untracked.txt"
printf '{ "appId": 100, "appAlias": "demo" }\n' > "$P/apex-sync.json"

pass=0; fail=0
ok()  { echo "ok   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1"; fail=$((fail + 1)); }

rc=0; (cd "$P" && "$PY" "$SCAN" > "$WORK/out.json" 2>/dev/null) || rc=$?
if [[ $rc -eq 1 ]]; then ok "the scratch repo is FAIL (exit 1)"; else bad "the scratch repo: exit $rc, expected 1"; fi
got=$("$PY" -c 'import json,sys
for f in json.load(open(sys.argv[1]))["criteria"][0]["findings"]: print(f["path"], f["line"])' "$WORK/out.json" | tr -d '\r' | sort)
want=$(printf '.env 1\nleaky.txt 1\nleaky.txt 2\nleaky.txt 3\nleaky.txt 4\nleaky.txt 5\nleaky.txt 6\nleaky.txt 7\n' | sort)
if [[ "$got" == "$want" ]]; then ok "exactly the planted secrets: none in clean.txt, .env.example, the binary or untracked"
else bad "findings differ"; diff <(echo "$want") <(echo "$got") || true; fi
if grep -q "$V" "$WORK/out.json"; then bad "the result carries a secret's value"; else ok "no finding carries the value"; fi
if "$PY" -c "import json,sys
d = json.load(open(sys.argv[1])); assert 'untracked.txt' not in d['files'] and 'blob.bin' in d['files']" "$WORK/out.json"
then ok "it scans what git tracks (the binary listed, skipped; untracked ignored)"; else bad "the file set is not git's"; fi

rc=0; (cd "$P" && "$PY" "$SCAN" clean.txt > "$WORK/out.json" 2>/dev/null) || rc=$?
if [[ $rc -eq 0 ]]; then ok "an explicit path: clean.txt alone is PASS (exit 0)"; else bad "clean.txt: exit $rc, expected 0"; fi
rc=0; (cd "$P" && "$PY" "$SCAN" --task T-1 clean.txt > "$WORK/out.json" 2>/dev/null) || rc=$?
if [[ $rc -eq 0 ]] && cmp -s "$WORK/out.json" "$P/.apex-evidence/T-1/security-demo-secrets.json"
then ok "--task writes .apex-evidence/T-1/security-demo-secrets.json"; else bad "--task: exit $rc, or no file"; fi
mkdir -p "$WORK/nogit"
rc=0; (cd "$WORK/nogit" && "$PY" "$SCAN" > /dev/null 2>&1) || rc=$?
if [[ $rc -eq 2 ]]; then ok "no git and no path → BLOCKED (exit 2)"; else bad "no git: exit $rc, expected 2"; fi
rc=0; (cd "$REPO" && "$PY" "$SCAN" > /dev/null 2>&1) || rc=$?
if [[ $rc -eq 0 ]]; then ok "this repository holds no secret (exit 0)"; else bad "this repository: exit $rc, expected 0"; fi

echo "secrets-scan: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
