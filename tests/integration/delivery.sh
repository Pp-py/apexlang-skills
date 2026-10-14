#!/usr/bin/env bash
# apexlang-delivery's aggregator (skills/apexlang-delivery/scripts/delivery.py), over a scratch
# repo whose task dir holds results as their producers write them: the contract fixtures,
# stamped with the task and the working tree, and a real `evidence.py capture` for Validation.
#   * a gate's status is its results' worst; the manifest's is the required gates' worst;
#   * missing or stale (another task, another tree) → NOT_RUN; invalid → UNKNOWN;
#   * Validation PASSes only on exit 0 and the compiler's own words;
#   * Security and UI are required only when the app opts in; --skip says why;
#   * the next step is the first required gate not run, or where to stop;
#   * every manifest it writes validates (the contract tier captures them).
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
DLV="$REPO/skills/apexlang-delivery/scripts/delivery.py"
EV="$REPO/framework/scripts/evidence.py"
FIX="$REPO/tests/contract/fixtures"
PY=$(command -v python3 || command -v python || true)
[[ -n "$PY" ]] || { echo "delivery: BLOCKED — python3 is required" >&2; exit 2; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/delivery-XXXXXX")
trap 'rm -rf "$WORK"' EXIT
P="$WORK/proj"; mkdir -p "$P"; git -C "$P" init -q
cd "$P"
config() { printf '%s\n' "$1" > apex-sync.json; }
config '{ "appId": 100, "appAlias": "hr", "apexlangDir": "src", "sqlclConnection": "dev" }'
T=.apex-evidence/T-1
mkdir -p "$T" && printf '*\n' > .apex-evidence/.gitignore

pass=0; fail=0
ok()  { echo "ok   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1"; fail=$((fail + 1)); sed 's/^/       | /' "$WORK/err.txt" | tail -12; }
run() {  # $1 = label, $2 = expected exit, rest = delivery.py args; stdout → out.json, stderr → err.txt
  local label=$1 want=$2 rc=0; shift 2
  "$PY" "$DLV" "$@" > "$WORK/out.json" 2> "$WORK/err.txt" || rc=$?
  if [[ $rc -eq $want ]]; then ok "$label (exit $rc)"; else bad "$label: exit $rc, expected $want"; fi
}
q() {  # $1 = a python assertion on d (the manifest on stdout) and g (its gates by name)
  if "$PY" -c "import json,sys
d = json.load(open(sys.argv[1])); g = {x['gate']: x for x in d['gates']}
assert $1, (d['status'], {k: (v['status'], v['required']) for k, v in g.items()})" "$WORK/out.json" 2>"$WORK/assert.txt"; then return 0
  else sed 's/^/       | /' "$WORK/assert.txt" | tail -3; return 1; fi
}
says() { grep -q -- "$1" "$WORK/err.txt"; }
stamp() {  # $1 = fixture (kind/name), $2 = file name in the task dir, [$3 = task to stamp, default T-1]
  "$PY" - "$FIX/$1.json" "$T/$2" "${3:-T-1}" "$REPO/framework/lib" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[4])
from result import tree
d = json.load(open(sys.argv[1]))
d["context"]["task"] = sys.argv[3]
d["context"]["repo"]["tree"] = tree()
json.dump(d, open(sys.argv[2], "w"), indent=2)
PY
}
validate() {  # $1 = what the "compiler" prints, $2 = its exit code
  "$PY" "$EV" capture --gate validation --task T-1 validate -- "$PY" -c "import sys; print(sys.argv[1]); sys.exit(int(sys.argv[2]))" "$1" "$2" > /dev/null
}

# --- an empty task: nothing has run
run "empty task → NOT_RUN" 4 --task T-1
if q "d['status'] == 'NOT_RUN' and g['architecture']['required'] and not g['security']['required'] and 'securityGate' in g['security']['notApplicableReason'] and g['ui']['status'] == 'NOT_RUN'" && says "next — run the architecture gate"; then
  ok "empty: Security and UI not required (opt-in), next is Architecture"; else bad "empty: wrong gates or next step"; fi
if [[ -f "$T/manifest.json" ]] && cmp -s "$T/manifest.json" "$WORK/out.json"; then ok "the manifest is written to the task dir"; else bad "no manifest in the task dir"; fi

