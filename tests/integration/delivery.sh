#!/usr/bin/env bash
# apexlang-delivery's aggregator (skills/apexlang-delivery/scripts/delivery.py), over a scratch
# repo whose task dir holds results as their producers write them: the contract fixtures,
# stamped with the task and the working tree, and a real `evidence.py capture` for Validation.
#   * a gate's status is its results' worst; the manifest's is the required gates' worst;
#   * missing or stale (another task, another tree) → NOT_RUN; invalid → UNKNOWN;
#   * a valid, fresh result of another destination (app, environment, operation, scope) is NOT_RUN
#     "misfiled" — never that destination's PASS; the fields compared are the ones a result carries;
#   * Validation PASSes only on exit 0 and the compiler's own words;
#   * Runtime also cites record-sync (the import's second half) and is NOT_RUN without it, with another
#     operation, or when the walkthrough's verdict predates it — the order is read from context.timestamp,
#     which every fixture here sets EXPLICITLY (a constant stamp would pass the order by chance);
#   * Package (pkg-check.py's package-result, between Validation and Sync), Security and UI are required only when the
#     app opts in (packageGate / securityGate / uiGate); --skip says why;
#   * the next step is the first required gate not run, or where to stop;
#   * every manifest it writes validates (the contract tier captures them);
#   * jsonschema is required: without it delivery.py BLOCKS (NO_JSONSCHEMA), and without the
#     core's schemas it BLOCKS (NO_SCHEMAS) — never a weaker check, never a crash.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
DLV="$REPO/skills/apexlang-delivery/scripts/delivery.py"
EV="$REPO/framework/scripts/evidence.py"
FIX="$REPO/tests/contract/fixtures"
PY=$(command -v python3 || command -v python || true)
[[ -n "$PY" ]] || { echo "delivery: BLOCKED — python3 is required" >&2; exit 2; }
# delivery.py needs jsonschema (apexlang-delivery's one non-stdlib dependency): a missing
# prerequisite is BLOCKED and named, never a pass.
"$PY" -c "import jsonschema" 2>/dev/null \
  || { echo "delivery: BLOCKED — python jsonschema is required (apt install python3-jsonschema, or pip install jsonschema)" >&2; exit 2; }
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
# Explicit timestamps: the order of record-sync before Runtime is read from context.timestamp, so no fixture is
# left with the constant its file carries (record-sync 12:05 < runtime 12:30 would pass the order by chance).
RS=2026-11-04T10:00:00Z   # record-sync's verdict
RT=2026-11-04T10:05:00Z   # the Runtime walkthrough's verdict: after the import and its record-sync
SETTS='ts = TS or {"runtime-result": "'$RT'"}.get(d["kind"]) or ("'$RS'" if d.get("operation") == "record-sync" else None)
if ts: d["context"]["timestamp"] = ts'
stamp() {  # $1 = fixture (kind/name), $2 = file name in the task dir, [$3 = task to stamp, default T-1], [$4 = context.timestamp]
  "$PY" - "$FIX/$1.json" "$T/$2" "${3:-T-1}" "$REPO/framework/lib" "${4:-}" "$SETTS" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[4])
from result import tree
d = json.load(open(sys.argv[1]))
d["context"]["task"] = sys.argv[3]
d["context"]["repo"]["tree"] = tree()
TS = sys.argv[5]
exec(sys.argv[6])
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
# a gate the app did not opt in to is excluded by "config", and stderr says so on every branch (next, stop, PASS)
if q "g['security']['excludedBy'] == 'config' and g['ui']['excludedBy'] == 'config' and all('excludedBy' not in x for x in d['gates'] if x['required'])" && says "not evaluated: package (config), security (config), ui (config) - not a statement about them"; then
  ok "excludedBy: config on a gate the app did not opt in to, and the 'not evaluated' line on the next-step branch"; else bad "excludedBy: config / next-step line"; fi
if [[ -f "$T/manifest.json" ]] && cmp -s "$T/manifest.json" "$WORK/out.json"; then ok "the manifest is written to the task dir"; else bad "no manifest in the task dir"; fi

# --- the four default gates, one by one
stamp architecture-result/pass architecture.json
run "architecture PASS → next is Validation" 4 --task T-1
if says "next — run the validation gate"; then ok "next: validation"; else bad "next: not validation"; fi
validate "Validation successful" 0
stamp sync-result/check-import-pass sync-hr-check-import.json
stamp sync-result/record-sync-pass sync-hr-record-sync.json
stamp runtime-result/editable-ig-pass runtime-hr.json
run "architecture, validation, sync, record-sync, runtime PASS → PASS" 0 --task T-1
if q "d['status'] == 'PASS' and g['validation']['evidence'][0]['output'] == 'Validation successful' and len(g['sync']['results']) == 1 and d['schemaCheck'] == 'jsonschema'" && says "every required gate PASSes"; then
  ok "PASS: Validation cites the compiler's words, each gate its result and sha256"; else bad "PASS: the manifest is wrong"; fi
if q "[r['kind'] for r in g['runtime']['results']] == ['runtime-result', 'sync-result'] and g['runtime']['results'][1]['path'].endswith('sync-hr-record-sync.json') and all(len(r['sha256']) == 64 for r in g['runtime']['results'])"; then
  ok "PASS: Runtime cites its own result and record-sync's, each by path and sha256 (Sync still cites check-import alone)"; else bad "PASS: Runtime does not cite record-sync"; fi
if says "not evaluated: package (config), security (config), ui (config) - not a statement about them" && says "every required gate PASSes"; then ok "PASS with Security and UI not opted in: the exclusion line is said beside the verdict"; else bad "PASS: no 'not evaluated' line"; fi

# --- Validation: only the compiler's own words, on exit 0
validate "Validación correcta." 0
run "validation: exit 0 in another language → UNKNOWN" 3 --task T-1
validate "Compile Errors: 3" 1
run "validation: compile errors → FAIL, and stop there" 1 --task T-1
if says "stop — the validation gate is FAIL"; then ok "stop at validation"; else bad "no stop at validation"; fi
if says "not evaluated: package (config), security (config), ui (config) - not a statement about them"; then ok "stop branch: the 'not evaluated' line is there too"; else bad "stop branch: no 'not evaluated' line"; fi
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
  stamp sync-result/record-sync-pass sync-hr-record-sync.json
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
# R2-02: several producers, one exit code: PASSes an earlier run left cannot absorb a failed run
run "R2-02: --exit security:2 while all four scopes read PASS → UNKNOWN" 3 --task T-1 --exit security:2
if q "g['security']['status'] == 'UNKNOWN'" && says "every result reads PASS"; then ok "  ...a failed run is not told apart from the earlier results"; else bad "R2-02: security exit 2 kept PASS"; fi
run "R2-02: --exit security:0 with the four PASS → the gate stays PASS" 4 --task T-1 --exit security:0
if q "g['security']['status'] == 'PASS'"; then ok "  ...control"; else bad "R2-02: security exit 0"; fi
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
run "every gate PASS with Security and UI required, the page declared → PASS" 0 --task T-1 --page orders
if q "g['ui']['required'] and len(g['ui']['results']) == 2"; then ok "ui: static and a page"; else bad "ui: wrong"; fi
stamp security-result/static-fail security-hr-static.json
run "a security scope FAIL → FAIL" 1 --task T-1
if says "stop — the security gate is FAIL"; then ok "stop at security"; else bad "no stop at security"; fi
stamp security-result/static-pass security-hr-static.json

# --- skipping a gate is recorded, never silent
run "--skip runtime:<reason> → runtime not required" 0 --task T-1 --page orders --skip "runtime:a migration with no page"
if q "not g['runtime']['required'] and g['runtime']['notApplicableReason'] == 'a migration with no page'"; then ok "skip: required false with the reason"; else bad "skip: not recorded"; fi
if q "g['runtime']['excludedBy'] == 'skip' and all('excludedBy' not in x for x in d['gates'] if x['required'])" && says "not evaluated: package (config), runtime (skip) - not a statement about them"; then
  ok "excludedBy: skip for --skip (Security and UI are on here, so they are evaluated), and the line names it"; else bad "excludedBy: skip"; fi
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
run "conformance: a PASS whose command exited 0 → PASS" 0 --task T-1 --page orders --exit runtime:0
# R2-01: the capture on disk is fresh (same task, same tree) but the command that just ran exited otherwise
for c in 1 2 3; do
  run "R2-01: a fresh Validation PASS capture, the command exited $c → UNKNOWN (never PASS)" 3 --task T-1 --page orders --exit validation:$c
  if q "g['validation']['status'] == 'UNKNOWN' and d['status'] == 'UNKNOWN'" && says "but its command exited $c"; then ok "  ...named"; else bad "R2-01: validation exit $c kept PASS"; fi
