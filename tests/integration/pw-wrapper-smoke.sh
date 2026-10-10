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

PW=$(cd "$(dirname "$0")/../../skills/apex-sentinel" && pwd)/scripts/pw.sh
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pw-smoke-XXXXXX")
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/badjq" "$WORK/ws"

cat > "$WORK/bin/playwright-cli" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$PW_LOG"
printf '%s\n' "$PWD" >> "${PW_CWD_LOG:-/dev/null}"
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
  # a CLI that fails and echoes the code it was handed — password included
  [[ "$prev" == "--filename" && -n "${PW_FAKE_RUNCODE_ECHO:-}" ]] && { cat "$a"; exit 1; }
  prev=$a
done
case " $* " in *" run-code "*) printf '"%s"\n' "${PW_FAKE_URL:-}"; exit 0 ;; esac
exit "${PW_FAKE_RC:-0}"
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
# The snippet answers with a verdict; LOGIN-OK carries the APP_USER APEX reported.
export PW_FAKE_URL='LOGIN-OK|TEST_QA|https://apex.example/r/ws/APP/home?session=8808821264318'
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
  *) check_in "login: the snippet file is mode 600" "$WORK/snip" '^[0-7]?[0-7]00$' ;;
esac

# A CLI that fails and prints back what it was handed must not print the password:
# every message pw.sh builds from that output goes through redact().
PW_FAKE_RUNCODE_ECHO=1 run "$OPEN" login
if [[ $RC -eq 2 ]] && ! grep -qF -- "$SECRET" "$WORK/err" "$WORK/out" && grep -qF '***' "$WORK/err"; then
  ok "login: a failing CLI that echoes the snippet never prints the password"
else bad "login: the password leaked, or the failure was not reported (exit $RC)" "$WORK/err"; fi

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
export PW_FAKE_URL='LOGIN-FAILED|Credenciales de conexión no válidas'
run "$OPEN" login
if [[ $RC -ne 0 ]] && grep -q 'Credenciales' "$WORK/err" && grep -q '12 s' "$WORK/err"; then
  ok "login: a rejected login fails loudly and names the throttling"
else bad "login: expected a non-zero exit quoting the notification, got exit $RC" "$WORK/err"; fi

# Landing back on the login page must never be reported as signed in, even when the URL
# carries a session token — the login page has one of its own. This is the wrapper's own
# check, independent of the snippet's verdict, because a false "logged in" would make
# every later assertion measure a logged-out page.
export PW_FAKE_URL='LOGIN-OK|TEST_QA|https://apex.example/r/ws/APP/login?session=12011062162154&tz=X'
run "$OPEN" login
if [[ $RC -ne 0 ]] && grep -q 'NOT signed in' "$WORK/err"; then
  ok "login: a login-page URL is a failure, token or no token"
else bad "login: expected a non-zero exit rejecting the login-page URL, got exit $RC" "$WORK/err" "$WORK/out"; fi

