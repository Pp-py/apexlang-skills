#!/usr/bin/env bash
# apex-security's static scan (skills/apex-security/scripts/sec-scan.py), in a scratch repo
# whose apex-sync.json carries publicPages, against its fixtures and the repo's examples:
#   pass/         an app that holds every static FAIL criterion, near-misses included → exit 0
#   fail/         every finding in fail.expected and nothing else, the advisories too → exit 1
#   unparsed.apx  a one-line block the parser refuses → UNKNOWN, exit 3 (never a PASS)
#   no input, a file outside the repo, several apps and no --app, a bad publicPages → exit 2
#   --task        the security-result lands in the evidence dir
#   examples/     the runnable examples hold every criterion; no application.apx → SEC-APP-SSP NOT_RUN
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
SCAN="$REPO/skills/apex-security/scripts/sec-scan.py"
FIX="$REPO/tests/integration/fixtures/sec-scan"
PY=$(command -v python3 || command -v python || true)
[[ -n "$PY" ]] || { echo "sec-scan: BLOCKED — python3 is required" >&2; exit 2; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/sec-scan-XXXXXX")
trap 'rm -rf "$WORK"' EXIT
P="$WORK/proj"; mkdir -p "$P"; git -C "$P" init -q
cp -r "$FIX/pass" "$FIX/fail" "$FIX/unparsed.apx" "$P/"

pass=0; fail=0
ok()  { echo "ok   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1"; fail=$((fail + 1)); }
config() { printf '%s\n' "$1" > "$P/apex-sync.json"; }

expect_rc() {  # $1 = label, $2 = expected exit, rest = scan args (run inside the scratch repo)
  local label=$1 want=$2 rc=0; shift 2
  (cd "$P" && "$PY" "$SCAN" "$@" > "$WORK/out.json" 2>/dev/null) || rc=$?
  if [[ $rc -eq $want ]]; then ok "$label (exit $rc)"; else bad "$label: exit $rc, expected $want"; fi
}

config '{ "appId": 100, "appAlias": "demo", "publicPages": [5] }'
expect_rc "pass/ is PASS" 0 pass
if "$PY" -c "import json,sys
d = json.load(open(sys.argv[1]))
assert d['advisories'] == [] and all(c['status'] == 'PASS' for c in d['criteria']), d" "$WORK/out.json"
then ok "pass/: every criterion PASS, no advisory"; else bad "pass/: a criterion or an advisory fired"; fi

config '{ "appId": 100, "appAlias": "demo", "publicPages": [31] }'
expect_rc "fail/ is FAIL" 1 fail
got=$("$PY" -c 'import json,sys
d = json.load(open(sys.argv[1]))
for c in d["criteria"]:
    for f in c["findings"]: print(c["id"], f["path"].rsplit("/", 1)[1], f["line"])
for a in d["advisories"]: print("ADVISE", a["id"])' "$WORK/out.json" | tr -d '\r' | sort)
want=$( { tr -d '\r' < "$FIX/fail.expected"; printf 'ADVISE SEC-SESSION-TIMEOUTS\nADVISE SEC-SESSION-TIMEOUTS\nADVISE SEC-SESSION-REJOIN\n'; } | sort)
if [[ "$got" == "$want" ]]; then ok "fail/ findings and advisories match fail.expected"
else bad "fail/ findings differ from fail.expected"; diff <(echo "$want") <(echo "$got") || true; fi

# What an export leaves out is its version's default (R-8, APEX 26.2): a page with no
# pageAccessProtection is checksummed from 26.2 and unrestricted in 26.1; an app with no
# sessionStateProtection block has it enabled in both.
for v in 26.2.0+3479 26.1.0+3102; do
  mkdir -p "$P/v$v/.apex" "$P/v$v/pages"
  printf '{ "mmdVersion" : "%s" }\n' "$v" > "$P/v$v/.apex/apexlang.json"
  printf 'app V (\n    name: V\n    sessionManagement {\n        maxSessionIdleTime: 3600\n        maxSessionLength: 28800\n        rejoinSessions: false\n    }\n)\n' > "$P/v$v/application.apx"
  printf 'page 7 (\n    name: Plain\n    alias: PLAIN\n    security {\n        authorizationScheme: mustNotBePublicUser\n    }\n)\n' > "$P/v$v/pages/p00007-plain.apx"
done
config '{ "appId": 100, "appAlias": "demo" }'
expect_rc "26.2: no pageAccessProtection (checksum by default), no SSP block (enabled) → PASS" 0 "v26.2.0+3479"
expect_rc "26.1: no pageAccessProtection is unrestricted → FAIL" 1 "v26.1.0+3102"
if "$PY" -c "import json,sys
d = json.load(open(sys.argv[1])); c = {x['id']: x for x in d['criteria']}
assert c['SEC-APP-SSP']['status'] == 'PASS' and c['SEC-PAGE-CHECKSUM']['status'] == 'FAIL', c
assert '26.1 default' in c['SEC-PAGE-CHECKSUM']['findings'][0]['detail']" "$WORK/out.json"
then ok "26.1: the finding names the version's default; SSP PASS"; else bad "26.1: wrong criteria"; fi

expect_rc "unparsed.apx is UNKNOWN" 3 unparsed.apx
expect_rc "no input is BLOCKED" 2
expect_rc "a file outside the repo is BLOCKED" 2 "$FIX/pass/p00010-orders.apx"
config '{ "appId": 100, "appAlias": "demo", "publicPages": ["5"] }'
expect_rc "publicPages that are not numbers → BLOCKED" 2 pass
config '{ "apps": [ { "appId": 1, "appAlias": "a" }, { "appId": 2, "appAlias": "b", "publicPages": [5] } ] }'
expect_rc "several apps and no --app → BLOCKED" 2 pass
expect_rc "several apps, --app b takes its publicPages → PASS" 0 --app b pass

config '{ "appId": 100, "appAlias": "demo", "publicPages": [5] }'
rc=0; (cd "$P" && "$PY" "$SCAN" --task T-1 pass > "$WORK/out.json" 2>/dev/null) || rc=$?
if [[ $rc -eq 0 ]] && cmp -s "$WORK/out.json" "$P/.apex-evidence/T-1/security-demo-static.json"; then
  ok "--task writes .apex-evidence/T-1/security-demo-static.json"
else bad "--task: exit $rc, or the result is not where it belongs"; fi

rc=0; "$PY" "$SCAN" "$REPO/skills/apexlang-architecture/examples" > "$WORK/out.json" 2>/dev/null || rc=$?
if [[ $rc -eq 0 ]] && "$PY" -c "import json,sys
c = {x['id']: x['status'] for x in json.load(open(sys.argv[1]))['criteria']}
assert c.pop('SEC-APP-SSP') == 'NOT_RUN' and set(c.values()) == {'PASS'}, c" "$WORK/out.json"
then ok "the repo's examples are PASS (SEC-APP-SSP NOT_RUN: no application.apx)"
else bad "the repo's examples: exit $rc, or a criterion is not PASS"; fi

echo "sec-scan: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