done
run "R2-01: a fresh Validation PASS capture, the command exited 0 → PASS" 0 --task T-1 --page orders --exit validation:0
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
run "conformance: every gate skipped → NOT_RUN, never PASS" 4 --task T-1 --skip "architecture:x" --skip "validation:x" --skip "package:x" --skip "sync:x" --skip "runtime:x" --skip "security:x" --skip "ui:x"
if q "d['status'] == 'NOT_RUN' and not any(x['required'] for x in d['gates'])"; then ok "conformance: no required gate is NOT_RUN"; else bad "conformance: no required gate"; fi
if q "all(x['excludedBy'] == 'skip' for x in d['gates'])" && says "not evaluated: architecture (skip), validation (skip), package (skip), sync (skip), runtime (skip), security (skip), ui (skip) - not a statement about them"; then
  ok "excludedBy: every gate skipped → all 'skip', and the line lists them in gate order"; else bad "excludedBy: every gate skipped"; fi
# MUST NOT turn a non-PASS into PASS: a FAIL gate not required does not lower the task
stamp security-result/static-fail security-hr-static.json
# F-06 pin of today's rule: Security is on here, the result is a fresh FAIL. Without --skip the task is FAIL (the gate was
# evaluated, no excludedBy). --skip still hides it, exit 0, as before; what changed is the evidence: the manifest says the
# caller left the gate out (excludedBy: skip) and stderr names it.
run "excludedBy: a fresh security FAIL, no --skip → FAIL (exit 1), the gate evaluated" 1 --task T-1 --page orders
if q "g['security']['required'] and g['security']['status'] == 'FAIL' and 'excludedBy' not in g['security']"; then ok "  ...required, FAIL, no excludedBy"; else bad "excludedBy: evaluated FAIL"; fi
run "conformance: a FAIL in a skipped gate does not count — but is recorded as NOT_RUN" 0 --task T-1 --page orders --skip "security:reviewed by hand in T-0"
if q "g['security']['status'] == 'NOT_RUN' and not g['security']['required']"; then ok "conformance: a skipped gate is NOT_RUN with its reason"; else bad "conformance: skipped gate"; fi
if q "d['status'] == 'PASS' and g['security']['excludedBy'] == 'skip' and 'results' not in g['security']" && says "not evaluated: package (config), security (skip) - not a statement about them"; then
  ok "excludedBy: --skip over a fresh FAIL is still exit 0 (behavior pinned), but excludedBy is skip and stderr says security was not evaluated"; else bad "excludedBy: skip over a fresh FAIL"; fi
stamp security-result/static-pass security-hr-static.json

# --- an app with environments names the one verified
config '{ "appId": 100, "appAlias": "hr", "apexlangDir": "src", "environments": { "dev": { "sqlclConnection": "dev" } } }'
run "environments and no --env → BLOCKED" 2 --task T-1
restamp
run "--env dev reads the environment's results" 4 --task T-1 --env dev
if says "sync-hr.dev-check-import.json: not in the task" && says "runtime-hr.dev.json"; then ok "env: keyed hr.dev; validation keyed by the alias"; else bad "env: wrong keys"; fi
if q "g['validation']['status'] == 'PASS'"; then ok "env: Validation of the source holds for every environment"; else bad "env: validation not read"; fi

# --- identity: a valid, fresh result is read only for the destination it is about (GATES.md §The
# orchestration contract: validate each result before reading it). A result of another app, another
# environment, another operation or scope is NOT_RUN — "misfiled" — never read as this destination's PASS.
stampm() {  # $1 = fixture, $2 = file in the task dir, $3 = python run on d (the identity edits), stamped for T-1 and the tree
  "$PY" - "$FIX/$1.json" "$T/$2" "$REPO/framework/lib" "${3:-pass}" "$SETTS" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[3])
from result import tree
d = json.load(open(sys.argv[1])); d["context"]["task"] = "T-1"; d["context"]["repo"]["tree"] = tree()
TS = ""
exec(sys.argv[5])         # the default timestamps (record-sync before Runtime); the edits below may override them
exec(sys.argv[4])
json.dump(d, open(sys.argv[2], "w"), indent=2)
PY
}
who() {  # $1 = alias, $2 = appId, [$3 = environment]: python setting a result's identity as its producer writes it
  local s="a = d.setdefault('app', {}); a['appAlias'] = '$1'"$'\n'"if 'appId' in a: a['appId'] = $2"
  [[ -z "${3:-}" ]] || s+=$'\n'"a['environment'] = '$3'"
  printf '%s\n' "$s"
}
PASSUI='d["status"] = "PASS"; d["reasons"] = [{"code": "UI_CRITERIA_HELD", "message": "ok"}]
for c in d["criteria"]:
    if c["status"] == "FAIL": c["status"], c["findings"] = "PASS", []
'
good() {  # $1 = alias, $2 = appId, [$3 = environment]: every gate's result for that app, as each producer writes it
  local al=$1 id=$2 en=${3:-} k=$1${3:+.$3} w ws s
  w=$(who "$al" "$id" "$en"); ws=$(who "$al" "$id")          # static scopes and the decision carry no environment
  rm -rf "$T"; mkdir -p "$T"
  stampm architecture-result/pass architecture.json "$ws"
  stampm package-result/pass "package-$k.json" "$w"
  stampm sync-result/check-import-pass "sync-$k-check-import.json" "$w"
  stampm sync-result/record-sync-pass "sync-$k-record-sync.json" "$w"
  stampm runtime-result/editable-ig-pass "runtime-$k.json" "$w"
  for s in static plsql secrets; do stampm "security-result/$s-pass" "security-$al-$s.json" "$ws"; done
  stampm security-result/runtime-pass "security-$k-runtime.json" "$w"
  stampm ui-result/static-pass "ui-$al-static.json" "$ws"
  stampm ui-result/runtime-fail "ui-$k-runtime-orders.json" "$PASSUI$w"
  "$PY" "$EV" capture --gate validation --app "$al" ${en:+--env "$en"} --task T-1 validate -- "$PY" -c "print('Validation successful')" > /dev/null
}
neg() {  # $1 = label, $2 = file in the task dir, $3 = fixture, $4 = python on d; rest = delivery.py args: that file is misfiled → NOT_RUN
  local label=$1 f=$2 fx=$3 snip=$4; shift 4
  cp "$T/$f" "$WORK/neg.keep"
  stampm "$fx" "$f" "$snip"
  run "$label → NOT_RUN (misfiled)" 4 "$@"
  if says "$f: misfiled" && ! says "$f: not in the task" && q "d['status'] == 'NOT_RUN'"; then ok "  ...and it says misfiled, not missing"; else bad "  $label: not named misfiled"; fi
  mv "$WORK/neg.keep" "$T/$f"
}

config '{ "appId": 100, "appAlias": "hr", "apexlangDir": "src", "sqlclConnection": "dev", "securityGate": true, "uiGate": true }'
good hr 100
run "identity control: every result is hr's → PASS" 0 --task T-1 --app hr --page orders
HR=(--task T-1 --app hr --page orders)
neg "runtime of another app (fin, id 200)" runtime-hr.json runtime-result/editable-ig-pass "$(who fin 200)" "${HR[@]}"
neg "runtime of hr with another appId" runtime-hr.json runtime-result/editable-ig-pass "$(who hr 999)" "${HR[@]}"
neg "sync of another app" sync-hr-check-import.json sync-result/check-import-pass "$(who fin 200)" "${HR[@]}"
neg "ui static with no app at all" ui-hr-static.json ui-result/static-pass "d.pop('app')" "${HR[@]}"
neg "security static whose app names no alias" security-hr-static.json security-result/static-pass "d['app'] = {'appId': 100}" "${HR[@]}"
neg "ui page of another app" ui-hr-runtime-orders.json ui-result/runtime-fail "$PASSUI$(who fin 200)" "${HR[@]}"
neg "security runtime of another app" security-hr-runtime.json security-result/runtime-pass "$(who fin 200)" "${HR[@]}"
neg "an app without environments, a result that says prod" runtime-hr.json runtime-result/editable-ig-pass "$(who hr 100 prod)" "${HR[@]}"
neg "sync check-export saved as check-import" sync-hr-check-import.json sync-result/check-import-pass \
  "d['operation'] = 'check-export'; d['reasons'] = [{'code': 'LOCAL_CLEAN', 'message': 'export check'}]; d.pop('payload', None); d['marker']['path'] = '.git/apex-sync/hr/check-ok.export'; d['changes'] = []" "${HR[@]}"
