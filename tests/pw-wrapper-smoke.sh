#!/usr/bin/env bash
# Smoke test for apex-sentinel's pw.sh, offline: a stubbed Playwright CLI records
# the argv it was handed and serves a canned `list --json`, so the wrapper's
# guarantees can be asserted without a browser —
#   * `open` on a LIVE session is routed to `goto` (a real open would kill the
#     browser and discard the APEX login),
#   * the TLS config is written and passed as a path that actually exists, and
#   * `login` delivers the test user's password to the browser WITHOUT ever putting
#     it on a command line. The stub records both the argv and the snippet file, so
#     that claim is asserted from both sides rather than assumed.
set -euo pipefail

PW=$(cd "$(dirname "$0")/../skills/apex-sentinel" && pwd)/scripts/pw.sh
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pw-smoke-XXXXXX")
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/badjq" "$WORK/ws"

cat > "$WORK/bin/playwright-cli" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$PW_LOG"
case " $* " in *" --version "*) echo "1.0.0"; exit 0 ;; esac
prev=""
for a in "$@"; do
  [[ "$a" == "list" ]] && { cat "$PW_STATE"; exit 0; }
  # Record what the wrapper actually handed us for --filename: mode first, then the
  # snippet body. Asserting on this is what proves the password TRAVELLED, so the
  # "not in argv" assertion cannot pass merely because the login never happened.
  if [[ "$prev" == "--filename" && -n "${PW_SNIP_LOG:-}" ]]; then
    { stat -c %a "$a" 2>/dev/null || stat -f %Lp "$a" 2>/dev/null; cat "$a"; } >> "$PW_SNIP_LOG"
  fi
  prev=$a
done
case " $* " in *" run-code "*) printf '"%s"\n' "${PW_FAKE_URL:-}"; exit 0 ;; esac
exit 0
EOF
chmod +x "$WORK/bin/playwright-cli"
printf '#!/usr/bin/env bash\nexit 127\n' > "$WORK/badjq/jq"      # present but broken
chmod +x "$WORK/badjq/jq"

export PATH="$WORK/bin:$PATH" PW_STATE="$WORK/state.json" PW_WORKSPACE="$WORK/ws"
PATH_OK="$PATH"                                                  # before the broken-jq case
OPEN='{"browsers":[{"name":"apex","workspace":"/x","status":"open"}]}'
SHUT='{"browsers":[]}'

pass=0; fail=0
ok()   { echo "ok   $1"; pass=$((pass+1)); }
bad()  { echo "FAIL $1"; shift; for f in "$@"; do [[ -s "$f" ]] && sed 's/^/       | /' "$f"; done; fail=$((fail+1)); }
check() {  # $1 = description, $2 = ERE the recorded argv must match
  if grep -qE -- "$2" "$PW_LOG"; then ok "$1"; else bad "$1 (argv did not match /$2/)" "$PW_LOG"; fi
}
check_absent() {  # $1 = description, $2 = fixed string that must NOT be in the argv
  if grep -qF -- "$2" "$PW_LOG"; then bad "$1 (argv contained it)" "$PW_LOG"; else ok "$1"; fi
}
check_no_match() {  # $1 = description, $2 = ERE the recorded argv must NOT match
  if grep -qE -- "$2" "$PW_LOG"; then bad "$1 (argv matched /$2/)" "$PW_LOG"; else ok "$1"; fi
}
check_in() {  # $1 = description, $2 = file, $3 = ERE it must match
  if grep -qE -- "$3" "$2" 2>/dev/null; then ok "$1"; else bad "$1 ($2 did not match /$3/)" "$2"; fi
}
run() {  # $1 = session state, rest = pw.sh args. RC/out/err are left for the caller.
  printf '%s\n' "$1" > "$PW_STATE"; shift
  PW_LOG="$WORK/log"; PW_SNIP_LOG="$WORK/snip"; export PW_LOG PW_SNIP_LOG
  : > "$PW_LOG"; : > "$PW_SNIP_LOG"
  RC=0; "$PW" "$@" >"$WORK/out" 2>"$WORK/err" || RC=$?
}

run "$SHUT" open "https://apex.example/r/ws/APP/"
check "closed session -> open, with --config" '-s apex open --config .* https://'
cfg=$(grep -o -- '--config [^ ]*' "$PW_LOG" | head -1 | cut -d' ' -f2)
if [[ -s "$cfg" ]] && grep -q ignoreHTTPSErrors "$cfg"; then
  echo "ok   --config points at a written TLS config"; pass=$((pass+1))
else
  echo "FAIL --config path does not exist or lacks ignoreHTTPSErrors: $cfg"; fail=$((fail+1))
fi

run "$OPEN" open "https://apex.example/p30"
check "live session -> goto, never a destructive open" '^-s apex goto '

# The session probe must not depend on jq merely being present: a jq that errors
# would report the live session as closed and the recovery path would then open —
# killing the browser and the APEX login it holds.
export PATH="$WORK/badjq:$PATH"
run "$OPEN" open "https://apex.example/p31"
check "broken jq + live session -> still goto" '^-s apex goto '
run "$SHUT" open "https://apex.example/p31"
check "broken jq + closed session -> open" '^-s apex open '

# ------------------------------------------------------------------ test-user login
# The point of `login` is that a password can be parameterised without leaking. argv
# is world-readable through /proc/<pid>/cmdline, so "did the secret stay out of argv"
# is the assertion this whole section exists for.
export PATH="$PATH_OK"                  # step back off the broken-jq PATH
SECRET='S3cr3tV4lue'
export PW_FAKE_URL='https://apex.example/r/ws/APP/home?session=8808821264318'
export APEX_TEST_FILE="$WORK/external.json"