# Leaving the login page is not a login: a public landing page, an SSO redirect or a
# change-password interstitial all leave it too. Only APEX naming the test user as the
# session's APP_USER counts, and the wrapper re-checks the snippet's verdict.
export PW_FAKE_URL='LOGIN-OK|test_qa|https://apex.example/r/ws/APP/home?session=42'
run "$OPEN" login
if [[ $RC -eq 0 ]] && grep -qx '42' "$WORK/out"; then ok "login: APP_USER is compared case-insensitively"
else bad "login: expected exit 0 and the token, got exit $RC" "$WORK/err"; fi
export PW_FAKE_URL='LOGIN-OK|SOMEONE_ELSE|https://apex.example/r/ws/APP/home?session=42'
run "$OPEN" login
if [[ $RC -eq 2 ]] && grep -q "signed in as 'SOMEONE_ELSE'" "$WORK/err"; then ok "login: an OK for another user is refused by the wrapper"
else bad "login: expected exit 2 naming the other user, got exit $RC" "$WORK/err"; fi
export PW_FAKE_URL='LOGIN-WRONG-USER|SOMEONE_ELSE'
run "$OPEN" login
if [[ $RC -eq 2 ]] && grep -q 'close-all' "$WORK/err"; then ok "login: a browser held by another user is refused"
else bad "login: expected exit 2 with the close-all hint, got exit $RC" "$WORK/err"; fi
export PW_FAKE_URL='LOGIN-UNVERIFIED|the page is anonymous (APP_USER=nobody)'
run "$OPEN" login
if [[ $RC -eq 2 ]] && grep -q 'cannot verify who is signed in' "$WORK/err"; then ok "login: an unverifiable session is refused"
else bad "login: expected exit 2 for an unverified login, got exit $RC" "$WORK/err"; fi
export PW_FAKE_URL='https://apex.example/r/ws/APP/home?session=42'      # the old, verdict-less answer
run "$OPEN" login
if [[ $RC -eq 2 ]] && grep -q 'no verdict' "$WORK/err"; then ok "login: anything but a verdict fails closed"
else bad "login: expected exit 2 'no verdict', got exit $RC" "$WORK/err"; fi
check_in "login: the snippet reads apex.env.APP_USER"   "$WORK/snip" 'apex\.env\.APP_USER'
check_in "login: the snippet compares the user"         "$WORK/snip" 'toUpperCase\(\) !== USER\.toUpperCase\(\)'
if grep -q 'return page.url()' "$WORK/snip"; then bad "login: the snippet still returns a bare URL as success" "$WORK/snip"
else ok "login: no bare-URL success path left in the snippet"; fi
export PW_FAKE_URL='LOGIN-OK|TEST_QA|https://apex.example/r/ws/APP/home?session=8808821264318'

# A command that had to reopen a dead browser ran on a logged-out page: exit 3, so the
# step reads as UNKNOWN instead of a clean 0 behind a warning.
run "$SHUT" eval '() => 1'
if [[ $RC -eq 3 ]] && grep -q 'exit 3' "$WORK/err"; then ok "recovered session: the call exits 3"
else bad "recovered session: expected exit 3, got $RC" "$WORK/err"; fi
PW_FAKE_RC=1 run "$SHUT" eval '() => 1'
if [[ $RC -eq 1 ]]; then ok "recovered session: the CLI's own failure code still wins"
else bad "recovered session: expected the CLI's exit 1, got $RC" "$WORK/err"; fi
run "$OPEN" eval '() => 1'
if [[ $RC -eq 0 ]]; then ok "live session: a passthrough call exits 0"
else bad "live session: expected exit 0, got $RC" "$WORK/err"; fi

# --- one private workspace per project, never inside it. It used to be one shared
# /tmp/apex-sentinel-pw: two projects drove the same browser, login and last-url.
export PW_CWD_LOG="$WORK/cwdlog"
mkdir -p "$WORK/tmp" "$WORK/proj2" && git -C "$WORK/proj2" init -q
# shellcheck disable=SC2030,SC2031   # the subshell-local environment is the point
ws_of() {  # $1 = dir to run from, PW_WORKSPACE unset -> the workspace the CLI ran in
  : > "$PW_CWD_LOG"; printf '%s\n' "$OPEN" > "$PW_STATE"
  ( cd "$1" && unset PW_WORKSPACE && export TMPDIR="$WORK/tmp" PW_LOG="$WORK/log" && "$PW" eval '() => 1' ) >/dev/null 2>&1 || true
  tail -1 "$PW_CWD_LOG"            # the eval itself (the launcher probe runs where pw.sh was called)
}
w1=$(ws_of "$WORK/proj"); w2=$(ws_of "$WORK/proj2")
if [[ "$w1" == "$WORK/tmp/apex-sentinel-$(id -u)/proj-APP-"* ]]; then ok "workspace: per user, named after the project and its app"
else bad "workspace: unexpected default '$w1'"; fi
if [[ -n "$w1" && -n "$w2" && "$w1" != "$w2" ]]; then ok "workspace: two projects get two workspaces"
else bad "workspace: '$w1' vs '$w2'"; fi
if [[ "$w1" != "$WORK/proj"* ]]; then ok "workspace: never inside the project"
else bad "workspace: '$w1' is inside the project"; fi
# An explicit PW_WORKSPACE inside the repo is refused unless the repo ignores it.
RC=0; (cd "$WORK/proj" && PW_WORKSPACE="$WORK/proj/ws" "$PW" list) >/dev/null 2>"$WORK/err" || RC=$?
if [[ $RC -eq 2 ]] && grep -q 'inside the project repo' "$WORK/err"; then ok "workspace: inside the repo and not ignored -> refused"
else bad "workspace: expected exit 2 for an unignored in-repo workspace, got $RC" "$WORK/err"; fi
printf '.playwright/\n.playwright-cli/\n' > "$WORK/proj/.gitignore"
RC=0; (cd "$WORK/proj" && PW_WORKSPACE="$WORK/proj/ws" "$PW" list) >/dev/null 2>"$WORK/err" || RC=$?
if [[ $RC -eq 0 ]]; then ok "workspace: inside the repo but ignored -> allowed"
else bad "workspace: an ignored in-repo workspace was refused (exit $RC)" "$WORK/err"; fi
rm -f "$WORK/proj/.gitignore"; rm -rf "$WORK/proj/ws"
unset PW_CWD_LOG

