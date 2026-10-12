#!/usr/bin/env bash
# framework/scripts/evidence.py, in a scratch repo:
#   capture   stdout saved under raw/<gate>-<alias>/, its sha256 printed; session ids, the home
#             dir, a password assignment and a connect string never reach the file; the evidence
#             dir gets its .gitignore; a bad name or no command → 2, a command that cannot run → 3
#   write     runtime: the status is derived (PASS · required FAIL → FAIL · no browser or an
#             unverified login → BLOCKED · a required criterion not run → UNKNOWN); appId and
#             runtimeUrl come from apex-sync.json; architecture: PASS on decisions and a scan,
#             red flags → FAIL, missing inputs → BLOCKED, no scan → UNKNOWN
#   refused   (exit 2, nothing written, the value never echoed): a status in the draft, a PASS
#             without evidence, a cited file that changed or is outside the repo, a secret in a
#             field, a decision whose branch and layer disagree
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
EV="$REPO/framework/scripts/evidence.py"
PY=$(command -v python3 || command -v python || true)
[[ -n "$PY" ]] || { echo "evidence: BLOCKED — python3 is required" >&2; exit 2; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/evidence-XXXXXX")
trap 'rm -rf "$WORK"' EXIT
P="$WORK/proj"; mkdir -p "$P"; git -C "$P" init -q
printf '{ "appId": 100, "appAlias": "hr", "runtimeUrl": "https://apex.example/ords/r/ws/hr/" }\n' > "$P/apex-sync.json"
cd "$P"

pass=0; fail=0
ok()  { echo "ok   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1"; fail=$((fail + 1)); }
run() {  # $1 = label, $2 = expected exit, rest = evidence.py args; stdout → out.json, stderr → err.txt
  local label=$1 want=$2 rc=0; shift 2
  "$PY" "$EV" "$@" > "$WORK/out.json" 2> "$WORK/err.txt" || rc=$?
  if [[ $rc -eq $want ]]; then ok "$label (exit $rc)"; else bad "$label: exit $rc, expected $want"; cat "$WORK/err.txt"; fi
}
q() { "$PY" -c "import json,sys
d = json.load(open(sys.argv[1]))
$1" "${2:-$WORK/out.json}"; }
draft() { printf '%s\n' "$1" > "$WORK/d.json"; }
RAW=.apex-evidence/T-1/raw/runtime-hr
SECRET_PW=hunter2-$$
SECRET_CS="scott/tiger$$@db1"   # secrets-scan: allow a fake connect string this test proves never leaks
H=$("$PY" -c 'import os; print(os.path.expanduser("~"))' | tr -d '\r')   # the home dir as Python sees it

# --- capture
run "capture saves the output" 0 capture --gate runtime --task T-1 render -- \
  printf 'rows=2 %s %s password=%s %s home=%s\n' 'f?p=100:1:1234567890' 'x?session=987654321' "$SECRET_PW" "$SECRET_CS" "$H"
if q "import hashlib; assert d['evidence']['path'] == '$RAW/render'; assert d['evidence']['sha256'] == hashlib.sha256(open('$RAW/render','rb').read()).hexdigest(); assert d['exitCode'] == 0 and d['redacted'] == 2, d"; then
  ok "capture: the path and sha256 it prints are the file's"; else bad "capture: wrong evidence ref"; fi
if ! grep -qE "1234567890|987654321|$SECRET_PW|tiger$$" "$RAW/render" && ! grep -qF "$H" "$RAW/render" && grep -q 'home=~' "$RAW/render"; then
  ok "capture: no session id, password, connect string or home dir in the file"; else bad "capture: a value reached the file"; cat "$RAW/render"; fi
if [[ "$(cat .apex-evidence/.gitignore)" == "*" ]]; then ok "capture: the evidence dir ignores itself"; else bad "capture: no .gitignore"; fi
run "capture: a bad name is refused" 2 capture --gate runtime --task T-1 ../x -- true
run "capture: no command is refused" 2 capture --gate runtime --task T-1 empty
run "capture: a command that cannot run is UNKNOWN" 3 capture --gate runtime --task T-1 none -- /nonexistent/cmd

# --- write runtime
CRIT='{"id":"IG-RENDER","required":true,"status":"PASS","observed":"rows=2","evidence":[{"kind":"file","path":"'$RAW'/render"}]}'
BASE='"check":"editable-ig","backend":{"kind":"playwright-cli"},"login":{"user":"QA_HR","status":"PASS"}'
draft "{$BASE,\"criteria\":[$CRIT,{\"id\":\"IG-EXTRA\",\"required\":false,\"status\":\"NOT_RUN\",\"notApplicableReason\":\"not asked\"}]}"
run "runtime: every required criterion passed → PASS" 0 write --kind runtime --task T-1 "$WORK/d.json"
if q "assert d['status'] == 'PASS' and d['app'] == {'appAlias': 'hr', 'appId': 100}; assert d['context']['target']['runtimeUrl'].startswith('https://apex.example'); assert d['context']['producer'] == {'skill': 'apex-sentinel', 'method': 'agent'}; assert len(d['criteria'][0]['evidence'][0]['sha256']) == 64" .apex-evidence/T-1/runtime-hr.json; then
  ok "runtime: written with app, target, producer and the file's hash"; else bad "runtime: the written result is wrong"; fi
draft "{$BASE,\"criteria\":[$CRIT,{\"id\":\"IG-DUP\",\"required\":true,\"status\":\"FAIL\",\"observed\":\"saved twice\"}]}"
run "runtime: a required FAIL → FAIL" 1 write --kind runtime --task T-1 "$WORK/d.json"
draft "{\"check\":\"editable-ig\",\"backend\":{\"kind\":\"none\"},\"login\":{\"user\":\"QA_HR\",\"status\":\"NOT_RUN\"},\"criteria\":[]}"
run "runtime: no browser → BLOCKED" 2 write --kind runtime --task T-1 "$WORK/d.json"
if q "assert d['reasons'][0]['code'] == 'NO_BROWSER'"; then ok "runtime: BLOCKED says why"; else bad "runtime: BLOCKED reason"; fi
draft "{\"check\":\"editable-ig\",\"backend\":{\"kind\":\"playwright-cli\"},\"login\":{\"user\":\"QA_HR\",\"status\":\"FAIL\"},\"criteria\":[$CRIT]}"
run "runtime: an unverified login → BLOCKED" 2 write --kind runtime --task T-1 "$WORK/d.json"
draft "{$BASE,\"criteria\":[$CRIT,{\"id\":\"IG-DUP\",\"required\":true,\"status\":\"NOT_RUN\",\"notApplicableReason\":\"no data\"}]}"
run "runtime: a required criterion not run → UNKNOWN" 3 write --kind runtime --task T-1 "$WORK/d.json"

# --- refusals
rm -f .apex-evidence/T-1/runtime-hr.json
draft "{$BASE,\"status\":\"PASS\",\"criteria\":[$CRIT]}"
run "refused: a status in the draft" 2 write --kind runtime --task T-1 "$WORK/d.json"
draft "{$BASE,\"criteria\":[{\"id\":\"IG-RENDER\",\"required\":true,\"status\":\"PASS\",\"observed\":\"trust me\"}]}"
run "refused: a PASS without evidence" 2 write --kind runtime --task T-1 "$WORK/d.json"
draft "{$BASE,\"criteria\":[{\"id\":\"IG-RENDER\",\"required\":true,\"status\":\"FAIL\",\"observed\":\"login as $SECRET_CS\"}]}"
run "refused: a connect string in a field" 2 write --kind runtime --task T-1 "$WORK/d.json"
if grep -q "criteria\[0\].observed" "$WORK/err.txt" && ! grep -q "tiger" "$WORK/err.txt"; then ok "refused: names the field, never the value"; else bad "refused: the message"; cat "$WORK/err.txt"; fi
draft "{$BASE,\"criteria\":[{\"id\":\"IG-RENDER\",\"required\":true,\"status\":\"PASS\",\"observed\":\"x\",\"evidence\":[{\"kind\":\"file\",\"path\":\"$RAW/render\",\"sha256\":\"$(printf 'a%.0s' {1..64})\"}]}]}"
run "refused: a cited file that changed" 2 write --kind runtime --task T-1 "$WORK/d.json"
draft "{$BASE,\"criteria\":[{\"id\":\"IG-RENDER\",\"required\":true,\"status\":\"PASS\",\"observed\":\"x\",\"evidence\":[{\"kind\":\"file\",\"path\":\"../outside\"}]}]}"
run "refused: a file outside the repo" 2 write --kind runtime --task T-1 "$WORK/d.json"
if [[ ! -e .apex-evidence/T-1/runtime-hr.json ]]; then ok "refused: nothing written"; else bad "refused: a result was written"; fi

# --- write architecture
printf 'create table t (id number);\n' > t.sql
DEC='{"subject":"a code is unique","type":"rule","branch":"A1","layer":"constraint","evidence":[{"kind":"file","path":"t.sql"}]}'
SCAN='{"kind":"command","command":"python3 arch-scan.py apex/","exitCode":0}'
draft "{\"decisions\":[$DEC],\"evidence\":[$SCAN]}"
run "architecture: decisions and a clean scan → PASS" 0 write --kind architecture --task T-1 "$WORK/d.json"
if q "assert d['status'] == 'PASS' and d['redFlags'] == [] and d['missingInputs'] == []" .apex-evidence/T-1/architecture.json; then
  ok "architecture: written to architecture.json"; else bad "architecture: the written result is wrong"; fi
draft "{\"decisions\":[$DEC],\"redFlags\":[{\"code\":\"DML_IN_PAGE_PROCESS\",\"path\":\"p.apx\",\"line\":3}],\"evidence\":[$SCAN]}"
run "architecture: a red flag → FAIL" 1 write --kind architecture --task T-1 "$WORK/d.json"
draft "{\"decisions\":[$DEC],\"missingInputs\":[\"which app owns the table\"],\"evidence\":[$SCAN]}"
run "architecture: a missing input → BLOCKED" 2 write --kind architecture --task T-1 "$WORK/d.json"
draft "{\"decisions\":[$DEC]}"
run "architecture: no scan in evidence → UNKNOWN" 3 write --kind architecture --task T-1 "$WORK/d.json"
draft "{\"decisions\":[{\"subject\":\"x\",\"type\":\"rule\",\"branch\":\"A1\",\"layer\":\"entity\",\"package\":\"pkg_x\",\"evidence\":[{\"kind\":\"file\",\"path\":\"t.sql\"}]}],\"evidence\":[$SCAN]}"
run "refused: a branch and layer that disagree" 2 write --kind architecture --task T-1 "$WORK/d.json"

echo "evidence: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
