#!/usr/bin/env bash
# apexlang-architecture's red-flag scan (skills/apexlang-architecture/scripts/arch-scan.py):
#   pass/          a marked loader and IG wrapper, an invokeApi process, near-miss DML in
#                  comments and literals, a versioned UPDATE, a reviewed one, a _flow that
#                  only calls packages → PASS, exit 0, no advisory
#   fail/          exactly the flags in fail.expected (the marker does not excuse a statement;
#                  a review two lines up does not count) → exit 1, and one advisory for the
#                  unmarked executeCode
#   unparsed.*     an .apx the reader cannot follow, an unclosed literal → UNKNOWN, exit 3
#   no input, a file outside the repo → BLOCKED, exit 2
#   examples/      the repo's packages and pages → PASS, no advisory
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
SCAN="$REPO/skills/apexlang-architecture/scripts/arch-scan.py"
FIX="$REPO/tests/integration/fixtures/arch-scan"
PY=$(command -v python3 || command -v python || true)
[[ -n "$PY" ]] || { echo "arch-scan: BLOCKED — python3 is required" >&2; exit 2; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/arch-scan-XXXXXX")
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

expect_rc "pass/ is PASS" 0 "$FIX/pass"
if q "assert d['status'] == 'PASS' and d['advisories'] == [], d"; then ok "pass/: no advisory"; else bad "pass/: an advisory fired"; fi
expect_rc "fail/ has red flags" 1 "$FIX/fail"
got=$(q "print('\n'.join(f\"{f['path'].rsplit('/', 1)[1]} {f['line']} {f['code']}\" for f in d['redFlags']))" | tr -d '\r' | sort)
want=$(tr -d '\r' < "$FIX/fail.expected" | sort)
if [[ "$got" == "$want" ]]; then ok "fail/ red flags match fail.expected"
else bad "fail/ red flags differ"; diff <(echo "$want") <(echo "$got") || true; fi
if q "assert [(a['code'], a['line']) for a in d['advisories']] == [('THIN_WRAPPER_UNMARKED', 33)], d['advisories']"; then
  ok "fail/: the unmarked executeCode is an advisory"; else bad "fail/: wrong advisories"; fi
expect_rc "unparsed.apx is UNKNOWN" 3 "$FIX/unparsed.apx"
expect_rc "unparsed.sql is UNKNOWN" 3 "$FIX/unparsed.sql"
expect_rc "no input is BLOCKED" 2
cp "$FIX/pass/pkg_things.sql" "$WORK/"
expect_rc "a file outside the repo is BLOCKED" 2 "$WORK/pkg_things.sql"

expect_rc "the repo's examples are PASS" 0 "$REPO/skills/apexlang-architecture/examples"
if q "assert d['advisories'] == [], d['advisories']"; then ok "every example executeCode is a marked thin wrapper"
else bad "an example executeCode has no thin-wrapper marker"; fi

echo "arch-scan: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
