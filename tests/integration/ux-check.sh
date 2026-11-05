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
#   * the snippet the CLI receives carries the pinned axe, and is deleted afterwards;
#   * oracle-owned.json lists only OO-1: a page's own dialog failing focusReturns on 26.2 is FAIL,
#     the version compare is exact, and the `failed` branch is covered by a temporary list;
#   * the snippets in references/by-hand.md parse (when node is on PATH) and stay read-only.
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
  local label=$1 fx=$2 want=$3 assert=$4 rc=0 out; shift 4
  out="$FIX/$fx.json"; [[ "$fx" == /* ]] && out=$fx      # a fixture name, or a file the test wrote
  PW_FAKE_OUT="$out" "$PY" "$CHECK" "$@" > "$WORK/out.json" 2>/dev/null || rc=$?
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

# Markup APEX itself renders (oracle-owned.json): an advisory on the exact version an entry names,
# a FAIL on any other version, with any other target, or with another dialog step failing.
# Only OO-1 is listed. A dialog that loses focus on Esc is the page's own until a minimal
# reproduction with a negative control says otherwise (OO-2 was retired).
check "APEX 26.2's IG grid markup → UX-ORACLE-OWNED OO-1, PASS" oracle-owned 0 \
  "d['status'] == 'PASS' and sorted(a['detail'].split()[1] for a in d['advisories'] if a['id'] == 'UX-ORACLE-OWNED') == ['OO-1']" --dialog '#open'
sed 's/"apex": "26.2"/"apex": "26.3"/' "$FIX/oracle-owned.json" > "$WORK/oo-263.json"
sed 's/"apex": "26.2"/"apex": "26.2.0"/' "$FIX/oracle-owned.json" > "$WORK/oo-2620.json"
sed 's/#orders_ig_grid_vc/#orders_grid/' "$FIX/oracle-owned.json" > "$WORK/oo-target.json"
sed 's/"tabStays": true/"tabStays": false/' "$FIX/oracle-owned.json" > "$WORK/oo-steps.json"
sed 's/, "apex": "26.2"//' "$FIX/oracle-owned.json" > "$WORK/oo-none.json"
for v in 263:"another APEX version" 2620:"26.2.0 is not 26.2 (exact version)" target:"another target" steps:"another dialog step too" none:"no APEX version reported"; do
  check "oracle-owned, ${v#*:} → FAIL" "$WORK/oo-${v%%:*}.json" 1 "d['status'] == 'FAIL'" --dialog '#open'
done
# The retired OO-2: the page's own dialog failing only focusReturns on 26.2, against the REAL list.
check "own dialog on 26.2 failing only focusReturns → FAIL, no advisory" own-dialog 1 \
  "c['UX-DIALOG-FOCUS'] == 'FAIL' and 'UX-ORACLE-OWNED' not in adv and d['criteria'][3]['findings'][0]['failed'] == ['focusReturns']" --dialog '#my-own-dialog-opener'
sed 's/"apex": "26.2"/"apex": "26.2.0"/' "$FIX/own-dialog.json" > "$WORK/own-2620.json"
check "own dialog failing only focusReturns on 26.2.0 → FAIL" "$WORK/own-2620.json" 1 \
  "c['UX-DIALOG-FOCUS'] == 'FAIL' and 'UX-ORACLE-OWNED' not in adv" --dialog '#my-own-dialog-opener'
# The `failed` branch of owned_by_oracle, kept covered with a temporary list (UX_ORACLE_OWNED).
cat > "$WORK/owned-failed.json" <<'JSON'
{"about": "temporary list for the test", "entries": [
  {"id": "OO-T", "criterion": "UX-DIALOG-FOCUS", "failed": ["focusReturns"], "apex": "26.2", "note": "test entry", "source": "test"}]}
JSON
sed 's/"tabStays": true/"tabStays": false/' "$FIX/own-dialog.json" > "$WORK/own-steps.json"
sed 's/"apex": "26.2"/"apex": "26.3"/' "$FIX/own-dialog.json" > "$WORK/own-263.json"
UX_ORACLE_OWNED="$WORK/owned-failed.json" check "temporary list: the exact failed steps on the named version → UX-ORACLE-OWNED, PASS" own-dialog 0 \
  "d['status'] == 'PASS' and c['UX-DIALOG-FOCUS'] == 'PASS' and [a['detail'].split()[1] for a in d['advisories'] if a['id'] == 'UX-ORACLE-OWNED'] == ['OO-T']" --dialog '#my-own-dialog-opener'
UX_ORACLE_OWNED="$WORK/owned-failed.json" check "temporary list: another step fails too → FAIL" "$WORK/own-steps.json" 1 \
  "c['UX-DIALOG-FOCUS'] == 'FAIL' and 'UX-ORACLE-OWNED' not in adv" --dialog '#my-own-dialog-opener'
UX_ORACLE_OWNED="$WORK/owned-failed.json" check "temporary list: another APEX version → FAIL" "$WORK/own-263.json" 1 \
  "c['UX-DIALOG-FOCUS'] == 'FAIL' and 'UX-ORACLE-OWNED' not in adv" --dialog '#my-own-dialog-opener'
UX_ORACLE_OWNED="$WORK/owned-failed.json" check "temporary list: 26.2.0 is not 26.2 → FAIL" "$WORK/own-2620.json" 1 \
  "c['UX-DIALOG-FOCUS'] == 'FAIL' and 'UX-ORACLE-OWNED' not in adv" --dialog '#my-own-dialog-opener'
printf '{ not json' > "$WORK/owned-bad.json"
UX_ORACLE_OWNED="$WORK/owned-bad.json" check "an unreadable oracle-owned.json → BLOCKED, never 'no entry'" oracle-owned 2 "d['status'] == 'BLOCKED'" --dialog '#open'

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

# An app with environments (R-1): the page belongs to one of them, named with --env.
printf '{ "appId": 100, "appAlias": "demo", "evidenceDir": "ev", "environments": { "dev": { "sqlclConnection": "x" } } }\n' > "$P/apex-sync.json"
rc=0; (cd "$P" && PW_FAKE_OUT="$FIX/clean.json" "$PY" "$CHECK" --task T-2 >/dev/null 2>&1) || rc=$?
if [[ $rc -eq 2 ]]; then ok "environments and no --env → BLOCKED (exit 2)"
else bad "environments and no --env: exit $rc, expected 2"; fi
rc=0; (cd "$P" && PW_FAKE_OUT="$FIX/item-name.json" "$PY" "$CHECK" --env dev --task T-2 > "$WORK/out.json" 2>/dev/null) || rc=$?
if [[ $rc -eq 1 ]] && cmp -s "$WORK/out.json" "$P/ev/T-2/ui-demo.dev-runtime-orders.json" && "$PY" -c "import json,sys
d = json.load(open(sys.argv[1])); assert d['app'] == {'appAlias': 'demo', 'environment': 'dev'}, d['app']
assert d['evidence'][0]['path'] == 'ev/T-2/raw/ui-demo.dev/axe-orders.json', d['evidence']" "$WORK/out.json"; then
  ok "--env dev: ui-demo.dev-runtime-orders.json, the environment in the result"
else bad "--env dev: exit $rc, or the result is not the environment's"; fi

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

# references/by-hand.md: the snippets are the manual procedures' only code, so they must parse, be
# DOM functions (for `pw.sh eval`) or Playwright code (for `run-code`), never mixed, never touch
# focus, and never reach for `document` in Node code. Negative controls first: a tampered copy fails.
cat > "$WORK/by-hand-lint.py" <<'PYEOF'
import re, subprocess, shutil, sys
text = open(sys.argv[1], encoding="utf-8").read()
blocks = re.findall(r"^```js\n(.*?)^```", text, re.M | re.S)
problems = []
if len(blocks) < 3:
    problems.append(f"{len(blocks)} js snippets, expected at least 3")
node = shutil.which("node")
for i, b in enumerate(blocks, 1):
    run_code = b.lstrip().startswith("async (page)")
    if not run_code and not b.lstrip().startswith("() =>"):
        problems.append(f"snippet {i}: neither '() =>' (eval) nor 'async (page)' (run-code)")
    if run_code:
        # outside a function handed to evaluate(), `document` does not exist in Node
        if re.search(r"\bdocument\b", b):
            problems.append(f"snippet {i}: 'document' in run-code code")
    if re.search(r"\.focus\(|\.click\(|\.blur\(", b):
        problems.append(f"snippet {i}: moves focus or clicks on the shared session")
    if node:
        r = subprocess.run([node, "-e", "new Function('return (' + require('fs').readFileSync(0, 'utf8') + ')')"],
                           input=b, text=True, capture_output=True)
        if r.returncode:
            problems.append(f"snippet {i}: does not parse: {r.stderr.strip().splitlines()[-1] if r.stderr.strip() else r.returncode}")
print("PARSED" if node else "NOT-PARSED", len(blocks))
for p in problems:
    print("PROBLEM", p)
sys.exit(1 if problems else 0)
PYEOF
BH="$REPO/skills/apex-ux/references/by-hand.md"
sed 's/(\/\* the function, pasted here \*\/)/(document.title)/' "$BH" > "$WORK/bh-doc.md"
sed '0,/const de = /s//const de = (/' "$BH" > "$WORK/bh-syntax.md"
sed '0,/const de = /s//e.focus(); const de = /' "$BH" > "$WORK/bh-focus.md"
for v in doc:"'document' under run-code" syntax:"a snippet that does not parse" focus:"e.focus() on the shared session"; do
  if "$PY" "$WORK/by-hand-lint.py" "$WORK/bh-${v%%:*}.md" > "$WORK/lint.out" 2>&1; then
    if grep -q '^NOT-PARSED' "$WORK/lint.out" && [[ ${v%%:*} == syntax ]]; then echo "skip by-hand lint of ${v#*:} (node not found)"
    else bad "by-hand.md lint accepted ${v#*:}"; fi
  else ok "by-hand.md lint rejects ${v#*:}"; fi
done
if "$PY" "$WORK/by-hand-lint.py" "$BH" > "$WORK/lint.out" 2>&1; then
  ok "by-hand.md: every snippet is a DOM function or run-code code, read-only, and $(head -1 "$WORK/lint.out" | tr '[:upper:]' '[:lower:]')"
else bad "by-hand.md lint: $(grep PROBLEM "$WORK/lint.out" | head -3 | tr '\n' ';')"; fi

echo "ux-check: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
