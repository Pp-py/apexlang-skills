#!/usr/bin/env bash
# apex-security's runtime probes (skills/apex-security/scripts/sec-probe.py), offline: the real
# pw.sh against a stubbed Playwright CLI that hands back canned browser verdicts, and a local
# HTTP server (127.0.0.1) for the cookie-less probe —
#   * each probe maps to its criterion: refused → PASS, rendered → FAIL, not asked → NOT_RUN;
#   * a control that rendered no page, or an error page, is UNKNOWN, never a PASS; APEX's
#     error page under the requested page id is a refusal (checksum, authorization);
#   * the low-privilege user logs in in its own session, its password never in argv or output;
#   * stdout carries no session id and no checksum; --task writes the result.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
PROBE="$REPO/skills/apex-security/scripts/sec-probe.py"
PY=$(command -v python3 || command -v python || true)
[[ -n "$PY" ]] || { echo "sec-probe: BLOCKED — python3 is required" >&2; exit 2; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/sec-probe-XXXXXX")
SRV=""
trap '[[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null; rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/ws" "$WORK/tmp" "$WORK/proj"

cat > "$WORK/bin/playwright-cli" <<'STUB'
#!/usr/bin/env bash
case " $* " in *" --version "*) echo "1.0.0"; exit 0 ;; esac
printf '%s\n' "$*" >> "$PW_ARGV_LOG"
prev=""; snip=""
for a in "$@"; do
  [[ "$a" == "list" ]] && { cat "$PW_STATE"; exit 0; }
  [[ "$prev" == "--filename" ]] && snip=$a
  prev=$a
done
case " $* " in
  *" run-code "*)
    if grep -q "LOGIN-OK" "$snip"; then printf '"LOGIN-OK|QA_LOW|https://apex.example/ords/r/ws/app/home?session=99"\n'
    elif [[ " $* " == *" -s apex-low "* ]]; then cat "$PW_FAKE_LOW"
    else cat "$PW_FAKE_OUT"; fi ;;
esac
exit 0
STUB
chmod +x "$WORK/bin/playwright-cli"
printf '{"browsers":[{"name":"apex","workspace":"/x","status":"open"},{"name":"apex-low","workspace":"/x","status":"open"}]}\n' > "$WORK/state.json"
export PATH="$WORK/bin:$PATH" PW_STATE="$WORK/state.json" PW_WORKSPACE="$WORK/ws" PW_ARGV_LOG="$WORK/argv.log" \
       TMPDIR="$WORK/tmp" TMP="$WORK/tmp" TEMP="$WORK/tmp" PW_FAKE_OUT="$WORK/main.json" PW_FAKE_LOW="$WORK/low.json"

# The cookie-less side: a page that sends you to login, one that serves itself, one neither.
cat > "$WORK/srv.py" <<'SRV'
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path == "/ords/r/ws/app/orders":
            self.send_response(302); self.send_header("Location", "/ords/r/ws/app/login?session=123456789"); self.end_headers(); return
        if self.path == "/ords/r/ws/app/cookied":   # APEX 26.2: redirects again until its cookie comes back
            self.send_response(302)
            if "ORA_WWV_APP=1" in (self.headers.get("Cookie") or ""):
                self.send_header("Location", "/ords/r/ws/app/login?session=123456789")
            else:
                self.send_header("Set-Cookie", "ORA_WWV_APP=1; Path=/"); self.send_header("Location", "/ords/r/ws/app/cookied")
            self.end_headers(); return
        body = {"/ords/r/ws/app/login?session=123456789": '<form><input type="password" name="p"></form>',
                "/ords/r/ws/app/open": '<input type="hidden" name="p_flow_step_id" id="pFlowStepId" value="10">',
                "/ords/r/ws/app/odd": '<p>maintenance</p>'}.get(self.path, "")
        self.send_response(200 if body else 404); self.end_headers(); self.wfile.write(body.encode())
s = http.server.HTTPServer(("127.0.0.1", 0), H)
print(s.server_address[1], flush=True)
s.serve_forever()
SRV
"$PY" "$WORK/srv.py" > "$WORK/port" & SRV=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -s "$WORK/port" ]] && break; "$PY" -c 'import time; time.sleep(0.3)'; done
BASE="http://127.0.0.1:$(cat "$WORK/port")/ords/r/ws/app"