neg "security plsql saved as static" security-hr-static.json security-result/plsql-pass pass "${HR[@]}"
neg "security secrets saved as plsql" security-hr-plsql.json security-result/secrets-pass pass "${HR[@]}"
neg "security runtime saved as secrets" security-hr-secrets.json security-result/runtime-pass pass "${HR[@]}"
neg "ui static saved as a page" ui-hr-runtime-orders.json ui-result/static-pass pass "${HR[@]}"
# --exit: a command that just ran and left only a result for another destination left none for this one
stampm runtime-result/editable-ig-pass runtime-hr.json "$(who fin 200)"
run "misfiled, the command exited 2 → BLOCKED" 2 "${HR[@]}" --exit runtime:2
if says "ran (exit 2) but runtime-hr.json: misfiled" && q "g['runtime']['status'] == 'BLOCKED'"; then ok "  ...BLOCKED, naming it misfiled"; else bad "misfiled + exit 2"; fi
run "misfiled, the command exited 0 → UNKNOWN (never PASS)" 3 "${HR[@]}" --exit runtime:0
if q "g['runtime']['status'] == 'UNKNOWN' and d['status'] == 'UNKNOWN'"; then ok "  ...UNKNOWN in the manifest"; else bad "misfiled + exit 0"; fi
stampm runtime-result/editable-ig-pass runtime-hr.json "$(who hr 100)"
# controls: fields the reader must NOT insist on
stampm runtime-result/editable-ig-pass runtime-hr.json "$(who hr 100)"$'\n'"d['app'].pop('appId')"
run "control: a runtime result with no appId → PASS (compared only when both exist)" 0 "${HR[@]}"
stampm runtime-result/editable-ig-pass runtime-hr.json "$(who hr 100)"$'\n'"d['context']['target']['runtimeUrl'] = 'http://127.0.0.1:8090/ords/r/ws/hr/'"
run "control: a runtime URL on another host → PASS (the host is not identity)" 0 "${HR[@]}"
# an alias in capitals: compared exactly, as the guard matches it
config '{ "appId": 100, "appAlias": "HR", "apexlangDir": "src", "sqlclConnection": "dev", "securityGate": true, "uiGate": true }'
good HR 100
run "control: capitals in the alias, results of HR → PASS" 0 --task T-1 --app HR --page orders
neg "alias differing only in case (hr for HR)" runtime-HR.json runtime-result/editable-ig-pass "$(who hr 100)" --task T-1 --app HR --page orders

# an app with environments: the results of --env prod are prod's
config '{ "appId": 100, "appAlias": "hr", "apexlangDir": "src", "securityGate": true, "uiGate": true, "environments": { "dev": { "sqlclConnection": "dev" }, "prod": { "sqlclConnection": "prod", "appId": 101 } } }'
good hr 101 prod
PROD=(--task T-1 --app hr --env prod --page orders)
run "control: --env prod, results seeded with environment prod and its appId → PASS" 0 "${PROD[@]}"
if q "len(g['sync']['results']) == 1 and len(g['security']['results']) == 4 and len(g['ui']['results']) == 2"; then ok "  ...all cited"; else bad "env control: results not all cited"; fi
neg "sync of dev read for prod" sync-hr.prod-check-import.json sync-result/check-import-pass "$(who hr 101 dev)" "${PROD[@]}"
neg "runtime of dev read for prod" runtime-hr.prod.json runtime-result/editable-ig-pass "$(who hr 101 dev)" "${PROD[@]}"
neg "security runtime of dev read for prod" security-hr.prod-runtime.json security-result/runtime-pass "$(who hr 101 dev)" "${PROD[@]}"
neg "ui page of dev read for prod" ui-hr.prod-runtime-orders.json ui-result/runtime-fail "$PASSUI$(who hr 101 dev)" "${PROD[@]}"
neg "runtime with no environment under --env prod" runtime-hr.prod.json runtime-result/editable-ig-pass "$(who hr 101)" "${PROD[@]}"
neg "runtime of prod carrying dev's appId (100, not 101)" runtime-hr.prod.json runtime-result/editable-ig-pass "$(who hr 100 prod)" "${PROD[@]}"
# Static scopes read source, not a Builder: shared between environments
stampm security-result/static-pass security-hr-static.json "$(who hr 101 dev)"
stampm ui-result/static-pass ui-hr-static.json "$(who hr 101 dev)"
run "control: static results that name another environment stay PASS (shared)" 0 "${PROD[@]}"

# several apps in one task: the decision is the task's, not an app's (evidence.py: it holds for every environment)
config '{ "apexlangDir": "src", "securityGate": true, "uiGate": true, "apps": [ { "appId": 100, "appAlias": "hr", "sqlclConnection": "dev_hr" }, { "appId": 200, "appAlias": "fin", "sqlclConnection": "dev_fin" } ] }'
good fin 200
stampm architecture-result/pass architecture.json "$(who hr 100)"
run "control: architecture written for hr, read with --app fin in a multi-app task → PASS" 0 --task T-1 --app fin --page orders
neg "runtime of hr read with --app fin" runtime-fin.json runtime-result/editable-ig-pass "$(who hr 100)" --task T-1 --app fin --page orders

# --- UI pages: the task says which pages the change touched (--page <page>[:dialog]); a ui-result is read
# for exactly that page. The page is the part of ui-<key>-runtime-<page>.json that CONTRACTS defines, and
# the result's own runtimeUrl must name it (the same page_name ux-check.py wrote the file name with).
config '{ "appId": 100, "appAlias": "hr", "apexlangDir": "src", "sqlclConnection": "dev", "securityGate": true, "uiGate": true }'
good hr 100
page() {  # $1 = page (file name part), $2 = the result's runtimeUrl, [$3 = python on d after it is a PASS]
  stampm ui-result/runtime-fail "ui-hr-runtime-$1.json" "$PASSUI$(who hr 100)"$'\n'"d['context']['target'] = {'runtimeUrl': '$2'}"$'\n'"${3:-}"
}
NODIALOG="for c in d['criteria']:
    if c['id'] == 'UX-DIALOG-FOCUS': c['status'], c['findings'], c['notApplicableReason'] = 'NOT_RUN', [], 'no --dialog opener was given'"
FAILED="d['status'] = 'FAIL'; d['reasons'] = [{'code': 'UI_CRITERIA_FAILED', 'message': 'x'}]
d['criteria'][0]['status'] = 'FAIL'; d['criteria'][0]['findings'] = [{'rule': 'label', 'impact': 'serious', 'where': 'page', 'count': 1}]"
URLO=https://apex.example/ords/r/ws/app/orders
URLB=https://apex.example/ords/r/ws/app/billing
UIP=(--task T-1 --app hr)
run "ui pages: --page orders, its result names orders → PASS" 0 "${UIP[@]}" --page orders
if q "len(g['ui']['results']) == 2 and g['ui']['status'] == 'PASS' and 'scope' not in g['ui']"; then ok "  ...static and the page cited, no scope in the manifest"; else bad "ui pages: control"; fi
run "ui pages: no --page under uiGate → NOT_RUN, never PASS" 4 "${UIP[@]}"
if q "g['ui']['status'] == 'NOT_RUN' and g['ui']['required'] and d['status'] == 'NOT_RUN'" && says "no page declared" && says '--page <page>\[:dialog\]'; then
  ok "  ...it says how to declare the pages"; else bad "ui pages: no --page not explained"; fi