# A real project repo: the username and the runtime URL are ordinary config, the
# password is not — so it comes from a gitignored .env, never from apex-sync.json.
mkdir -p "$WORK/proj"
git -C "$WORK/proj" init -q
printf '{ "appId": 100, "appAlias": "APP", "testUser": "TEST_QA", "runtimeUrl": "https://apex.example/r/ws/APP/" }\n' \
  > "$WORK/proj/apex-sync.json"
printf 'APEX_TEST_PASSWORD=%s\n' "$SECRET" > "$WORK/proj/.env"
cd "$WORK/proj"

run "$OPEN" login
check_absent   "login: the password never reaches argv"          "$SECRET"
check          "login: the snippet is handed over by --filename" '--filename '
check          "login: run-code is --raw, so the CLI cannot echo the snippet back" 'run-code --raw '
check_no_match "login: a live session is never re-opened"        '^-s apex open '
check_in       "login: the user comes from apex-sync.json"       "$WORK/snip" 'TEST_QA'
check_in       "login: the runtime URL comes from apex-sync.json" "$WORK/snip" 'https://apex\.example/r/ws/APP/'
check_in       "login: the password comes from the repo's .env"  "$WORK/snip" "$SECRET"
check_in       "login: the session token is printed on stdout"   "$WORK/out"  '^8808821264318$'
snip=$(grep -o -- '--filename [^ ]*' "$PW_LOG" | head -1 | cut -d' ' -f2)
if [[ -n "$snip" && ! -e "$snip" ]]; then ok "login: the snippet file is removed afterwards"
else bad "login: snippet file still on disk: $snip"; fi

# The stub cannot run the snippet, so the one thing this harness CAN pin down about
# idempotency is the ordering that makes it work: navigating to the app root without a
# token opens a fresh APEX session, so a `goto` placed before the signed-in check would
# destroy the login on every call. That regression cost a real session once.
guard=$(grep -n 'await signedIn()'  "$WORK/snip" | head -1 | cut -d: -f1)
nav=$(  grep -n 'page.goto(APP'     "$WORK/snip" | head -1 | cut -d: -f1)
if [[ -n "$guard" && -n "$nav" && "$guard" -lt "$nav" ]]; then
  ok "login: the held page is checked BEFORE any navigation"
else bad "login: signed-in guard ($guard) must precede the goto ($nav)" "$WORK/snip"; fi

# POSIX modes are synthetic under Git Bash, so assert this only where it means something.
case "${OSTYPE:-}" in
  msys*|cygwin*) echo "skip mode assertion (synthetic POSIX modes on Windows)" ;;
  *) check_in "login: the snippet is created 600, before a byte is written" "$WORK/snip" '^[0-7]?[0-7]00$' ;;
esac

# An explicit URL argument wins, so a run can target another page or environment.
run "$OPEN" login "https://other.example/r/ws/APP/"
check_in "login: an explicit url argument overrides apex-sync.json" "$WORK/snip" 'https://other\.example/'

# The environment beats the .env, which is how CI supplies the password.
export APEX_TEST_PASSWORD='EnvW1nsHere'
run "$OPEN" login
check_in "login: \$APEX_TEST_PASSWORD overrides the .env" "$WORK/snip" 'EnvW1nsHere'
if grep -qF -- "$SECRET" "$WORK/snip"; then bad "login: the overridden .env password was still used" "$WORK/snip"
else ok "login: the overridden .env password is not used"; fi
unset APEX_TEST_PASSWORD

# No .env in the project: fall back to the json outside the repo.
rm -f "$WORK/proj/.env"
printf '{ "user": "EXT_USER", "password": "ExtP4ssw0rd" }\n' > "$WORK/external.json"
run "$OPEN" login
check_in "login: falls back to the json outside the repo" "$WORK/snip" 'ExtP4ssw0rd'

# Nothing anywhere: stop and say what to set. Never guess, never prompt.
rm -f "$WORK/external.json"
run "$OPEN" login
if [[ $RC -ne 0 ]] && grep -q 'no test password' "$WORK/err"; then
  ok "login: no password anywhere -> actionable failure"
else bad "login: expected a non-zero exit naming the fix, got exit $RC" "$WORK/err"; fi
printf 'APEX_TEST_PASSWORD=%s\n' "$SECRET" > "$WORK/proj/.env"

# A rejected login must not read as success: APEX re-renders the login page, so the
# notification text is the only evidence of what went wrong.
export PW_FAKE_URL='LOGIN-FAILED Credenciales de conexión no válidas'
run "$OPEN" login
if [[ $RC -ne 0 ]] && grep -q 'Credenciales' "$WORK/err" && grep -q '12 s' "$WORK/err"; then
  ok "login: a rejected login fails loudly and names the throttling"
else bad "login: expected a non-zero exit quoting the notification, got exit $RC" "$WORK/err"; fi

# Landing back on the login page must never be reported as signed in, even when the URL
# carries a session token — the login page has one of its own. This is the wrapper's own
# check, independent of the snippet's verdict, because a false "logged in" would make
# every later assertion measure a logged-out page.
export PW_FAKE_URL='https://apex.example/r/ws/APP/login?session=12011062162154&tz=X'
run "$OPEN" login
if [[ $RC -ne 0 ]] && grep -q 'NOT signed in' "$WORK/err"; then
  ok "login: a login-page URL is a failure, token or no token"
else bad "login: expected a non-zero exit rejecting the login-page URL, got exit $RC" "$WORK/err" "$WORK/out"; fi
cd /                                    # the EXIT trap removes $WORK

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