# --- the TLS setting is rewritten when it changes (it used to be written once, so
# PW_INSECURE_TLS=0 set later changed nothing), but never under a live browser that
# was launched with the old setting.
CFGF="$WORK/ws/.playwright/cli.config.json"
rm -f "$CFGF"
PW_INSECURE_TLS=0 run "$SHUT" open "https://apex.example/"
if [[ -f "$CFGF" ]] && ! grep -q ignoreHTTPSErrors "$CFGF"; then ok "tls: PW_INSECURE_TLS=0 writes a validating config"
else bad "tls: expected a config without ignoreHTTPSErrors" "$CFGF"; fi
PW_INSECURE_TLS=1 run "$SHUT" open "https://apex.example/"
if grep -q ignoreHTTPSErrors "$CFGF"; then ok "tls: flipping back to 1 rewrites it"
else bad "tls: the config was not rewritten" "$CFGF"; fi
PW_INSECURE_TLS=0 run "$OPEN" eval '() => 1'
if [[ $RC -eq 2 ]] && grep -q 'close-all first' "$WORK/err" && grep -q ignoreHTTPSErrors "$CFGF"; then
  ok "tls: a change under an open browser is refused, file untouched"
else bad "tls: expected exit 2 and an untouched config, got $RC" "$WORK/err"; fi
PW_INSECURE_TLS=maybe run "$OPEN" list
if [[ $RC -eq 2 ]]; then ok "tls: a value other than 0/1 is refused"
else bad "tls: expected exit 2 for PW_INSECURE_TLS=maybe, got $RC" "$WORK/err"; fi

# --- the APEX session token never lands on disk; snapshots go with the session.
run "$OPEN" goto 'https://apex.example/r/ws/APP/p30?session=123&tz=1'
if [[ "$(cat "$WORK/ws/.playwright/last-url")" == 'https://apex.example/r/ws/APP/p30?tz=1' ]]; then
  ok "last-url keeps the page, drops the session token"
else bad "last-url still carries the token: $(cat "$WORK/ws/.playwright/last-url")"; fi
mkdir -p "$WORK/ws/.playwright-cli" && : > "$WORK/ws/.playwright-cli/page-1.yml"
run "$OPEN" close-all
if [[ $RC -eq 0 && ! -e "$WORK/ws/.playwright-cli" ]]; then ok "close-all purges the snapshots"
else bad "close-all left the snapshots behind (exit $RC)" "$WORK/err"; fi
# --- several apps (apps[]): each its own test user, URL, password and browser. With
# more than one, a browser-holding call must name its app — guessing logs into one
# app with another's credentials.
mkdir -p "$WORK/multi" && git -C "$WORK/multi" init -q
printf '%s\n' '{ "apexlangDir": "src", "sqlclConnection": "dev", "testUser": "QA",
  "apps": [ { "appId": 100, "appAlias": "hr", "testUser": "QA_HR", "runtimeUrl": "https://apex.example/r/ws/hr/" },
            { "appId": 200, "appAlias": "sales-eu", "runtimeUrl": "https://apex.example/r/ws/sales/" } ] }' \
  > "$WORK/multi/apex-sync.json"