# --- the four default gates, one by one
stamp architecture-result/pass architecture.json
run "architecture PASS → next is Validation" 4 --task T-1
if says "next — run the validation gate"; then ok "next: validation"; else bad "next: not validation"; fi
validate "Validation successful" 0
stamp sync-result/check-import-pass sync-hr-check-import.json
stamp runtime-result/editable-ig-pass runtime-hr.json
run "architecture, validation, sync, runtime PASS → PASS" 0 --task T-1
if q "d['status'] == 'PASS' and g['validation']['evidence'][0]['output'] == 'Validation successful' and len(g['sync']['results']) == 1 and d['schemaCheck'] in ('jsonschema', 'structural')" && says "every required gate PASSes"; then
  ok "PASS: Validation cites the compiler's words, each gate its result and sha256"; else bad "PASS: the manifest is wrong"; fi

# --- Validation: only the compiler's own words, on exit 0
validate "Validación correcta." 0
run "validation: exit 0 in another language → UNKNOWN" 3 --task T-1
validate "Compile Errors: 3" 1
run "validation: compile errors → FAIL, and stop there" 1 --task T-1
if says "stop — the validation gate is FAIL"; then ok "stop at validation"; else bad "no stop at validation"; fi
validate "APEXlang version 26.2.0+3479 is not supported by this SQLcl version." 0
run "validation: SQLcl cannot read the version (UP-2) → BLOCKED" 2 --task T-1
validate "Validation successful" 0

# --- the worst result, and the first required gate that is not PASS
stamp sync-result/check-import-conflict sync-hr-check-import.json
run "sync CONFLICT → CONFLICT (exit 1)" 1 --task T-1
if q "d['status'] == 'CONFLICT' and g['runtime']['status'] == 'PASS'" && says "stop — the sync gate is CONFLICT"; then ok "stop at sync, later gates still read"; else bad "conflict: wrong stop"; fi
stamp sync-result/check-import-pass sync-hr-check-import.json

# --- freshness: another task, another working tree
stamp runtime-result/editable-ig-pass runtime-hr.json T-0
run "a result made for another task → NOT_RUN" 4 --task T-1
if says "runtime-hr.json: stale — made for task T-0"; then ok "stale: names the other task"; else bad "stale: no reason"; fi
stamp runtime-result/editable-ig-pass runtime-hr.json
echo x > tracked.txt
run "the working tree changed since → NOT_RUN" 4 --task T-1
if q "g['architecture']['status'] == 'NOT_RUN'" && says "the working tree changed since"; then ok "a changed tree makes every result stale"; else bad "changed tree: not stale"; fi
rm tracked.txt

# --- invalid results are UNKNOWN, never read
"$PY" - "$T/runtime-hr.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["criteria"][0]["status"] = "FAIL"   # a PASS over a FAIL criterion
json.dump(d, open(sys.argv[1], "w"))
PY
run "a PASS over a FAIL criterion → UNKNOWN" 3 --task T-1
if says "runtime-hr.json: invalid"; then ok "invalid: named"; else bad "invalid: not named"; fi
printf '{ not json' > "$T/runtime-hr.json"
run "an unreadable result → UNKNOWN" 3 --task T-1
stamp runtime-result/editable-ig-pass runtime-hr.json

# --- Security and UI, when the app opts in
config '{ "appId": 100, "appAlias": "hr", "apexlangDir": "src", "sqlclConnection": "dev", "securityGate": true, "uiGate": true }'
# a changed apex-sync.json is a changed working tree: what ran before is stale, run it again
run "after a config change every result is stale → NOT_RUN" 4 --task T-1
if q "all(x['status'] == 'NOT_RUN' for x in d['gates'])" && says "Validation capture is stale"; then ok "stale: Validation too"; else bad "stale after config: not all"; fi
restamp() {
  stamp architecture-result/pass architecture.json; stamp sync-result/check-import-pass sync-hr-check-import.json
  stamp runtime-result/editable-ig-pass runtime-hr.json; validate "Validation successful" 0
}
restamp
run "securityGate with no security result → NOT_RUN, next is Security" 4 --task T-1
if says "next — run the security gate"; then ok "next: security"; else bad "next: not security"; fi
for s in static plsql secrets; do stamp "security-result/$s-pass" "security-hr-$s.json"; done
run "three security scopes of four → NOT_RUN" 4 --task T-1
stamp security-result/runtime-pass security-hr-runtime.json
stamp ui-result/static-pass ui-hr-static.json
run "Security PASS on four scopes; UI static only → NOT_RUN (a page is needed)" 4 --task T-1
if q "g['security']['status'] == 'PASS' and len(g['security']['results']) == 4 and g['ui']['status'] == 'NOT_RUN'"; then ok "security: four results cited"; else bad "security: wrong"; fi
"$PY" - "$FIX/ui-result/runtime-fail.json" "$T/ui-hr-runtime-orders.json" "$REPO/framework/lib" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[3])
from result import tree
d = json.load(open(sys.argv[1]))
for c in d["criteria"]:
    if c["status"] == "FAIL":
        c["status"], c["findings"] = "PASS", []