cd "$WORK/proj"; git init -q
config() { printf '%s\n' "$1" > apex-sync.json; }
config '{ "appId": 100, "appAlias": "demo", "testUser": "QA", "runtimeUrl": "https://apex.example/ords/r/ws/app/" }'
# main.json / low.json: the browser verdicts. $1 = open[] entries, $2 = extra members
main() { printf '{"verdict":"OK","url":"https://apex.example/ords/r/ws/app/orders?session=123456789","open":[%s]%s}\n' "$1" "${2:-}" > "$WORK/main.json"; }
low()  { printf '{"verdict":"OK","url":"https://apex.example/ords/r/ws/app/home","open":[%s]}\n' "$1" > "$WORK/low.json"; }
O() { printf '{"url":"%s","step":%s,"login":false}' "$1" "$2"; }

pass=0; fail=0
ok()  { echo "ok   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1"; fail=$((fail + 1)); sed 's/^/       | /' "$WORK/out.json" | head -12; }
check() {  # $1 = label, $2 = expected exit, $3 = python assertion on d / c, rest = args
  local label=$1 want=$2 assert=$3 rc=0; shift 3
  "$PY" "$PROBE" "$@" > "$WORK/out.json" 2>/dev/null || rc=$?
  if [[ $rc -ne $want ]]; then bad "$label: exit $rc, expected $want"; return 0; fi
  if [[ -n "$assert" ]] && ! "$PY" -c "import json,sys
d = json.load(open(sys.argv[1])); c = {x['id']: x['status'] for x in d['criteria']}
assert $assert, (c, d['status'], d['reasons'])" "$WORK/out.json" 2>/dev/null; then bad "$label: assertion"; return 0; fi
  ok "$label (exit $rc)"
}

main "$(O "$BASE/orders" '"10"'),$(O "$BASE/open" '"10"'),$(O "$BASE/odd" '"10"')"
check "anon: redirected to the login → PASS" 0 "c['SEC-ANON-REDIRECT'] == 'PASS' and c['SEC-ROLE-REFUSED'] == 'NOT_RUN'" --anon "$BASE/orders"
check "anon: the page served with no login → FAIL" 1 "c['SEC-ANON-REDIRECT'] == 'FAIL'" --anon "$BASE/open"
check "anon: neither the page nor a login → UNKNOWN" 3 "d['status'] == 'UNKNOWN'" --anon "$BASE/odd"
main "$(O "$BASE/cookied" '"10"')"
check "anon: a login reached only by keeping APEX's cookie → PASS" 0 "c['SEC-ANON-REDIRECT'] == 'PASS'" --anon "$BASE/cookied"
main "$(O "$BASE/orders" null)"
check "anon: the control rendered no page → UNKNOWN, never PASS" 3 "c['SEC-ANON-REDIRECT'] == 'NOT_RUN' and d['status'] == 'UNKNOWN'" --anon "$BASE/orders"

L="https://apex.example/ords/r/ws/app/resolve?p62_id=5&cs=3ABCDEF"
main "" ",\"tamper\":{\"link\":\"$L\",\"control\":$(O "$L" '"62"'),\"noChecksum\":$(O x '"9999"'),\"altered\":$(O x null)}"
check "tamper: both variants refused → PASS" 0 "c['SEC-CHECKSUM-TAMPER'] == 'PASS'" --tamper
if grep -q '3ABCDEF\|123456789' "$WORK/out.json"; then bad "stdout carries a checksum or a session id"
else ok "stdout carries neither the checksum nor the session id"; fi
main "" ",\"tamper\":{\"link\":\"$L\",\"control\":$(O "$L" '"62"'),\"noChecksum\":$(O x '"62"'),\"altered\":$(O x null)}"
check "tamper: rendered without its checksum → FAIL" 1 "c['SEC-CHECKSUM-TAMPER'] == 'FAIL'" --tamper
E() { printf '{"url":"%s","step":%s,"login":false,"error":true}' "$1" "$2"; }   # APEX's error page
main "" ",\"tamper\":{\"link\":\"$L\",\"control\":$(O "$L" '"62"'),\"noChecksum\":$(E x '"62"'),\"altered\":$(E x '"62"')}"
check "tamper: APEX's error page, under the same page id → refused, PASS" 0 "c['SEC-CHECKSUM-TAMPER'] == 'PASS'" --tamper
main "" ",\"tamper\":{\"link\":\"$L\",\"control\":$(E "$L" '"62"'),\"noChecksum\":$(E x '"62"'),\"altered\":null}"
check "tamper: a control that is itself an error page → UNKNOWN" 3 "c['SEC-CHECKSUM-TAMPER'] == 'NOT_RUN'" --tamper
main "" ',"tamper":{"link":null}'
check "tamper: no cs= link → NOT_RUN, nothing exercised → UNKNOWN" 3 "c['SEC-CHECKSUM-TAMPER'] == 'NOT_RUN'" --tamper