if says "next — run the ui gate" && says "delivery.py"; then ok "  ...and the next-step hint names --page"; else bad "ui pages: hint"; fi
# the change touches orders and billing; only orders was checked
run "ui pages: orders verified, billing declared and never checked → NOT_RUN" 4 "${UIP[@]}" --page orders --page billing
if says "ui-hr-runtime-billing.json: not in the task" && q "g['ui']['status'] == 'NOT_RUN'"; then ok "  ...naming billing's missing file"; else bad "ui pages: billing not named"; fi
page billing "$URLO"
run "ui pages: billing's file is a copy of orders' (its runtimeUrl names orders) → NOT_RUN" 4 "${UIP[@]}" --page orders --page billing
if says "ui-hr-runtime-billing.json: misfiled" && says "orders" && q "g['ui']['status'] == 'NOT_RUN'"; then ok "  ...misfiled, naming both pages"; else bad "ui pages: duplicate not misfiled"; fi
page billing "https://other.example/ords/r/zz/other/whatever"
run "ui pages: billing's file holds a foreign page's URL → NOT_RUN" 4 "${UIP[@]}" --page orders --page billing
if says "ui-hr-runtime-billing.json: misfiled" && q "g['ui']['status'] == 'NOT_RUN'"; then ok "  ...misfiled"; else bad "ui pages: foreign URL not misfiled"; fi
page billing "$URLB"
run "ui pages: orders and billing, each file names its own page → PASS" 0 "${UIP[@]}" --page orders --page billing
if q "len(g['ui']['results']) == 3"; then ok "  ...three results cited"; else bad "ui pages: two pages not cited"; fi
run "ui pages: control — billing exists but only orders is declared → PASS (an undeclared PASS is cited)" 0 "${UIP[@]}" --page orders
if q "len(g['ui']['results']) == 3"; then ok "  ...and still cited"; else bad "ui pages: undeclared file not cited"; fi
# an undeclared page's result still counts in the worst status
page extra "$URLB" "$FAILED"
run "ui pages: a FAIL on an undeclared page is still FAIL" 1 "${UIP[@]}" --page orders --page billing
if q "g['ui']['status'] == 'FAIL'" && says "stop — the ui gate is FAIL"; then ok "  ...stop at ui"; else bad "ui pages: undeclared FAIL hidden"; fi
run "ui pages: a FAIL on a page when no --page is given is FAIL, not NOT_RUN" 1 "${UIP[@]}"
rm -f "$T/ui-hr-runtime-extra.json"
# a declared page whose result is FAIL
page billing "$URLB" "$FAILED"
run "ui pages: a declared page FAIL → FAIL" 1 "${UIP[@]}" --page orders --page billing
page billing "$URLB"
# a dialog the page opens: declared with :dialog, UX-DIALOG-FOCUS must have PASSed
run "ui pages: orders:dialog, UX-DIALOG-FOCUS PASS → PASS" 0 "${UIP[@]}" --page orders:dialog
page orders "$URLO" "$NODIALOG"
run "ui pages: orders:dialog, UX-DIALOG-FOCUS NOT_RUN → NOT_RUN" 4 "${UIP[@]}" --page orders:dialog
if says "UX-DIALOG-FOCUS" && says "not exercised" && q "g['ui']['status'] == 'NOT_RUN'"; then ok "  ...naming the criterion"; else bad "ui pages: dialog not named"; fi
run "ui pages: control — the same result, orders declared without :dialog → PASS" 0 "${UIP[@]}" --page orders
page orders "$URLO" "d['criteria'] = [c for c in d['criteria'] if c['id'] != 'UX-DIALOG-FOCUS']"
run "ui pages: orders:dialog, no UX-DIALOG-FOCUS in the result → NOT_RUN" 4 "${UIP[@]}" --page orders:dialog
page orders "$URLO"
# a result that records no runtimeUrl is a schema-invalid PASS (UNKNOWN); another status keeps its severity,
# and a FAIL filed under the wrong page still FAILs — only a PASS is held to the page it names
page page "$URLO" "d['context'].pop('target')"
run "ui pages: --page page, a PASS with no runtimeUrl → UNKNOWN (invalid; never matched by the default token)" 3 "${UIP[@]}" --page orders --page page
if says "ui-hr-runtime-page.json: invalid"; then ok "  ...invalid, named"; else bad "ui pages: no runtimeUrl not invalid"; fi
page page "$URLO" "d['status'] = 'BLOCKED'; d['reasons'] = [{'code': 'LOGIN_PAGE', 'message': 'login'}]; d['context'].pop('target'); d.pop('engine', None)
for c in d['criteria']: c['status'], c['findings'], c['notApplicableReason'] = 'NOT_RUN', [], 'blocked'"
run "ui pages: --page page, a BLOCKED result with no runtimeUrl stays BLOCKED (not read as NOT_RUN)" 2 "${UIP[@]}" --page orders --page page
rm -f "$T/ui-hr-runtime-page.json"
page billing "$URLO" "$FAILED"
run "ui pages: billing's file is orders' FAIL → FAIL (only a PASS is held to its page)" 1 "${UIP[@]}" --page orders --page billing
page billing "$URLB"
# the page of an f?p= URL is its page id
page 30 "https://apex.example/pls/apex/f?p=100:30:12345"
run "ui pages: --page 30, an f?p=100:30 URL → PASS" 0 "${UIP[@]}" --page orders --page 30
page 30 "https://apex.example/pls/apex/f?p=100:31:12345"
run "ui pages: --page 30, an f?p=100:31 URL → NOT_RUN" 4 "${UIP[@]}" --page orders --page 30
rm -f "$T/ui-hr-runtime-30.json"
# stale: a declared page's result made for another task
page billing "$URLB" "d['context']['task'] = 'T-0'"
run "ui pages: a declared page's result made for another task → NOT_RUN (stale)" 4 "${UIP[@]}" --page orders --page billing
if says "ui-hr-runtime-billing.json: stale"; then ok "  ...stale"; else bad "ui pages: stale not named"; fi
# --exit ui:<code>: the command ran; a declared page it left no result for is read as the contract says
rm -f "$T/ui-hr-runtime-billing.json"
run "ui pages: --exit ui:2, a declared page has no result → BLOCKED" 2 "${UIP[@]}" --page orders --page billing --exit ui:2
if q "g['ui']['status'] == 'BLOCKED'" && says "ran (exit 2) but ui-hr-runtime-billing.json: not in the task"; then ok "  ...BLOCKED, naming the page"; else bad "ui pages: exit 2 masked"; fi
run "ui pages: --exit ui:1, a declared page has no result → UNKNOWN (never FAIL, never PASS)" 3 "${UIP[@]}" --page orders --page billing --exit ui:1
run "ui pages: --exit ui:2, no --page → BLOCKED (the declaration is what is missing)" 2 "${UIP[@]}" --exit ui:2
run "ui pages: --exit ui:0, every declared page has its PASS → PASS" 0 "${UIP[@]}" --page orders --exit ui:0
run "R2-02: --exit ui:2 while the declared page reads PASS → UNKNOWN" 3 "${UIP[@]}" --page orders --exit ui:2
if q "g['ui']['status'] == 'UNKNOWN'" && says "every result reads PASS"; then ok "  ...not told apart from the earlier page result"; else bad "R2-02: ui exit 2 kept PASS"; fi
page billing "$URLB"
# bad declarations are refused before anything is read
for bad_page in "" "orders:" "orders:modal" "orders:dialog:x" "a b" "a:b" "orders:#open" "orders:a b" "../x" "a/b" "$(printf 'x%.0s' $(seq 1 41))"; do
  run "ui pages: --page '${bad_page:0:12}' → BLOCKED (BAD_PAGE)" 2 "${UIP[@]}" --page "$bad_page"
  if says "BAD_PAGE" && [[ ! -s "$WORK/out.json" ]]; then ok "  ...refused, no manifest"; else bad "ui pages: '$bad_page' not refused as BAD_PAGE"; fi
done
run "ui pages: the same page twice → BLOCKED" 2 "${UIP[@]}" --page orders --page orders
if says "BAD_PAGE" && says "orders"; then ok "  ...named as a duplicate"; else bad "ui pages: duplicate not named"; fi
run "ui pages: the same page with and without :dialog → BLOCKED" 2 "${UIP[@]}" --page orders --page orders:dialog
# --skip ui:<reason> skips the whole gate and wins over --page: the manifest carries no scope
run "ui pages: --skip ui:<reason> with --page → the skip wins" 0 "${UIP[@]}" --page orders --page nowhere --skip "ui:no UI in this change"
if q "not g['ui']['required'] and g['ui']['status'] == 'NOT_RUN' and g['ui']['notApplicableReason'] == 'no UI in this change' and 'scope' not in g['ui'] and 'results' not in g['ui']" && says "--page ignored"; then
  ok "  ...recorded not required, no scope, and the ignored --page is said"; else bad "ui pages: skip + --page"; fi