d["status"] = "PASS"
d["reasons"] = [{"code": "UI_CRITERIA_HELD", "message": "1 axe run(s), 0 dialog(s)"}]
d["context"]["task"], d["context"]["repo"]["tree"] = "T-1", tree()
json.dump(d, open(sys.argv[2], "w"), indent=2)
PY
run "every gate PASS with Security and UI required → PASS" 0 --task T-1
if q "g['ui']['required'] and len(g['ui']['results']) == 2"; then ok "ui: static and a page"; else bad "ui: wrong"; fi
stamp security-result/static-fail security-hr-static.json
run "a security scope FAIL → FAIL" 1 --task T-1
if says "stop — the security gate is FAIL"; then ok "stop at security"; else bad "no stop at security"; fi
stamp security-result/static-pass security-hr-static.json

# --- skipping a gate is recorded, never silent
run "--skip runtime:<reason> → runtime not required" 0 --task T-1 --skip "runtime:a migration with no page"
if q "not g['runtime']['required'] and g['runtime']['notApplicableReason'] == 'a migration with no page'"; then ok "skip: required false with the reason"; else bad "skip: not recorded"; fi
run "--skip without a reason → BLOCKED" 2 --task T-1 --skip runtime
run "--skip of no gate → BLOCKED" 2 --task T-1 --skip "deploy:x"
run "a bad task id → BLOCKED" 2 --task "../x"

