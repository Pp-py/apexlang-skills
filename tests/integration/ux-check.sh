#!/usr/bin/env bash
# apex-ux's runtime checks (skills/apex-ux/scripts/ux-check.py), offline: the real pw.sh
# runs against a stubbed Playwright CLI that hands back a canned browser verdict
# (fixtures/ux-check/*.json), so the mapping to criteria, the exit codes and the
# redaction are pinned without a browser —
#   * a verdict maps to UX-AXE-SERIOUS / UX-ITEM-NAME / UX-CONTROL-NAME / UX-DIALOG-FOCUS,
#     minor and "incomplete" only to advisories, no --dialog to NOT_RUN;
#   * axe-core is verified against its lock before anything runs (BLOCKED otherwise);
#   * a dead session (pw.sh exit 3) or output with no verdict is UNKNOWN, never PASS;
#   * stdout never carries a node's HTML or a session id; --raw keeps both, with its sha256;
#   * --task writes the ui-result and the raw output into the evidence dir;
#   * the snippet the CLI receives carries the pinned axe, and is deleted afterwards.
# The real-browser smoke (fixtures/ux-check/page.html, a live app) is manual: tests/README.md.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
CHECK="$REPO/skills/apex-ux/scripts/ux-check.py"
FIX="$REPO/tests/integration/fixtures/ux-check"
PY=$(command -v python3 || command -v python || true)
[[ -n "$PY" ]] || { echo "ux-check: BLOCKED — python3 is required" >&2; exit 2; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/ux-check-XXXXXX")
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/ws" "$WORK/tmp"

cat > "$WORK/bin/playwright-cli" <<'EOF'
#!/usr/bin/env bash
case " $* " in *" --version "*) echo "1.0.0"; exit 0 ;; esac
prev=""
for a in "$@"; do
  [[ "$a" == "list" ]] && { cat "$PW_STATE"; exit 0; }
  [[ "$prev" == "--filename" ]] && cat "$a" > "$PW_SNIP_LOG"
  prev=$a
done
case " $* " in *" run-code "*) cat "$PW_FAKE_OUT"; exit "${PW_FAKE_RC:-0}" ;; esac
exit 0
EOF
chmod +x "$WORK/bin/playwright-cli"

OPEN='{"browsers":[{"name":"apex","workspace":"/x","status":"open"}]}'
SHUT='{"browsers":[]}'
export PATH="$WORK/bin:$PATH" PW_STATE="$WORK/state.json" PW_WORKSPACE="$WORK/ws" \
       PW_SNIP_LOG="$WORK/snippet.js" TMPDIR="$WORK/tmp" TMP="$WORK/tmp" TEMP="$WORK/tmp"
echo "$OPEN" > "$PW_STATE"

pass=0; fail=0
ok()  { echo "ok   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1"; fail=$((fail + 1)); [[ -s "$WORK/out.json" ]] && sed 's/^/       | /' "$WORK/out.json" | head -20; return 0; }

check() {  # $1 = label, $2 = fixture, $3 = expected exit, $4 = python assertion on d, rest = args
  local label=$1 fx=$2 want=$3 assert=$4 rc=0; shift 4
  PW_FAKE_OUT="$FIX/$fx.json" "$PY" "$CHECK" "$@" > "$WORK/out.json" 2>/dev/null || rc=$?
  if [[ $rc -ne $want ]]; then bad "$label: exit $rc, expected $want"; return 0; fi
  if [[ -n "$assert" ]] && ! "$PY" -c "import json,sys
d = json.load(open(sys.argv[1]))
c = {x['id']: x['status'] for x in d['criteria']}
adv = sorted({a['id'] for a in d['advisories']})
assert $assert, (c, adv, d['status'], d['reasons'])" "$WORK/out.json" 2>"$WORK/assert.err"; then
    bad "$label: $(tail -1 "$WORK/assert.err")"; return 0
  fi
  ok "$label (exit $rc)"
}

check "clean page, dialog holds focus → PASS" clean 0 \
  "d['status'] == 'PASS' and set(c.values()) == {'PASS'}" --dialog '#open'
check "the CLI's quoted string is the same verdict" clean-quoted 0 "d['status'] == 'PASS'" --dialog '#open'
check "no --dialog → UX-DIALOG-FOCUS NOT_RUN" clean 0 "c['UX-DIALOG-FOCUS'] == 'NOT_RUN'"
check "serious violation → UX-AXE-SERIOUS FAIL" serious 1 \
  "c['UX-AXE-SERIOUS'] == 'FAIL' and c['UX-ITEM-NAME'] == 'PASS'"
check "label at any impact → UX-ITEM-NAME FAIL" item-name 1 \
  "c['UX-ITEM-NAME'] == 'FAIL' and c['UX-AXE-SERIOUS'] == 'PASS' and adv == []"
check "minor + incomplete → advisories only, PASS" minor 0 \
  "d['status'] == 'PASS' and adv == ['UX-AXE-MINOR', 'UX-AXE-REVIEW']"
check "focus escapes the dialog → UX-DIALOG-FOCUS FAIL" dialog-bad 1 \
  "c['UX-DIALOG-FOCUS'] == 'FAIL' and d['criteria'][3]['findings'][0]['failed'] == ['tabStays', 'focusReturns']" --dialog '#open'
check "opener not found → BLOCKED, focus NOT_RUN" not-found 2 \
  "d['status'] == 'BLOCKED' and c['UX-DIALOG-FOCUS'] == 'NOT_RUN'" --dialog '#open'
check "login page → BLOCKED" not-logged-in 2 "d['status'] == 'BLOCKED'"
check "axe ran in no frame → UNKNOWN" no-runs 3 "d['status'] == 'UNKNOWN'"
check "no verdict in the output → UNKNOWN" garbage 3 "d['status'] == 'UNKNOWN'"