# an app that does not opt in to uiGate: --page changes nothing
config '{ "appId": 100, "appAlias": "hr", "apexlangDir": "src", "sqlclConnection": "dev", "securityGate": true }'
good hr 100
run "ui pages: uiGate not set, --page given → the gate stays not required" 0 "${UIP[@]}" --page orders
if q "not g['ui']['required'] and 'uiGate' in g['ui']['notApplicableReason']" && says "--page ignored"; then ok "  ...and --page is said to be ignored"; else bad "ui pages: --page with no uiGate"; fi
# environments and apps[]: the pages are read as the identity of the app they belong to — no false UNKNOWN
config '{ "appId": 100, "appAlias": "hr", "apexlangDir": "src", "securityGate": true, "uiGate": true, "environments": { "dev": { "sqlclConnection": "dev", "appId": 100 }, "prod": { "sqlclConnection": "prod", "appId": 101 } } }'
good hr 101 prod
run "ui pages: --env prod (appId 101 per environment), --page orders → PASS" 0 --task T-1 --app hr --env prod --page orders
config '{ "apexlangDir": "src", "securityGate": true, "uiGate": true, "apps": [ { "appId": 100, "appAlias": "hr", "sqlclConnection": "dev_hr" }, { "appId": 200, "appAlias": "fin", "sqlclConnection": "dev_fin" } ] }'
good fin 200
run "ui pages: apps[], --app fin --page orders → PASS" 0 --task T-1 --app fin --page orders

# --- F-07: record-sync before Runtime (GATES.md §The orchestration contract). Runtime cites sync-<key>-record-sync.json as
# its second result and is NOT_RUN without it, with another operation, or when its own verdict predates record-sync's.
# The Sync gate is unchanged: check-import alone authorizes the import, so asking record-sync of it would be circular.
# Every timestamp below is set on purpose (RS = record-sync, RT = the walkthrough, a little later).
config '{ "appId": 100, "appAlias": "hr", "apexlangDir": "src", "sqlclConnection": "dev" }'
good hr 100
HRT=(--task T-1 --app hr)
RSF="$T/sync-hr-record-sync.json"; RTF="$T/runtime-hr.json"
tsof() { "$PY" -c "import json,sys; print(json.load(open(sys.argv[1]))['context']['timestamp'])" "$1"; }
run "order control: record-sync at $RS, runtime at $RT → PASS" 0 "${HRT[@]}"
if q "g['runtime']['status'] == 'PASS' and len(g['runtime']['results']) == 2 and len(g['sync']['results']) == 1" && [[ $(tsof "$RSF") == "$RS" && $(tsof "$RTF") == "$RT" ]]; then
  ok "  ...both timestamps explicit, Runtime cites two results, Sync one"; else bad "order control: fixtures not as intended"; fi
# a Runtime result from long before any import (the audit's repro: 2020) is no longer a PASS
stampm runtime-result/editable-ig-pass runtime-hr.json "d['context']['timestamp'] = '2020-01-01T00:00:00Z'"
run "a runtime verdict from 2020, record-sync at $RS → NOT_RUN" 4 "${HRT[@]}"
if q "g['runtime']['status'] == 'NOT_RUN' and d['status'] == 'NOT_RUN'" && says "runtime-hr.json: stale — its verdict (2020-01-01T00:00:00Z) predates record-sync ($RS)"; then
  ok "  ...stale, naming both times"; else bad "2020 runtime: wrong verdict or note"; fi
# said once, on the runtime; the record-sync is not marked stale
if [[ $(grep -o 'predates' "$WORK/err.txt" | wc -l) -eq 1 ]] && ! says "sync-hr-record-sync.json: stale" && q "len(g['runtime']['results']) == 2"; then
  ok "  ...'predates' said once; only the runtime is stale, record-sync is still cited"; else bad "2020 runtime: duplicated or misplaced note"; fi
# the boundary is the second: equal passes, one second earlier does not
stampm runtime-result/editable-ig-pass runtime-hr.json "d['context']['timestamp'] = '$RS'"
run "boundary: runtime verdict in the same second as record-sync → PASS" 0 "${HRT[@]}"
stampm runtime-result/editable-ig-pass runtime-hr.json "d['context']['timestamp'] = '2026-11-04T09:59:59Z'"
run "boundary: runtime verdict one second before record-sync → NOT_RUN" 4 "${HRT[@]}"
if says "predates record-sync"; then ok "  ...predates"; else bad "boundary: not named"; fi
# a record-sync run again after the walkthrough was written moves the order: the earlier runtime is invalid
stamp runtime-result/editable-ig-pass runtime-hr.json
stamp sync-result/record-sync-pass sync-hr-record-sync.json T-1 2026-11-04T10:05:01Z
run "record-sync re-run after the runtime verdict (RT + 1 s) → NOT_RUN" 4 "${HRT[@]}"
if says "runtime-hr.json: stale — its verdict ($RT) predates record-sync (2026-11-04T10:05:01Z)"; then ok "  ...the runtime is run again after the import"; else bad "re-run record-sync: note"; fi
stamp sync-result/record-sync-pass sync-hr-record-sync.json
# a timestamp that cannot be read is UNKNOWN, never a pass by string order
for bad_ts in "2026-13-45T25:61:61Z" "9999-99-99T99:99:99Z"; do
  stampm runtime-result/editable-ig-pass runtime-hr.json "d['context']['timestamp'] = '$bad_ts'"
  run "unreadable runtime timestamp ($bad_ts) → UNKNOWN" 3 "${HRT[@]}"
  if q "g['runtime']['status'] == 'UNKNOWN'" && says "runtime-hr.json" && says "cannot be ordered"; then ok "  ...UNKNOWN, named"; else bad "runtime timestamp $bad_ts"; fi
done
stampm runtime-result/editable-ig-pass runtime-hr.json "d['context'].pop('timestamp')"
run "no runtime timestamp → UNKNOWN (the schema rejects it first)" 3 "${HRT[@]}"
if q "g['runtime']['status'] == 'UNKNOWN'" && says "runtime-hr.json: invalid"; then ok "  ...invalid, named"; else bad "no runtime timestamp"; fi
stamp runtime-result/editable-ig-pass runtime-hr.json
stampm sync-result/record-sync-pass sync-hr-record-sync.json "d['context']['timestamp'] = '2026-02-30T10:00:00Z'"
run "unreadable record-sync timestamp (a 30th of February) → UNKNOWN" 3 "${HRT[@]}"
if q "g['runtime']['status'] == 'UNKNOWN'" && says "sync-hr-record-sync.json" && says "cannot be ordered"; then ok "  ...UNKNOWN, named"; else bad "record-sync timestamp"; fi
stampm sync-result/record-sync-pass sync-hr-record-sync.json "d['context'].pop('timestamp')"
run "no record-sync timestamp → UNKNOWN" 3 "${HRT[@]}"
stamp sync-result/record-sync-pass sync-hr-record-sync.json

# record-sync absent
mv "$RSF" "$WORK/rs.keep"
run "record-sync missing, runtime PASS → NOT_RUN (the Runtime gate), not PASS" 4 "${HRT[@]}"
if q "g['runtime']['status'] == 'NOT_RUN' and g['sync']['status'] == 'PASS' and d['status'] == 'NOT_RUN' and len(g['runtime']['results']) == 1" \
  && says "sync-hr-record-sync.json: not in the task" && says "next — run the runtime gate" && says "apex-sync-check.sh record-sync"; then
  ok "  ...Sync stays PASS, the runtime gate says to import and record-sync, one result cited"; else bad "record-sync missing: wrong gates or hint"; fi
# --exit runtime:N speaks for runtime-<key>.json only: the missing record-sync is not read as that command's missing result
run "--exit runtime:0, record-sync missing → NOT_RUN, not UNKNOWN in the wrong place" 4 "${HRT[@]}" --exit runtime:0
if q "g['runtime']['status'] == 'NOT_RUN'" && says "sync-hr-record-sync.json: not in the task" && ! says "ran (exit 0) but sync-hr-record-sync"; then
  ok "  ...the exit is not attributed to record-sync"; else bad "--exit runtime:0 without record-sync"; fi
run "--exit runtime:1, record-sync missing, runtime PASS → UNKNOWN, the contrast against runtime-hr.json alone" 3 "${HRT[@]}" --exit runtime:1
if says "runtime-hr.json: PASS, but its command exited 1" && ! says "ran (exit 1) but sync-hr-record-sync"; then
  ok "  ...named on the runtime result only"; else bad "--exit runtime:1 contrast"; fi