# --- conformance: GATES.md §The orchestration contract, rule by rule
# MUST read a missing result — or one left by an earlier run — as BLOCKED when the command exited
# 2, UNKNOWN otherwise (delivery.py sees files, so the agent passes the exit with --exit).
mv "$T/runtime-hr.json" "$WORK/runtime.keep"
run "conformance: no result, the command exited 2 → BLOCKED" 2 --task T-1 --exit runtime:2
if says "ran (exit 2) but runtime-hr.json: not in the task" && says "stop — the runtime gate is BLOCKED"; then ok "conformance: BLOCKED, and the stop names it"; else bad "conformance: exit 2 not read"; fi
run "conformance: no result, the command exited 3 → UNKNOWN" 3 --task T-1 --exit runtime:3
run "conformance: no result, the command exited 1 → UNKNOWN (never FAIL, never PASS)" 3 --task T-1 --exit runtime:1
run "conformance: no result and no --exit → NOT_RUN" 4 --task T-1
mv "$WORK/runtime.keep" "$T/runtime-hr.json"
stamp runtime-result/editable-ig-pass runtime-hr.json T-0
run "conformance: a result left by an earlier run, the command exited 2 → BLOCKED" 2 --task T-1 --exit runtime:2
if q "g['runtime']['status'] == 'BLOCKED' and d['status'] == 'BLOCKED'"; then ok "conformance: the stale result is not read"; else bad "conformance: stale + exit 2"; fi
stamp runtime-result/editable-ig-pass runtime-hr.json
run "conformance: a PASS whose command exited 1 → UNKNOWN" 3 --task T-1 --exit runtime:1
if says "but its command exited 1"; then ok "conformance: the disagreement is named"; else bad "conformance: disagreement not named"; fi
run "conformance: a PASS whose command exited 0 → PASS" 0 --task T-1 --exit runtime:0
mv "$T/raw/validation-hr" "$WORK/validation.keep"
run "conformance: no Validation capture, it exited 2 → BLOCKED" 2 --task T-1 --exit validation:2
if q "g['validation']['status'] == 'BLOCKED'"; then ok "conformance: Validation BLOCKED in the manifest"; else bad "conformance: validation exit 2"; fi
mv "$WORK/validation.keep" "$T/raw/validation-hr"
run "conformance: --exit without a code → BLOCKED" 2 --task T-1 --exit runtime
run "conformance: --exit of no gate → BLOCKED" 2 --task T-1 --exit "deploy:0"
if says "(BAD_EXIT)"; then ok "conformance: a bad --exit is refused by delivery itself"; else bad "conformance: bad --exit"; fi
# MUST write the manifest with the aggregation rule: FAIL > CONFLICT > UNKNOWN > BLOCKED > NOT_RUN > PASS
validate "Compile Errors: 1" 1
stamp sync-result/check-import-conflict sync-hr-check-import.json
run "conformance: FAIL beats CONFLICT" 1 --task T-1
if q "d['status'] == 'FAIL' and g['sync']['status'] == 'CONFLICT'"; then ok "conformance: the worst required gate is the task's"; else bad "conformance: aggregation"; fi
validate "Validation successful" 0
run "conformance: CONFLICT beats a later UNKNOWN" 1 --task T-1 --exit runtime:1
if q "d['status'] == 'CONFLICT'"; then ok "conformance: CONFLICT over UNKNOWN"; else bad "conformance: CONFLICT not kept"; fi
stamp sync-result/check-import-pass sync-hr-check-import.json
# MAY skip a gate only as required: false with a reason; with none required the task is NOT_RUN, never PASS
run "conformance: every gate skipped → NOT_RUN, never PASS" 4 --task T-1 --skip "architecture:x" --skip "validation:x" --skip "sync:x" --skip "runtime:x" --skip "security:x" --skip "ui:x"
if q "d['status'] == 'NOT_RUN' and not any(x['required'] for x in d['gates'])"; then ok "conformance: no required gate is NOT_RUN"; else bad "conformance: no required gate"; fi
# MUST NOT turn a non-PASS into PASS: a FAIL gate not required does not lower the task
stamp security-result/static-fail security-hr-static.json
run "conformance: a FAIL in a skipped gate does not count — but is recorded as NOT_RUN" 0 --task T-1 --skip "security:reviewed by hand in T-0"
if q "g['security']['status'] == 'NOT_RUN' and not g['security']['required']"; then ok "conformance: a skipped gate is NOT_RUN with its reason"; else bad "conformance: skipped gate"; fi
stamp security-result/static-pass security-hr-static.json

# --- an app with environments names the one verified
config '{ "appId": 100, "appAlias": "hr", "apexlangDir": "src", "environments": { "dev": { "sqlclConnection": "dev" } } }'
run "environments and no --env → BLOCKED" 2 --task T-1
restamp
run "--env dev reads the environment's results" 4 --task T-1 --env dev
if says "sync-hr.dev-check-import.json: not in the task" && says "runtime-hr.dev.json"; then ok "env: keyed hr.dev; validation keyed by the alias"; else bad "env: wrong keys"; fi
if q "g['validation']['status'] == 'PASS'"; then ok "env: Validation of the source holds for every environment"; else bad "env: validation not read"; fi

# --- the core without its schemas: with jsonschema installed, the check BLOCKS (NO_SCHEMAS); it never crashes
if "$PY" -c "import jsonschema" 2>/dev/null; then
  CORE="$WORK/core"; mkdir -p "$CORE/skills" "$CORE/framework"
  cp -r "$REPO/skills/apexlang-delivery" "$CORE/skills/"
  cp -r "$REPO/framework/lib" "$CORE/framework/"            # no framework/schemas/ in this copy
  config '{ "appId": 100, "appAlias": "hr", "apexlangDir": "src", "sqlclConnection": "dev" }'
  rc=0; "$PY" "$CORE/skills/apexlang-delivery/scripts/delivery.py" --task T-1 --app hr > "$WORK/out.json" 2> "$WORK/err.txt" || rc=$?
  if [[ $rc -eq 2 ]] && says "NO_SCHEMAS"; then ok "no schemas with jsonschema → BLOCKED (exit 2), not a crash"; else bad "no schemas: exit $rc, expected 2 with NO_SCHEMAS"; fi
else
  echo "skip no-schemas case: jsonschema is not installed (the structural check has no schema to miss)"
fi

echo "delivery: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