R="https://apex.example/ords/r/ws/app/admin"
main "$(O "$R" '"20"')"
check "role: no lowPrivUser → NOT_RUN" 3 "c['SEC-ROLE-REFUSED'] == 'NOT_RUN'" --role "$R"
config '{ "appId": 100, "appAlias": "demo", "testUser": "QA", "runtimeUrl": "https://apex.example/ords/r/ws/app/", "lowPrivUser": "QA_LOW" }'
check "role: no low password → NOT_RUN" 3 "c['SEC-ROLE-REFUSED'] == 'NOT_RUN'" --role "$R"
export APEX_TEST_PASSWORD_LOW_DEMO='L0wS3cret'
: > "$WORK/argv.log"
low "$(O "$R" '"9999"')"
check "role: refused for the low user → PASS" 0 "c['SEC-ROLE-REFUSED'] == 'PASS'" --role "$R"
if grep -q -- '-s apex-low run-code' "$WORK/argv.log" && grep -q -- '-s apex-low close' "$WORK/argv.log"; then
  ok "role: the low user's own session, closed afterwards"; else bad "role: not in its own session, or not closed"; fi
if grep -rq 'L0wS3cret' "$WORK/argv.log" "$WORK/out.json"; then bad "role: the low password reached argv or the result"
else ok "role: the low password is in neither argv nor the result"; fi
low "$(E "$R" '"20"')"
check "role: APEX's authorization error, under the same page id → PASS" 0 "c['SEC-ROLE-REFUSED'] == 'PASS'" --role "$R"
low "$(O "$R" '"20"')"
check "role: rendered for the low user → FAIL" 1 "c['SEC-ROLE-REFUSED'] == 'FAIL'" --role "$R"
unset APEX_TEST_PASSWORD_LOW_DEMO
printf 'APEX_TEST_PASSWORD_LOW_DEMO=%s\n' 'L0wD0tenv' > .env   # secrets-scan: allow a fake password this test proves never leaks
: > "$WORK/argv.log"
low "$(O "$R" '"9999"')"
check "role: the low password from the repo's .env, as pw.sh reads it → PASS" 0 "c['SEC-ROLE-REFUSED'] == 'PASS'" --role "$R"
if grep -rq 'L0wD0tenv' "$WORK/argv.log" "$WORK/out.json"; then bad "role: the .env password reached argv or the result"
else ok "role: the .env password is in neither argv nor the result"; fi
rm -f .env

main "" ',"xss":{"elements":0,"text":true}'
check "xss: shown as text → PASS" 0 "c['SEC-XSS-ESCAPED'] == 'PASS'" --xss T0KEN1
main "" ',"xss":{"elements":1,"text":false}'
check "xss: rendered as markup → FAIL" 1 "c['SEC-XSS-ESCAPED'] == 'FAIL'" --xss T0KEN1
check "xss: a token that could inject → BLOCKED" 2 "" --xss 'a"b'
printf '{"verdict":"NOT-LOGGED-IN","url":"https://apex.example/ords/r/ws/app/login"}\n' > "$WORK/main.json"
check "a login page held → BLOCKED" 2 "" --xss T0KEN1
check "nothing asked → BLOCKED" 2 ""

main "" ',"xss":{"elements":0,"text":true}'
rc=0; "$PY" "$PROBE" --task T-1 --xss T0KEN1 > "$WORK/out.json" 2>/dev/null || rc=$?
if [[ $rc -eq 0 ]] && cmp -s "$WORK/out.json" .apex-evidence/T-1/security-demo-runtime.json; then
  ok "--task writes .apex-evidence/T-1/security-demo-runtime.json"; else bad "--task: exit $rc, or no file"; fi

echo "sec-probe: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