mv "$RTF" "$WORK/rt.keep"
run "--exit runtime:2, neither result there → BLOCKED, on runtime-hr.json only" 2 "${HRT[@]}" --exit runtime:2
if says "ran (exit 2) but runtime-hr.json: not in the task" && ! says "ran (exit 2) but sync-hr-record-sync" && q "g['runtime']['status'] == 'BLOCKED'"; then
  ok "  ...BLOCKED"; else bad "--exit runtime:2, neither result"; fi
# check-import PASS alone: the state that authorizes the import. Sync PASS, Runtime NOT_RUN, and the hint is not circular
run "check-import alone → Sync PASS, Runtime NOT_RUN (nothing circular)" 4 "${HRT[@]}"
if q "g['sync']['status'] == 'PASS' and g['runtime']['status'] == 'NOT_RUN' and 'results' not in g['runtime']" \
  && says "next — run the runtime gate" && ! says "next — run the sync gate" && says "import (only on the Sync PASS)" && says "record-sync"; then
  ok "  ...next is the runtime gate: import on the Sync PASS, then record-sync"; else bad "check-import alone: wrong next step"; fi
# a task with no import: skip Runtime with the reason...
run "--skip runtime:<reason>, no record-sync, no runtime (a change with no import) → PASS" 0 "${HRT[@]}" --skip "runtime:package-only change, nothing imported"
if q "not g['runtime']['required'] and g['runtime']['excludedBy'] == 'skip' and 'results' not in g['runtime'] and d['status'] == 'PASS'"; then
  ok "  ...Runtime recorded not required, with its reason"; else bad "--skip runtime"; fi
mv "$WORK/rs.keep" "$RSF"; mv "$WORK/rt.keep" "$RTF"
# ...or a no-op record-sync (basis builder-unchanged) and a runtime after it
stampm sync-result/record-sync-pass sync-hr-record-sync.json "d['basis'] = 'builder-unchanged'"
run "a no-op record-sync (basis builder-unchanged) before the runtime → PASS" 0 "${HRT[@]}"
# a forced record-sync is the user's call (P9): it does not block, and it is said
stampm sync-result/record-sync-pass sync-hr-record-sync.json "d['basis'] = 'forced'"
run "record-sync with basis forced → PASS (not judged)" 0 "${HRT[@]}"
if says "basis forced" && q "g['runtime']['status'] == 'PASS'"; then ok "  ...and the note says it was forced"; else bad "forced: not noted"; fi
stamp sync-result/record-sync-pass sync-hr-record-sync.json
# a record-sync that did not PASS keeps its own severity in the Runtime gate
stampm sync-result/record-sync-pass sync-hr-record-sync.json "d['status'] = 'BLOCKED'; d['reasons'] = [{'code': 'NO_FRESH_CHECK', 'message': 'no check-import PASS in the last 5 minutes'}]; d['syncpoint']['recorded'] = False; d.pop('basis'); d['evidence'] = []"
run "record-sync BLOCKED (NO_FRESH_CHECK) → the Runtime gate is BLOCKED (exit 2)" 2 "${HRT[@]}"
if q "g['runtime']['status'] == 'BLOCKED' and g['sync']['status'] == 'PASS'" && says "stop — the runtime gate is BLOCKED"; then ok "  ...stop at runtime, Sync untouched"; else bad "record-sync BLOCKED"; fi
stamp sync-result/record-sync-pass sync-hr-record-sync.json
# a record-sync that is not this destination's, or not fresh
neg "record-sync file holding a check-import (another operation)" sync-hr-record-sync.json sync-result/check-import-pass pass "${HRT[@]}"
neg "record-sync of another app" sync-hr-record-sync.json sync-result/record-sync-pass "$(who fin 200)" "${HRT[@]}"
neg "record-sync of another environment on an app without any" sync-hr-record-sync.json sync-result/record-sync-pass "$(who hr 100 prod)" "${HRT[@]}"
stamp sync-result/record-sync-pass sync-hr-record-sync.json T-0
run "record-sync made for another task → NOT_RUN (stale)" 4 "${HRT[@]}"
if says "sync-hr-record-sync.json: stale — made for task T-0"; then ok "  ...stale, naming the task"; else bad "record-sync of another task"; fi
stampm sync-result/record-sync-pass sync-hr-record-sync.json "d['context']['repo']['tree'] = 'f' * len(d['context']['repo']['tree'])"
run "record-sync of another working tree → NOT_RUN (stale)" 4 "${HRT[@]}"
if says "sync-hr-record-sync.json: stale — the working tree changed since" && q "g['runtime']['status'] == 'NOT_RUN'"; then ok "  ...stale, tree"; else bad "record-sync of another tree"; fi
stamp sync-result/record-sync-pass sync-hr-record-sync.json
run "control: the record-sync restored → PASS" 0 "${HRT[@]}"
# the Sync gate does not read record-sync: a stale or absent one changes nothing there
stamp sync-result/record-sync-pass sync-hr-record-sync.json T-0
run "--exit sync:0 with a stale record-sync → NOT_RUN in Runtime only" 4 "${HRT[@]}" --exit sync:0
if q "g['sync']['status'] == 'PASS' and g['runtime']['status'] == 'NOT_RUN'"; then ok "  ...Sync is check-import's alone"; else bad "Sync read record-sync"; fi
stamp sync-result/record-sync-pass sync-hr-record-sync.json

# an app with environments: sync-<alias>.<env>-record-sync.json
config '{ "appId": 100, "appAlias": "hr", "apexlangDir": "src", "environments": { "dev": { "sqlclConnection": "dev" } } }'
good hr 100 dev
DEV=(--task T-1 --app hr --env dev)
run "--env dev: record-sync and runtime of dev → PASS" 0 "${DEV[@]}"
if q "[r['path'].rsplit('/', 1)[1] for r in g['runtime']['results']] == ['runtime-hr.dev.json', 'sync-hr.dev-record-sync.json']"; then ok "  ...cited as sync-hr.dev-record-sync.json"; else bad "--env: record-sync not cited"; fi
neg "dev's record-sync read for the wrong environment (prod)" sync-hr.dev-record-sync.json sync-result/record-sync-pass "$(who hr 100 prod)" "${DEV[@]}"
neg "dev's record-sync with no environment" sync-hr.dev-record-sync.json sync-result/record-sync-pass "$(who hr 100)" "${DEV[@]}"
mv "$T/sync-hr.dev-record-sync.json" "$WORK/rs.keep"
run "--env dev, record-sync missing → NOT_RUN" 4 "${DEV[@]}"
if says "sync-hr.dev-record-sync.json: not in the task" && q "g['runtime']['status'] == 'NOT_RUN'"; then ok "  ...naming the env file"; else bad "--env: record-sync missing not named"; fi
mv "$WORK/rs.keep" "$T/sync-hr.dev-record-sync.json"
stampm runtime-result/editable-ig-pass runtime-hr.dev.json "$(who hr 100 dev)"$'\n'"d['context']['timestamp'] = '2026-11-04T09:00:00Z'"
run "--env dev, runtime verdict before dev's record-sync → NOT_RUN" 4 "${DEV[@]}"
if says "runtime-hr.dev.json: stale — its verdict (2026-11-04T09:00:00Z) predates record-sync ($RS)"; then ok "  ...stale"; else bad "--env: order"; fi

# --- the Package gate: opt-in (packageGate), between Validation and Sync (GATES.md §The Package gate). It reads
# package-<key>.json for exactly this destination (alias, environment, appId) — a package-result of another app or
# environment is NOT_RUN "misfiled", like every gate with a producer. Each case is a manifest delivery.py wrote.
config '{ "appId": 100, "appAlias": "hr", "apexlangDir": "src", "sqlclConnection": "dev" }'
good hr 100
run "package: packageGate unset → not required, with its reason; every other gate PASS → PASS" 0 --task T-1 --app hr
if q "not g['package']['required'] and g['package']['status'] == 'NOT_RUN' and g['package']['excludedBy'] == 'config' and 'packageGate' in g['package']['notApplicableReason'] and 'results' not in g['package']"; then
  ok "  ...the gate is listed (never omitted), not required, excludedBy config, no result read"; else bad "package: unset gate wrong"; fi