cd "$WORK/multi"
run "$OPEN" eval '() => 1'
if [[ $RC -eq 2 ]] && grep -q 'declares 2 apps — name one' "$WORK/err"; then ok "multi: a call without --app is refused"
else bad "multi: expected exit 2 asking for --app, got $RC" "$WORK/err"; fi
run "$OPEN" --app nope eval '() => 1'
if [[ $RC -eq 2 ]] && grep -q "declares no app 'nope'" "$WORK/err"; then ok "multi: an unknown --app is refused"
else bad "multi: expected exit 2 for --app nope, got $RC" "$WORK/err"; fi
RC=0; "$PW" apps > "$WORK/out" 2>"$WORK/err" || RC=$?
if [[ $RC -eq 0 ]] && grep -qx $'sales-eu\tQA\thttps://apex.example/r/ws/sales/' "$WORK/out"; then ok "multi: apps lists each app with the top-level defaults applied"
else bad "multi: apps (exit $RC)" "$WORK/out" "$WORK/err"; fi

export APEX_TEST_PASSWORD_HR='HrS3cret' PW_FAKE_URL='LOGIN-OK|QA_HR|https://apex.example/r/ws/hr/home?session=77'
run "$OPEN" --app hr login
check_in "multi: login uses the app's own test user"   "$WORK/snip" 'QA_HR'
check_in "multi: ... its own runtime URL"               "$WORK/snip" 'https://apex\.example/r/ws/hr/'
check_in "multi: ... and \$APEX_TEST_PASSWORD_<ALIAS>"  "$WORK/snip" 'HrS3cret'
check_absent "multi: the per-app password stays out of argv" 'HrS3cret'
printf 'APEX_TEST_PASSWORD_SALES_EU=EuS3cret\nAPEX_TEST_PASSWORD=Sh4red\n' > "$WORK/multi/.env"
export PW_FAKE_URL='LOGIN-OK|QA|https://apex.example/r/ws/sales/home?session=78'
run "$OPEN" --app sales-eu login
check_in "multi: a dash in the alias becomes _ in the variable (.env)" "$WORK/snip" 'EuS3cret'
check_in "multi: an app without testUser takes the default"           "$WORK/snip" 'USER = "QA"'
unset APEX_TEST_PASSWORD_HR
export PW_FAKE_URL='LOGIN-OK|QA_HR|https://apex.example/r/ws/hr/home?session=79'
run "$OPEN" --app hr login
check_in "multi: without a per-app password the shared one serves" "$WORK/snip" 'Sh4red'
rm -f "$WORK/multi/.env"

export PW_CWD_LOG="$WORK/cwdlog"
# shellcheck disable=SC2030,SC2031   # the subshell-local environment is the point
ws_app() {  # $1 = alias → the workspace a call for that app ran in
  : > "$PW_CWD_LOG"; printf '%s\n' "$OPEN" > "$PW_STATE"
  ( unset PW_WORKSPACE && export TMPDIR="$WORK/tmp" PW_LOG="$WORK/log" && "$PW" --app "$1" eval '() => 1' ) >/dev/null 2>&1 || true
  tail -1 "$PW_CWD_LOG"
}
wh=$(ws_app hr); we=$(ws_app sales-eu)
if [[ "$wh" == *"/multi-hr-"* && "$we" == *"/multi-sales-eu-"* ]]; then ok "multi: each app gets its own browser workspace"
else bad "multi: workspaces '$wh' / '$we'"; fi
mkdir -p "$wh/.playwright-cli" "$we/.playwright-cli"
RC=0
# shellcheck disable=SC2030,SC2031
( unset PW_WORKSPACE && export TMPDIR="$WORK/tmp" PW_LOG="$WORK/log" && "$PW" close-all ) >/dev/null 2>"$WORK/err" || RC=$?
if [[ $RC -eq 0 && ! -e "$wh/.playwright-cli" && ! -e "$we/.playwright-cli" ]]; then ok "multi: close-all without --app tears down every app's session"
else bad "multi: close-all left a workspace behind (exit $RC)" "$WORK/err"; fi
unset PW_CWD_LOG

cd /                                    # the EXIT trap removes $WORK

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
