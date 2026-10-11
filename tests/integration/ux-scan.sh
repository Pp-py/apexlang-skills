#!/usr/bin/env bash
# apex-ux's static scan (skills/apex-ux/scripts/ux-scan.py) against its fixtures and
# against the repo's own examples:
#   pass.apx      near-misses that are legal → PASS, exit 0
#   fail.apx      every finding listed in fail.expected, and nothing else → FAIL, exit 1
#   unparsed.apx  shorthand the parser refuses → UNKNOWN, exit 3 (never a PASS)
#   no input      → BLOCKED, exit 2
#   examples/     the runnable examples hold every static FAIL criterion → exit 0
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
SCAN="$REPO/skills/apex-ux/scripts/ux-scan.py"
FIX="$REPO/tests/integration/fixtures/ux-scan"
PY=$(command -v python3 || command -v python || true)
[[ -n "$PY" ]] || { echo "ux-scan: BLOCKED — python3 is required" >&2; exit 2; }

pass=0; fail=0
ok()  { echo "ok   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1"; fail=$((fail + 1)); }

expect_rc() {  # $1 = label, $2 = expected exit, rest = scan args
  local label=$1 want=$2 rc=0; shift 2
  "$PY" "$SCAN" "$@" >/dev/null 2>&1 || rc=$?
  if [[ $rc -eq $want ]]; then ok "$label (exit $rc)"; else bad "$label: exit $rc, expected $want"; fi
}

expect_rc "pass.apx is PASS" 0 "$FIX/pass.apx"
expect_rc "fail.apx is FAIL" 1 "$FIX/fail.apx"
expect_rc "unparsed.apx is UNKNOWN" 3 "$FIX/unparsed.apx"
expect_rc "no input is BLOCKED" 2
expect_rc "missing path is BLOCKED" 2 "$FIX/does-not-exist.apx"
expect_rc "the repo's examples are PASS" 0 "$REPO/skills/apexlang-architecture/examples"

# fail.apx: exactly the expected findings — a check that stops firing, or starts
# firing on a near-miss, shows up here even when the exit code is still 1.
got=$("$PY" "$SCAN" "$FIX/fail.apx" 2>/dev/null \
  | "$PY" -c 'import json,sys
for c in json.load(sys.stdin)["criteria"]:
    for f in c["findings"]: print(c["id"], f["line"])' | tr -d '\r' | sort || true)
want=$(tr -d '\r' < "$FIX/fail.expected" | sort)
if [[ "$got" == "$want" ]]; then ok "fail.apx findings match fail.expected"
else bad "fail.apx findings differ from fail.expected"; diff <(echo "$want") <(echo "$got") || true; fi

echo "ux-scan: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