if q "[x['gate'] for x in d['gates']] == ['architecture', 'validation', 'package', 'sync', 'runtime', 'security', 'ui']"; then
  ok "  ...and it sits between validation and sync in the manifest"; else bad "package: order in the manifest"; fi
if says "not evaluated: package (config), security (config), ui (config) - not a statement about them"; then
  ok "  ...stderr names it with the other opt-in gates"; else bad "package: 'not evaluated' line"; fi
# an unset gate hides a package FAIL on purpose (opt-in): the exclusion is said, not the verdict
stampm package-result/fail package-hr.json "d['app']['appAlias'] = 'hr'"
run "package: packageGate unset, a FAIL result in the task → still not read (PASS, not evaluated)" 0 --task T-1 --app hr
if q "g['package']['status'] == 'NOT_RUN' and 'results' not in g['package']" && says "not evaluated: package (config)"; then
  ok "  ...the unset gate does not read the file"; else bad "package: unset gate read a result"; fi
stampm package-result/pass package-hr.json

config '{ "appId": 100, "appAlias": "hr", "apexlangDir": "src", "sqlclConnection": "dev", "packageGate": true }'
good hr 100
PK=(--task T-1 --app hr)
run "package: packageGate set, a package-result PASS → PASS" 0 "${PK[@]}"
if q "g['package']['required'] and g['package']['status'] == 'PASS' and 'excludedBy' not in g['package'] and [r['kind'] for r in g['package']['results']] == ['package-result'] and g['package']['results'][0]['path'].endswith('package-hr.json') and len(g['package']['results'][0]['sha256']) == 64"; then
  ok "  ...cited by kind, path and sha256, no excludedBy"; else bad "package: PASS not cited"; fi
if says "every required gate PASSes" && says "not evaluated: security (config), ui (config) - not a statement about them" && ! says "package (config)"; then
  ok "  ...Package is evaluated: only Security and UI are named as not evaluated"; else bad "package: required gate named as not evaluated"; fi
# required and not run: NOT_RUN, never PASS, and the next step names the producer
mv "$T/package-hr.json" "$WORK/pk.keep"
run "package: required, no result → NOT_RUN (never PASS)" 4 "${PK[@]}"
if q "g['package']['status'] == 'NOT_RUN' and g['package']['required'] and d['status'] == 'NOT_RUN'" && says "package-hr.json: not in the task" \
  && says "next — run the package gate" && says "pkg-check.py --app hr --task T-1"; then
  ok "  ...next names pkg-check.py with the app and the task"; else bad "package: not-run next step"; fi
if says "pkg-check.py" && ! says "SQL source" && says "\.apx"; then ok "  ...and says it reads .apx files"; else bad "package: hint text"; fi
# the order: a later gate's PASS does not move the next step past Package
if ! says "next — run the sync gate" && q "g['sync']['status'] == 'PASS' and g['validation']['status'] == 'PASS'"; then
  ok "  ...sync and validation PASS, yet the next step is Package, not Sync"; else bad "package: order of the next step"; fi
run "package: required, no result, pkg-check.py exited 2 → BLOCKED, on the gate" 2 "${PK[@]}" --exit package:2
if q "g['package']['status'] == 'BLOCKED'" && says "ran (exit 2) but package-hr.json: not in the task" && says "stop — the package gate is BLOCKED"; then
  ok "  ...BLOCKED, and the stop names it"; else bad "package: --exit 2"; fi
run "package: required, no result, it exited 3 → UNKNOWN" 3 "${PK[@]}" --exit package:3
run "package: required, no result, it exited 1 → UNKNOWN (never FAIL, never PASS)" 3 "${PK[@]}" --exit package:1
run "package: --exit package:x → BLOCKED (BAD_EXIT)" 2 "${PK[@]}" --exit package
run "package: --skip package:<reason> → not required, excludedBy skip, recorded" 0 "${PK[@]}" --skip "package:a change with no page, nothing for the gate to look up"
if q "not g['package']['required'] and g['package']['excludedBy'] == 'skip' and g['package']['notApplicableReason'].startswith('a change with no page') and 'results' not in g['package']" \
  && says "not evaluated: package (skip), security (config), ui (config)"; then
  ok "  ...the reason and excludedBy skip are recorded, and the line says so"; else bad "package: skip not recorded"; fi
mv "$WORK/pk.keep" "$T/package-hr.json"
# the producer's verdicts
stampm package-result/fail package-hr.json
run "package: a package-result FAIL → FAIL, and stop there" 1 "${PK[@]}"
if q "g['package']['status'] == 'FAIL' and d['status'] == 'FAIL' and g['sync']['status'] == 'PASS'" && says "stop — the package gate is FAIL"; then
  ok "  ...stop at package, later gates still read"; else bad "package: FAIL"; fi
stampm package-result/unknown package-hr.json
run "package: a package-result UNKNOWN → UNKNOWN (authorizes nothing)" 3 "${PK[@]}"
if q "g['package']['status'] == 'UNKNOWN' and d['status'] == 'UNKNOWN'" && says "stop — the package gate is UNKNOWN"; then ok "  ...stop at package"; else bad "package: UNKNOWN"; fi
stampm package-result/pass package-hr.json "d['status'] = 'BLOCKED'; d['reasons'] = [{'code': 'NO_PAIRS', 'message': 'no package.procedure to look up'}]
d['criteria'] = [{'id': c['id'], 'status': 'NOT_RUN', 'findings': [], 'notApplicableReason': 'nothing was looked up'} for c in d['criteria']]
d['files'] = []; d['evidence'] = []; d.pop('database', None)"
run "package: a package-result BLOCKED → BLOCKED (exit 2)" 2 "${PK[@]}"
if q "g['package']['status'] == 'BLOCKED' and d['status'] == 'BLOCKED'" && says "stop — the package gate is BLOCKED"; then ok "  ...stop at package"; else bad "package: BLOCKED"; fi
stampm package-result/pass package-hr.json
# a result that disagrees with its own criteria is invalid, never read; one made for another task or tree is stale
"$PY" - "$T/package-hr.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["criteria"][1] = {"id": "PKG-COMPILED", "status": "UNKNOWN", "findings": [{"package": "PKG_X", "detail": "INVALID"}]}   # a PASS over an UNKNOWN criterion
json.dump(d, open(sys.argv[1], "w"))
PY
run "package: a PASS over an UNKNOWN criterion → UNKNOWN (invalid, never read)" 3 "${PK[@]}"
if says "package-hr.json: invalid" && q "g['package']['status'] == 'UNKNOWN'"; then ok "  ...invalid, named"; else bad "package: invalid not named"; fi
printf '{ not json' > "$T/package-hr.json"
run "package: an unreadable result → UNKNOWN" 3 "${PK[@]}"
stampm package-result/pass package-hr.json "d['context']['task'] = 'T-0'"
run "package: a result made for another task → NOT_RUN (stale)" 4 "${PK[@]}"
if says "package-hr.json: stale — made for task T-0"; then ok "  ...stale, naming the task"; else bad "package: stale not named"; fi
stampm package-result/pass package-hr.json "d['context']['repo']['tree'] = 'f' * len(d['context']['repo']['tree'])"
run "package: a result of another working tree → NOT_RUN (stale)" 4 "${PK[@]}"
if says "package-hr.json: stale — the working tree changed since"; then ok "  ...stale, tree"; else bad "package: other tree"; fi
stampm package-result/pass package-hr.json
run "package: control — the PASS restored → PASS" 0 "${PK[@]}"
# identity (C2's table): another app, another appId, another environment, or none at all → NOT_RUN "misfiled"
neg "package-result of another app (fin, id 200)" package-hr.json package-result/pass "$(who fin 200)" "${PK[@]}"
neg "package-result of hr with another appId" package-hr.json package-result/pass "$(who hr 999)" "${PK[@]}"
neg "package-result whose app names no alias" package-hr.json package-result/pass "d['app'] = {'appId': 100}" "${PK[@]}"
stampm package-result/pass package-hr.json "d.pop('app')"
run "package: a PASS with no app at all → UNKNOWN (the schema needs the app of a verdict)" 3 "${PK[@]}"
stampm package-result/pass package-hr.json
neg "package-result of an app without environments that says prod" package-hr.json package-result/pass "$(who hr 100 prod)" "${PK[@]}"
neg "package-result for the alias in another case (HR for hr)" package-hr.json package-result/pass "$(who HR 100)" "${PK[@]}"
# a result of another gate's kind in the file name package-<key>.json is invalid (its schema is another's): UNKNOWN, not PASS
stampm sync-result/check-import-pass package-hr.json pass
run "package: a sync-result saved as package-hr.json → UNKNOWN (invalid as a package-result)" 3 "${PK[@]}"
# a --exit that disagrees with the result
stampm package-result/pass package-hr.json
run "package: a PASS whose command exited 1 → UNKNOWN" 3 "${PK[@]}" --exit package:1
if says "package-hr.json: PASS, but its command exited 1"; then ok "  ...the disagreement is named"; else bad "package: exit contrast"; fi
run "package: a PASS whose command exited 0 → PASS" 0 "${PK[@]}" --exit package:0
# the manifest Package cites validates as a package gate PASS (the contract tier captures it too)
# apps with environments: package-<alias>.<env>.json
config '{ "appId": 100, "appAlias": "hr", "apexlangDir": "src", "packageGate": true, "environments": { "dev": { "sqlclConnection": "dev" }, "prod": { "sqlclConnection": "prod", "appId": 101, "protected": true } } }'
good hr 100 dev
PKD=(--task T-1 --app hr --env dev)
run "package: --env dev reads package-hr.dev.json → PASS" 0 "${PKD[@]}"
if q "g['package']['results'][0]['path'].endswith('package-hr.dev.json')"; then ok "  ...cited as package-hr.dev.json"; else bad "package: env key"; fi
neg "package-result of prod read for dev" package-hr.dev.json package-result/pass "$(who hr 100 prod)" "${PKD[@]}"
neg "package-result with no environment under --env dev" package-hr.dev.json package-result/pass "$(who hr 100)" "${PKD[@]}"
good hr 101 prod
PKP=(--task T-1 --app hr --env prod)
run "package: --env prod (appId 101, protected) reads prod's own result → PASS" 0 "${PKP[@]}"
neg "package-result of dev read for prod" package-hr.prod.json package-result/pass "$(who hr 101 dev)" "${PKP[@]}"
neg "package-result of prod carrying dev's appId (100, not 101)" package-hr.prod.json package-result/pass "$(who hr 100 prod)" "${PKP[@]}"
# the default of the top level, and an app's own value over it (apps[])
config '{ "apexlangDir": "src", "packageGate": true, "apps": [ { "appId": 100, "appAlias": "hr", "sqlclConnection": "dev_hr" }, { "appId": 200, "appAlias": "fin", "sqlclConnection": "dev_fin", "packageGate": false } ] }'
good hr 100
run "package: apps[] — the top-level packageGate:true applies to hr" 0 --task T-1 --app hr
if q "g['package']['required']"; then ok "  ...hr: required (inherited)"; else bad "package: top-level default"; fi
good fin 200
run "package: apps[] — fin's own packageGate:false overrides the default" 0 --task T-1 --app fin
if q "not g['package']['required'] and g['package']['excludedBy'] == 'config'"; then ok "  ...fin: not required"; else bad "package: per-app override"; fi