# pw.sh found the browser dead and reopened it: whatever ran measured a logged-out page.
echo "$SHUT" > "$PW_STATE"
check "dead session (pw.sh exit 3) → UNKNOWN" clean 3 "d['status'] == 'UNKNOWN'" --dialog '#open'
echo "$OPEN" > "$PW_STATE"

# Redaction: the fixtures carry a session id and a node's HTML with a name in it.
PW_FAKE_OUT="$FIX/item-name.json" "$PY" "$CHECK" --raw "$WORK/raw.json" > "$WORK/out.json" 2>/dev/null || true
if grep -q '1234567890\|PII-Maria' "$WORK/out.json"; then bad "stdout leaks a session id or node HTML"
else ok "stdout carries neither the session id nor node HTML"; fi
if grep -q 'PII-Maria' "$WORK/raw.json" && "$PY" -c "import json,sys
assert 'evidence' not in json.load(open(sys.argv[1]))" "$WORK/out.json"; then
  ok "--raw outside the repo keeps the full output, uncited"
else bad "--raw file missing, or cited from outside the repo"; fi

# --task: the result and the raw output land in the project's evidence dir, the raw
# one cited by its sha256; the dir is ignored by git from its first write.
P="$WORK/proj"; mkdir -p "$P"; git -C "$P" init -q
printf '{ "appId": 100, "appAlias": "demo", "evidenceDir": "ev" }\n' > "$P/apex-sync.json"
rc=0; (cd "$P" && PW_FAKE_OUT="$FIX/item-name.json" "$PY" "$CHECK" --task T-1 > "$WORK/out.json" 2>/dev/null) || rc=$?
if [[ $rc -eq 1 ]] && cmp -s "$WORK/out.json" "$P/ev/T-1/ui-demo-runtime-orders.json" \
   && [[ "$(cat "$P/ev/.gitignore")" == "*" ]] && "$PY" -c "import hashlib,json,sys
d = json.load(open(sys.argv[1])); e = d['evidence'][0]
assert d['app'] == {'appAlias': 'demo'} and d['context']['task'] == 'T-1', d
assert e['path'] == 'ev/T-1/raw/ui-demo/axe-orders.json', e
assert e['sha256'] == hashlib.sha256(open(sys.argv[2] + '/' + e['path'], 'rb').read()).hexdigest()
assert d['context']['target']['runtimeUrl'] == 'https://apex.example/ords/r/ws/app/orders', d['context']" \
  "$WORK/out.json" "$P"; then ok "--task writes ui-demo-runtime-orders.json and cites the raw output"
else bad "--task: exit $rc, or the result/raw output is not where it belongs"; fi
# pw.sh's refusal names local paths: passed on as <repo>/… and ~/…, never verbatim.
rc=0; (cd "$P" && HOME="$WORK" PW_WORKSPACE="$P/.pw" PW_FAKE_OUT="$FIX/clean.json" "$PY" "$CHECK" > "$WORK/out.json" 2>/dev/null) || rc=$?
if [[ $rc -eq 2 ]] && grep -q 'pw.sh refused' "$WORK/out.json" && ! grep -q "$WORK" "$WORK/out.json"; then
  ok "pw.sh refused → BLOCKED, its message without local paths"
else bad "pw.sh refused: exit $rc, or its message carries a local path"; fi
printf '{ "apps": [ { "appId": 1, "appAlias": "a" }, { "appId": 2, "appAlias": "b" } ] }\n' > "$P/apex-sync.json"
rc=0; (cd "$P" && PW_FAKE_OUT="$FIX/clean.json" "$PY" "$CHECK" --task T-1 >/dev/null 2>&1) || rc=$?
if [[ $rc -eq 2 ]]; then ok "--task with several apps and no --app → BLOCKED (exit 2)"
else bad "--task with several apps and no --app: exit $rc, expected 2"; fi

# The snippet: the pinned engine and the dialogs went in; nothing is left behind.
PW_FAKE_OUT="$FIX/clean.json" "$PY" "$CHECK" --dialog '#open' >/dev/null 2>&1 || true
if grep -q 'axe v4.13.0' "$PW_SNIP_LOG" && grep -q '"#open"' "$PW_SNIP_LOG"; then
  ok "the snippet carries the pinned axe-core and the dialog selectors"
else bad "the snippet lacks axe-core or the dialogs"; fi
if ls "$WORK/tmp"/ux-check-* >/dev/null 2>&1; then bad "a snippet was left in TMPDIR"
else ok "no snippet left behind"; fi

# The engine is verified before anything runs.
mkdir -p "$WORK/vendor/axe-core"
cp "$REPO/skills/apex-ux/vendor/axe-core.lock.json" "$WORK/vendor/"
printf '/* tampered */\n' > "$WORK/vendor/axe-core/axe.min.js"
UX_AXE_DIR="$WORK/vendor" check "axe-core not matching its lock → BLOCKED" clean 2 \
  "d['status'] == 'BLOCKED' and 'sha256' in d['reasons'][0]['message']"
UX_AXE_DIR="$WORK/nowhere" check "axe-core missing → BLOCKED" clean 2 "d['status'] == 'BLOCKED'"
if "$PY" -c "import hashlib,json,sys
lock = json.load(open(sys.argv[1] + '/axe-core.lock.json'))
assert hashlib.sha256(open(sys.argv[1] + '/' + lock['file'], 'rb').read()).hexdigest() == lock['sha256']" \
  "$REPO/skills/apex-ux/vendor"; then ok "the vendored axe-core matches its lock"
else bad "the vendored axe-core does not match its lock"; fi

echo "ux-check: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
