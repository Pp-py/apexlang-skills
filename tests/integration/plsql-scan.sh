#!/usr/bin/env bash
# apex-security's package scan (skills/apex-security/scripts/plsql-scan.py):
#   pass.sql      literals, USING, DBMS_ASSERT, a declared constant, q'[…]', comments, a
#                 reviewed parameter → PASS, exit 0, no AUTHID advisory (it states one)
#   fail.sql      exactly the lines in fail.expected (concatenation even under a review
#                 comment; untraced texts with none) → FAIL, exit 1, and the AUTHID advisory
#   page.apx      a ```plsql block concatenating an item → FAIL at its line
#   unparsed.sql  an unclosed literal → UNKNOWN, exit 3 (never a PASS)
#   no input, a file outside the repo → BLOCKED, exit 2; --task writes the result
#   examples/     the repo's packages and pages → PASS, every package states AUTHID
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
SCAN="$REPO/skills/apex-security/scripts/plsql-scan.py"
FIX="$REPO/tests/integration/fixtures/plsql-scan"
PY=$(command -v python3 || command -v python || true)
[[ -n "$PY" ]] || { echo "plsql-scan: BLOCKED — python3 is required" >&2; exit 2; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/plsql-scan-XXXXXX")
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok()  { echo "ok   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1"; fail=$((fail + 1)); }
expect_rc() {  # $1 = label, $2 = expected exit, rest = scan args
  local label=$1 want=$2 rc=0; shift 2
  "$PY" "$SCAN" "$@" > "$WORK/out.json" 2>/dev/null || rc=$?
  if [[ $rc -eq $want ]]; then ok "$label (exit $rc)"; else bad "$label: exit $rc, expected $want"; fi
}
q() { "$PY" -c "import json,sys
d = json.load(open(sys.argv[1]))
$1" "$WORK/out.json"; }

expect_rc "pass.sql is PASS" 0 "$FIX/pass.sql"
if q "assert d['advisories'] == [], d['advisories']"; then ok "pass.sql: no AUTHID advisory"; else bad "pass.sql: an advisory fired"; fi
expect_rc "fail.sql is FAIL" 1 "$FIX/fail.sql"
got=$(q "print('\n'.join(f\"{f['path'].rsplit('/', 1)[1]} {f['line']}\" for f in d['criteria'][0]['findings']))" | tr -d '\r' | sort)
want=$(tr -d '\r' < "$FIX/fail.expected" | sort)
if [[ "$got" == "$want" ]]; then ok "fail.sql findings match fail.expected"
else bad "fail.sql findings differ"; diff <(echo "$want") <(echo "$got") || true; fi
if q "assert [a['id'] for a in d['advisories']] == ['SEC-AUTHID']"; then ok "fail.sql: the AUTHID advisory"; else bad "fail.sql: no AUTHID advisory"; fi
expect_rc "page.apx is FAIL" 1 "$FIX/page.apx"
if q "assert [f['line'] for f in d['criteria'][0]['findings']] == [10]"; then ok "page.apx: the finding is on the .apx line"
else bad "page.apx: wrong line"; fi
expect_rc "unparsed.sql is UNKNOWN" 3 "$FIX/unparsed.sql"
expect_rc "no input is BLOCKED" 2
cp "$FIX/pass.sql" "$WORK/"
expect_rc "a file outside the repo is BLOCKED" 2 "$WORK/pass.sql"

P="$WORK/proj"; mkdir -p "$P"; git -C "$P" init -q; cp "$FIX/pass.sql" "$P/"
printf '{ "appId": 100, "appAlias": "demo" }\n' > "$P/apex-sync.json"
rc=0; (cd "$P" && "$PY" "$SCAN" --task T-1 pass.sql > "$WORK/out.json" 2>/dev/null) || rc=$?
if [[ $rc -eq 0 ]] && cmp -s "$WORK/out.json" "$P/.apex-evidence/T-1/security-demo-plsql.json"; then
  ok "--task writes .apex-evidence/T-1/security-demo-plsql.json"
else bad "--task: exit $rc, or the result is not where it belongs"; fi

expect_rc "the repo's examples are PASS" 0 "$REPO/skills/apexlang-architecture/examples"
if q "assert d['advisories'] == [], d['advisories']"; then ok "every example package states AUTHID"; else bad "an example package states no AUTHID"; fi

echo "plsql-scan: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