# --- no apex-sync.json (F-03): the exit stays 4 and ONE additive stderr note says why Sync, Validation and Runtime cannot PASS.
# A sentinel sql and npx on PATH record any call: delivery.py reads files and runs neither. With a valid config the note is absent.
NC="$WORK/noconf"; mkdir -p "$NC" "$WORK/sentinel"; git -C "$NC" init -q
# shellcheck disable=SC2016  # the sentinel's own $0 and $* are meant literally: they expand when IT runs
for t in sql npx; do printf '#!/usr/bin/env bash\necho "$0 $*" >> "%s/called"\n' "$WORK/sentinel" > "$WORK/sentinel/$t"; chmod +x "$WORK/sentinel/$t"; done
NOTE="apex-sync.json not found: Sync, Validation and Runtime cannot PASS; run apex-sync-check.sh apps"
rc=0; ( cd "$NC" && PATH="$WORK/sentinel:$PATH" "$PY" "$DLV" --task T-1 --app hr ) > "$WORK/out.json" 2> "$WORK/err.txt" || rc=$?
if [[ $rc -eq 4 ]] && says "$NOTE" && q "d['status'] == 'NOT_RUN'"; then ok "no apex-sync.json, --app given → exit 4 unchanged (NOT_RUN) with the stderr note"
else bad "no apex-sync.json: exit $rc, expected 4 with the note"; fi
if [[ $(grep -c "apex-sync.json not found" "$WORK/err.txt") -eq 1 ]]; then ok "  ...the note is printed once"; else bad "no apex-sync.json: the note is not exactly one line"; fi
if [[ ! -e "$WORK/sentinel/called" ]]; then ok "  ...no sql or npx was invoked"; else bad "no apex-sync.json: a stub ran: $(cat "$WORK/sentinel/called")"; fi
rc=0; ( cd "$NC" && "$PY" "$DLV" --task T-1 ) > "$WORK/out.json" 2> "$WORK/err.txt" || rc=$?
if [[ $rc -eq 2 ]] && says "APP_REQUIRED" && ! says "$NOTE"; then ok "no apex-sync.json and no --app → still BLOCKED (APP_REQUIRED), no note"; else bad "no config, no --app: exit $rc, expected 2 APP_REQUIRED"; fi
rc=0; ( cd "$P" && PATH="$WORK/sentinel:$PATH" "$PY" "$DLV" --task T-1 --app hr ) > "$WORK/out.json" 2> "$WORK/err.txt" || rc=$?
if ! says "apex-sync.json not found" && [[ ! -e "$WORK/sentinel/called" ]]; then ok "with a valid apex-sync.json the note does not appear (and no stub ran)"; else bad "valid config: the note appeared or a stub ran"; fi

# --- the core as a user may have installed it: a copy of the skill and lib/ (schemas/ only where a case says so)
CORE="$WORK/core"; mkdir -p "$CORE/skills" "$CORE/framework"
cp -r "$REPO/skills/apexlang-delivery" "$CORE/skills/"
cp -r "$REPO/framework/lib" "$CORE/framework/"
config '{ "appId": 100, "appAlias": "hr", "apexlangDir": "src", "sqlclConnection": "dev" }'
core_run() { rc=0; "$PY" "$CORE/skills/apexlang-delivery/scripts/delivery.py" --task T-1 --app hr > "$WORK/out.json" 2> "$WORK/err.txt" || rc=$?; }

# no jsonschema: BLOCKED (NO_JSONSCHEMA), exit 2, naming the fix, no manifest. The stub sits next to the copied
# delivery.py — Python puts the script's directory first on sys.path, so `import jsonschema` finds it and raises
# ImportError; no environment variable, so no path conversion to trust on Git Bash.
cp -r "$REPO/framework/schemas" "$CORE/framework/"           # the schemas are there: only jsonschema is missing
printf 'raise ImportError("jsonschema stubbed out by tests/integration/delivery.sh")\n' > "$CORE/skills/apexlang-delivery/scripts/jsonschema.py"
rm -f "$T/manifest.json"
core_run
if [[ $rc -eq 2 ]] && says "NO_JSONSCHEMA" && says "pip install jsonschema" && says "apt install python3-jsonschema" && [[ ! -s "$WORK/out.json" && ! -f "$T/manifest.json" ]]; then
  ok "no jsonschema → BLOCKED (exit 2, NO_JSONSCHEMA) naming the fix, and no manifest"; else bad "no jsonschema: exit $rc, expected 2 with NO_JSONSCHEMA, the fix and no manifest"; fi
# without the schemas too it is the same stop: jsonschema is the first prerequisite
rm -rf "$CORE/framework/schemas"
core_run
if [[ $rc -eq 2 ]] && says "NO_JSONSCHEMA"; then ok "no jsonschema and no schemas → BLOCKED (NO_JSONSCHEMA), never a weaker check"; else bad "no jsonschema, no schemas: exit $rc, expected 2 with NO_JSONSCHEMA"; fi

# the core without its schemas, jsonschema installed: BLOCKS (NO_SCHEMAS); it never crashes
rm -f "$CORE/skills/apexlang-delivery/scripts/jsonschema.py"   # no framework/schemas/ in this copy
core_run
if [[ $rc -eq 2 ]] && says "NO_SCHEMAS"; then ok "no schemas with jsonschema → BLOCKED (exit 2), not a crash"; else bad "no schemas: exit $rc, expected 2 with NO_SCHEMAS"; fi

echo "delivery: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
