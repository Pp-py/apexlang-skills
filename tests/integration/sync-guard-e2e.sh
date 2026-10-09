#!/usr/bin/env bash
# E2E harness for apex-sync-guard: exercises the full protocol offline.
# A stubbed SQLcl answers `apex export` by copying from a fixture "remote"
# dir (the fake Builder), so no database or real SQLcl is needed.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
SKILL_DIR="$REPO/skills/apex-sync-guard"
CHK="$SKILL_DIR/scripts/apex-sync-check.sh"
HOOK="$SKILL_DIR/scripts/apex-sync-hook.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/sync-guard-e2e-XXXXXX")
trap 'rm -rf "$WORK"' EXIT
export TMPDIR="$WORK"                       # keep the scripts' scratch dirs inside WORK
mkdir -p "$WORK/bin" "$WORK/proj/src/demo"

# --- stub SQLcl: 'apex export -dir X' copies the fixture; selects return a fixed stamp
cat > "$WORK/bin/sql" <<'EOF'
#!/usr/bin/env bash
stmts=$(cat)
if grep -q 'apex export' <<<"$stmts"; then
  [[ -n "${FAKE_EXPORT_FAIL:-}" ]] && { echo "SQL Error: simulated export failure" >&2; exit 1; }
  if grep -q -- '-dir "' <<<"$stmts"; then          # the guard quotes paths holding spaces
    dir=$(sed -n 's/.*-dir "\([^"]*\)".*/\1/p' <<<"$stmts")
  else
    dir=$(sed -n 's/.*-dir \([^ ]*\).*/\1/p' <<<"$stmts")
  fi
  mkdir -p "$dir/demo" && cp -r "$FAKE_REMOTE/demo/." "$dir/demo/"
elif grep -q 'greatest' <<<"$stmts"; then
  echo "2026-07-17T10:00:00"
elif grep -q 'apex-sync-appcount' <<<"$stmts"; then
  # Unset means "1 row" — the app exists, which every other case here assumes.
  # Empty means the answer came back unreadable, which the guard must treat as
  # "cannot tell", never as "no app".
  printf '%s\n' "${FAKE_REMOTE_APP_COUNT-1}"
elif grep -q 'apex-sync-doctor' <<<"$stmts"; then
  echo "apex-sync-doctor ${FAKE_APP_COUNT:-1}"
fi
EOF
chmod +x "$WORK/bin/sql"
export PATH="$WORK/bin:$PATH" FAKE_REMOTE="$WORK/remote"

# --- project repo: apex-sync.json + LOCAL source; remote fixture starts identical
cd "$WORK/proj"
git init -q
git config user.email sync-guard-e2e@example.com
git config user.name  sync-guard-e2e
printf '{ "appId": 100, "appAlias": "demo", "apexlangDir": "src", "sqlclConnection": "fake", "ignorePaths": ["apex-exports/"] }\n' > apex-sync.json
printf 'application 100 (\n  name: Demo\n)\n' > src/demo/application.apx
printf 'page 30 (\n  name: One\n)\n' > src/demo/p30.apx
mkdir -p src/demo/apex-exports && echo legacy > src/demo/apex-exports/old.sql   # repo-only, must be ignored
git add -A && git commit -qm init
mkdir -p "$WORK/remote" && cp -r src/demo "$WORK/remote/demo" && rm -rf "$WORK/remote/demo/apex-exports"

pass=0; fail=0
expect() {  # $1 = description, $2 = expected exit code, rest = command
  local desc=$1 want=$2; shift 2
  local out got=0; out=$("$@" 2>&1) || got=$?
  if [[ "$got" == "$want" ]]; then
    echo "ok   $desc"; pass=$((pass+1))
  else
    echo "FAIL $desc (exit $got, wanted $want)"; fail=$((fail+1))
    # printed, not swallowed: these failures usually only reproduce on another
    # platform's CI, where this output is the only evidence available
    while IFS= read -r l; do printf '       | %s\n' "$l"; done <<<"$out"
  fi
}
expect_out() {  # $1 = description, $2 = ERE the combined output must match, rest = command
  local desc=$1 want=$2; shift 2
  local out; out=$("$@" 2>&1) || true
  if grep -qE "$want" <<<"$out"; then
    echo "ok   $desc"; pass=$((pass+1))
  else
    echo "FAIL $desc (output did not match /$want/)"; fail=$((fail+1))
    while IFS= read -r l; do printf '       | %s\n' "$l"; done <<<"$out"
  fi
}
expect_out_not() {  # $1 = description, $2 = ERE the combined output must NOT match, rest = command
  local desc=$1 unwanted=$2; shift 2
  local out; out=$("$@" 2>&1) || true
  if grep -qE "$unwanted" <<<"$out"; then
    echo "FAIL $desc (output matched /$unwanted/)"; fail=$((fail+1))
    while IFS= read -r l; do printf '       | %s\n' "$l"; done <<<"$out"
  else
    echo "ok   $desc"; pass=$((pass+1))
  fi
}
hook_in_proj()  { printf '{"tool_name":"%s","tool_input":{"command":"%s"},"cwd":"%s"}' "${2:-Bash}" "$1" "$WORK/proj" | "$HOOK"; }
hook_out_repo() { printf '{"tool_input":{"command":"apex import"},"cwd":"/"}' | "$HOOK"; }

# --- wrapper protocol
expect "status before any syncpoint exits 0"                 0 "$CHK" status
expect "bootstrap: equal replicas -> PASS + first syncpoint" 0 "$CHK" check-import
sed 's/One/OneEditedInBuilder/' "$WORK/remote/demo/p30.apx" > "$WORK/remote/demo/p30.apx.new" \
  && mv "$WORK/remote/demo/p30.apx.new" "$WORK/remote/demo/p30.apx"
expect "builder moved -> check-import FAIL"                  1 "$CHK" check-import
cp "$WORK/remote/demo/p30.apx" src/demo/p30.apx && git add -A && git commit -qm "capture Builder changes"
expect "builder changes captured in LOCAL -> PASS"           0 "$CHK" check-import
expect "record-sync"                                         0 "$CHK" record-sync
# a page deleted in the Builder is a Builder-side change too: importing would
# recreate it. Exercises the comparator's "only in BASE" branch.
mv "$WORK/remote/demo/p30.apx" "$WORK/p30.apx.away"
expect "builder deleted a page -> check-import FAIL"         1 "$CHK" check-import
mv "$WORK/p30.apx.away" "$WORK/remote/demo/p30.apx"
expect "page restored -> PASS again"                         0 "$CHK" check-import
echo "-- local edit" >> src/demo/p30.apx
expect "dirty source dir -> check-export FAIL"               1 "$CHK" check-export
git checkout -q -- src/demo/p30.apx
expect "clean source dir -> check-export PASS"               0 "$CHK" check-export
expect "status runs"                                         0 "$CHK" status

# --- scratch hygiene and honest snapshots. The export/snapshot helpers used to run
# inside $(...): the scratch dirs they registered were lost with the subshell (every
# check leaked a full Builder export into TMPDIR), and errexit does not reach into a
# command substitution, so a failed git step still printed "syncpoint recorded".
count_scratch() { find "$WORK" -maxdepth 1 -name 'apex-sync-*' | wc -l | tr -d '[:space:]'; }
before=$(count_scratch)
"$CHK" check-import >/dev/null 2>&1 || true
expect "a PASS leaves no scratch export behind"              0 test "$(count_scratch)" = "$before"
cp "$WORK/remote/demo/p30.apx" "$WORK/p30.saved"
printf 'page 30 (\n  name: HygieneEdit\n)\n' > "$WORK/remote/demo/p30.apx"
before=$(count_scratch)
"$CHK" check-import >/dev/null 2>&1 || true
expect "a FAIL keeps exactly the Builder export it printed"  0 test "$(count_scratch)" = "$((before + 1))"
mv "$WORK/p30.saved" "$WORK/remote/demo/p30.apx"
"$CHK" check-import >/dev/null                         # back in sync: a fresh PASS for record-sync
mkdir -p "$WORK/gitfail"
# shellcheck disable=SC2016   # the stub's "$@" must reach the file unexpanded
printf '#!/usr/bin/env bash\nfor a in "$@"; do [[ "$a" == commit-tree ]] && { echo "fatal: simulated commit-tree failure" >&2; exit 128; }; done\nexec "%s" "$@"\n' \
  "$(command -v git)" > "$WORK/gitfail/git" && chmod +x "$WORK/gitfail/git"
# shellcheck disable=SC2030,SC2031   # the subshell-local PATH is the point
with_git_fail() { ( export PATH="$WORK/gitfail:$PATH"; "$@" ); }
ref_before=$(git rev-parse refs/apex-sync/demo)
expect         "a failed snapshot exits 3, not 0"            3 with_git_fail "$CHK" record-sync
expect_out_not "and is never reported as recorded"           'syncpoint recorded' with_git_fail "$CHK" record-sync
expect         "and the syncpoint ref is untouched"          0 test "$(git rev-parse refs/apex-sync/demo)" = "$ref_before"

# --- the marker is the hook's whole authorization, so it must only ever mean "the
# last check of this direction PASSed". It used to be written before the verdict was
# final and never withdrawn: a FAIL three minutes after a PASS left the PASS's marker
# fresh, and the hook let the import through.
MK="$WORK/proj/.git/apex-sync/demo"
"$CHK" check-import >/dev/null
expect "a PASS writes the import marker"                     0 test -f "$MK/check-ok.import"
last_line() { "$@" | tail -1; }
expect_out "the marker note is the last line of a PASS"      'marker: [^[:space:]]+check-ok\.import$' last_line "$CHK" check-import
cp "$WORK/remote/demo/p30.apx" "$WORK/p30.saved"
printf 'page 30 (\n  name: EditedAfterThePass\n)\n' > "$WORK/remote/demo/p30.apx"
expect "Builder moved after a PASS -> check-import FAIL"     1 "$CHK" check-import
expect "the FAIL withdrew the earlier PASS's marker"         1 test -f "$MK/check-ok.import"
expect "so the hook now blocks the import"                   2 hook_in_proj "apex import -input src/demo"
mv "$WORK/p30.saved" "$WORK/remote/demo/p30.apx"
"$CHK" check-export >/dev/null
echo "-- local edit" >> src/demo/p30.apx
expect "dirty tree after an export PASS -> check-export FAIL" 1 "$CHK" check-export
expect "the FAIL withdrew the export marker"                 1 test -f "$MK/check-ok.export"
git checkout -q -- src/demo/p30.apx
"$CHK" check-import >/dev/null
expect "an export that fails part-way -> exit 3 (UNKNOWN)"   3 env FAKE_EXPORT_FAIL=1 "$CHK" check-import
expect "and leaves no marker behind"                         1 test -f "$MK/check-ok.import"
cp "$MK/state.json" "$WORK/state.saved"
printf 'not json\n' > "$MK/state.json"
printf 'page 99 (\n  name: Payload\n)\n' > src/demo/p99.apx        # makes payload_report read state.json
expect     "a crash after the PASS line -> exit 3"           3 "$CHK" check-import
expect     "and no marker: the gate stays closed"            1 test -f "$MK/check-ok.import"
expect_out "the crash is named UNKNOWN, not PASS"            'reached PASS, then failed .* UNKNOWN' "$CHK" check-import
mv "$WORK/state.saved" "$MK/state.json"; rm -f src/demo/p99.apx
"$CHK" check-import >/dev/null

# --- record-sync rewrites BASE to whatever the Builder holds now. Run at the wrong
# moment — to "clear" a CONFLICT, or after an export that never happened — it
# launders Builder-only work into BASE: the next check-import PASSes and the import
# destroys that work. It now needs a basis that rules this out, or the user's --force.
ref_before=$(git rev-parse refs/apex-sync/demo)
cp "$WORK/remote/demo/p30.apx" "$WORK/p30.saved"
printf 'page 30 (\n  name: BuilderOnlyWork\n)\n' > "$WORK/remote/demo/p30.apx"
expect "Builder moved -> check-import CONFLICT"                 1 "$CHK" check-import
expect "record-sync to clear the CONFLICT -> BLOCKED"            2 "$CHK" record-sync
expect "and the syncpoint did not move"                          0 test "$(git rev-parse refs/apex-sync/demo)" = "$ref_before"
"$CHK" check-export >/dev/null
expect "a fresh EXPORT marker is no basis -> BLOCKED"            2 "$CHK" record-sync
printf '{"check":"import"}\n' > "$MK/check-ok.import" && touch -d '11 minutes ago' "$MK/check-ok.import"
expect "an import marker past the TTL is no basis -> BLOCKED"    2 "$CHK" record-sync
expect "--force is refused outside record-sync"                  2 "$CHK" check-import --force
expect     "record-sync --force records it anyway"               0 "$CHK" record-sync --force
expect_out "and state.json keeps the basis"                      '"basis":"forced"' cat "$MK/state.json"
expect_out "and status shows the forced syncpoint"               'FORCED by record-sync --force' "$CHK" status
mv "$WORK/p30.saved" "$WORK/remote/demo/p30.apx"
"$CHK" check-import >/dev/null && "$CHK" record-sync >/dev/null      # back to a clean syncpoint
rm -f "$MK/check-ok.import"
expect_out "no marker but Builder == BASE -> recorded"           'basis: +builder-unchanged' "$CHK" record-sync

# --- content comparison must not depend on git's content filters.
# `git diff --no-index` applies .gitattributes/core.autocrlf to whichever side git
# resolves inside the repo and not to the scratch export, so its verdict tracked the
# user's git config instead of the bytes. Comparison is byte-exact now; a difference
# that is only in line endings is reported apart and does not gate.
printf 'src/** text eol=lf\n' > .gitattributes
git add -A && git commit -qm "line-ending attributes"
sed 's/$/\r/' src/demo/p30.apx > "$WORK/remote/demo/p30.apx"          # same text, CRLF in the Builder
expect     "EOL-only difference -> check-import PASS"        0 "$CHK" check-import
expect_out "EOL-only difference is named, not silent"        'only in line endings' "$CHK" check-import
printf 'page 30 (\r\n  name: OneChangedInBuilder\r\n)\r\n' > "$WORK/remote/demo/p30.apx"
expect     "real change under CRLF still FAILs"              1 "$CHK" check-import
git rm -q --cached .gitattributes && rm -f .gitattributes
cp src/demo/p30.apx "$WORK/remote/demo/p30.apx"                       # restore the fixture
git commit -qm "drop line-ending attributes"
expect "replicas back in sync -> PASS"                       0 "$CHK" check-import

# --- JSON parser resolution. `command -v python3` succeeding does not mean python3
# runs: the Microsoft Store stub satisfies it and then exits without doing anything.
# Both scripts must probe by execution, and the hook must not open the gate when the
# probe finds nothing.
mkdir -p "$WORK/stub"
printf '#!/usr/bin/env bash\necho "Python was not found; run without arguments to install from the Microsoft Store" >&2\nexit 49\n' \
  > "$WORK/stub/python3" && chmod +x "$WORK/stub/python3"
cp "$WORK/stub/python3" "$WORK/stub/python"
cp "$WORK/stub/python3" "$WORK/stub/py"        # the Windows launcher: without it the
                                               # resolver finds a real python behind the stubs
printf '#!/usr/bin/env bash\nexit 127\n' > "$WORK/stub/jq" && chmod +x "$WORK/stub/jq"   # jq present but broken
mkdir -p "$WORK/nojq"
printf '#!/usr/bin/env bash\nexit 127\n' > "$WORK/nojq/jq" && chmod +x "$WORK/nojq/jq"
real_python=$(command -v python3 || true)
# shellcheck disable=SC2030,SC2031   # the subshell-local PATH is the point
with_stub_json() { ( export PATH="$WORK/stub:$PATH"; "$@" ); }   # no parser at all
# shellcheck disable=SC2030,SC2031
without_jq()     { ( export PATH="$WORK/nojq:$PATH"; "$@" ); }   # jq broken, real python behind it
# shellcheck disable=SC2030,SC2031
hook_no_json()   { ( export PATH="$WORK/stub:$PATH"; hook_in_proj "apex import" ); }

expect     "no working JSON parser -> check-import dies (exit 2)"  2 with_stub_json "$CHK" check-import
expect_out "the Microsoft Store stub is named in the error"        'Microsoft Store' with_stub_json "$CHK" check-import
rm -f "$WORK/proj/.git/apex-sync/demo/"check-ok.*
expect     "hook fails CLOSED without a JSON parser"               2 hook_no_json
"$CHK" check-import >/dev/null                       # restore the marker the hook section needs
if [[ -n "$real_python" ]]; then     # the python fallback path never runs in CI, where jq exists
  expect "python fallback works when jq is broken"                 0 without_jq "$CHK" status
fi

# --- deploy payload. A PASS says the import destroys nothing; it must also say what
# the import PUSHES, because `apex import` replaces the whole app with the LOCAL
# backlog accumulated since the syncpoint.
"$CHK" record-sync >/dev/null
expect_out "in sync -> payload says there is nothing to deploy" 'Nothing to deploy' "$CHK" check-import
printf 'page 31 (\n  name: Two\n)\n' > src/demo/p31.apx
printf 'application 100 (\n  name: Demo v2\n)\n' > src/demo/application.apx    # (no sed -i: BSD sed differs)
git add -A && git commit -qm "local work not yet imported"
expect_out "payload lists the files an import would deploy" 'A[[:space:]]+p31\.apx' "$CHK" check-import
expect_out "payload counts files and commits"              '2 file\(s\), 1 commit\(s\)' "$CHK" check-import
expect_out "payload warns the import replaces the whole app" 'replaces the WHOLE app' "$CHK" check-import
expect_out "status reports the payload too, without an export" 'A[[:space:]]+p31\.apx' "$CHK" status
# zero commits since the syncpoint (work not committed yet) must print "0", on one
# line: `git log | grep -c .` exits 1 on a zero count, which emitted count AND fallback.
"$CHK" record-sync >/dev/null
printf 'page 32 (\n  name: Three\n)\n' > src/demo/p32.apx
expect_out "payload prints a bare 0 when no commits followed the syncpoint" ', 0 commit\(s\)' "$CHK" check-import
rm -f src/demo/p32.apx
git rm -q src/demo/p31.apx && git checkout -q -- src/demo/application.apx
git commit -qm "back to the syncpoint"

# --- a JSON parser that emits CRLF (native tooling on Windows does) must not break
# ignorePaths: the entries are read line by line, so a trailing \r left the prefix
# match failing and the repo-only apex-exports/ showed up as a Builder-side deletion.
mkdir -p "$WORK/crlf"
printf '#!/usr/bin/env bash\nexit 127\n' > "$WORK/crlf/jq" && chmod +x "$WORK/crlf/jq"
printf '#!/usr/bin/env bash\ncommand %s "$@" | sed "s/$/\\r/"\n' "$(command -v python3)" \
  > "$WORK/crlf/python3" && chmod +x "$WORK/crlf/python3"
# shellcheck disable=SC2030,SC2031
with_crlf_json() { ( export PATH="$WORK/crlf:$PATH"; "$@" ); }
if [[ -n "$real_python" ]]; then
  expect "CRLF-emitting parser still honours ignorePaths"          0 with_crlf_json "$CHK" check-import
fi

# --- apex-sync.json is validated as a whole before anything trusts it, with one
# reading shared by jq and python. Read key by key, the two parsers disagreed: python
# iterated a string-valued ignorePaths character by character, so nearly every file
# was excluded from the comparison and the check PASSed without comparing anything.
CFG_FILE="$WORK/proj/apex-sync.json"
with_config() {  # $1 = the JSON to use for one command; the real config is always restored
  local saved rc=0; saved=$(cat "$CFG_FILE"); printf '%s\n' "$1" > "$CFG_FILE"; shift
  "$@" || rc=$?
  printf '%s\n' "$saved" > "$CFG_FILE"; return "$rc"
}
APPCFG='"appId": 100, "appAlias": "demo", "apexlangDir": "src", "sqlclConnection": "fake"'
expect "ignorePaths as a string -> BLOCKED (jq)"              2 with_config "{ $APPCFG, \"ignorePaths\": \"apex-exports/\" }" "$CHK" check-import
if [[ -n "$real_python" ]]; then
  expect "ignorePaths as a string -> BLOCKED (python)"        2 without_jq with_config "{ $APPCFG, \"ignorePaths\": \"apex-exports/\" }" "$CHK" check-import
fi
cp "$WORK/remote/demo/p30.apx" "$WORK/p30.saved"
printf 'page 30 (\n  name: HiddenByAPrefix\n)\n' > "$WORK/remote/demo/p30.apx"
expect "ignorePaths matches segments: \"p\" does not hide p30.apx" 1 with_config "{ $APPCFG, \"ignorePaths\": [\"p\"] }" "$CHK" check-import
mv "$WORK/p30.saved" "$WORK/remote/demo/p30.apx"
NODIR='{ "appId": 100, "appAlias": "demo", "apexlangDir": "nope", "sqlclConnection": "fake" }'
expect "a source dir that does not exist -> check-export BLOCKED (was PASS)" 2 with_config "$NODIR" "$CHK" check-export
expect "a source dir that does not exist -> check-import BLOCKED"            2 with_config "$NODIR" "$CHK" check-import
expect "a connect string as sqlclConnection -> BLOCKED"       2 with_config '{ "appId": 100, "appAlias": "demo", "apexlangDir": "src", "sqlclConnection": "scott/tiger@db" }' "$CHK" check-import
expect "a non-numeric appId -> BLOCKED"                       2 with_config '{ "appId": "abc", "appAlias": "demo", "apexlangDir": "src", "sqlclConnection": "fake" }' "$CHK" check-import
expect "an alias that is not a plain name -> BLOCKED"         2 with_config '{ "appId": 100, "appAlias": "../x", "apexlangDir": "src", "sqlclConnection": "fake" }' "$CHK" check-import
expect "apps[] next to a top-level appId -> BLOCKED"          2 with_config "{ $APPCFG, \"apps\": [] }" "$CHK" check-import
expect "an empty object -> BLOCKED"                           2 with_config '{}' "$CHK" check-import
expect_out "and every missing key is named at once"           'sqlclConnection is missing' with_config '{}' "$CHK" check-import
expect     "doctor on an invalid config -> exit 1, not a crash" 1 with_config '{}' "$CHK" doctor
expect_out "doctor lists the config errors"                   'FAIL +apex-sync.json: appAlias is missing' with_config '{}' "$CHK" doctor
mkdir -p src/demo/deployments && printf '{ "app": { "id": 999 } }\n' > src/demo/deployments/default.json
expect     "deployments/default.json names another app -> BLOCKED" 2 "$CHK" check-import
expect_out "and both ids are named"                           'says app 999, apex-sync.json says 100' "$CHK" check-import
rm -rf src/demo/deployments
"$CHK" check-import >/dev/null

# --- doctor: one command that validates a machine, probing by doing
expect     "doctor passes on a wired project"                      0 "$CHK" doctor
expect_out "doctor names the resolved JSON parser"                 'JSON parser \(probed by execution\)' "$CHK" doctor
expect     "doctor fails when the app is invisible to the connection" 1 \
           env FAKE_APP_COUNT=0 "$CHK" doctor
expect_out "doctor reports the platform"                           'bash .* on ' "$CHK" doctor

# --- the registered matcher. Every payload below is piped straight into the script,
# which bypasses Claude Code's own matcher dispatch entirely — so a matcher regression
# would pass this suite green. Assert it statically instead, in BOTH places it lives:
# hooks/hooks.json (plugin install) and setup.md (local-clone install) drift apart
# silently otherwise. PowerShell is a separate tool, not an alias of Bash, so a
# Bash-only matcher stops policing a Windows-native session without any symptom.
MATCHER='"matcher": "Bash|PowerShell"'
expect "matcher: hooks.json covers both shell tools"         0 grep -qF "$MATCHER" "$REPO/hooks/hooks.json"
expect "matcher: setup.md documents the same string"         0 grep -qF "$MATCHER" "$SKILL_DIR/setup.md"

# --- first publication into a workspace that has never held this app.
# There is no second replica, so the premise of the gate is absent and blocking
# would leave no way to populate the workspace at all — which is the shape of a
# fresh PROD deploy: create the workspace, then publish. The shortcut must be
# taken ONLY on a definitive answer: an unreadable count means "cannot tell",
# and treating that as "no app" would open the gate on failure.
# And only where no syncpoint exists: with one on record, "not visible" means a wrong
# connection, workspace or appId (or a deleted app), never a fresh workspace.
rm -f "$WORK/proj/.git/apex-sync/demo/"check-ok.*
expect     "app invisible but a syncpoint exists -> BLOCKED"  2 env FAKE_REMOTE_APP_COUNT=0 "$CHK" check-import
expect_out "and the reason names the syncpoint"               'has a syncpoint' env FAKE_REMOTE_APP_COUNT=0 "$CHK" check-import
expect     "and it writes no marker"                          1 test -f "$WORK/proj/.git/apex-sync/demo/check-ok.import"
saved_ref=$(git rev-parse refs/apex-sync/demo)               # the documented escape: set the syncpoint aside
git update-ref -d refs/apex-sync/demo
expect_out "check-import PASSes when the app is not in the workspace yet" \
  "does not exist in the target workspace" env FAKE_REMOTE_APP_COUNT=0 "$CHK" check-import
expect "and it writes the marker, so the publication is allowed" \
  0 hook_in_proj "apex import -input src/app"
git update-ref refs/apex-sync/demo "$saved_ref"

rm -f "$WORK/proj/.git/apex-sync/demo/"check-ok.*
expect_out "an unreadable count does NOT take the shortcut (fails closed)" \
  "Builder exported to scratch" env FAKE_REMOTE_APP_COUNT= "$CHK" check-import
"$CHK" check-import >/dev/null                       # restore the marker for the hook section

# --- enforcement hook
expect "hook: fresh marker allows apex import"               0 hook_in_proj "apex import -applicationid 100"
expect "hook: fresh marker allows it under PowerShell too"   0 hook_in_proj "apex import -applicationid 100" PowerShell
rm -f "$WORK/proj/.git/apex-sync/demo/"check-ok.*
expect "hook: no marker blocks apex import"                  2 hook_in_proj "apex import -applicationid 100"
# The verdict must come from the command TEXT, never from which shell tool asked:
# both tools carry the same tool_input.command, and the hook runs nothing of the
# caller's shell. That is what makes widening the matcher safe.
expect "hook: no marker blocks it under PowerShell too"      2 hook_in_proj "apex import -applicationid 100" PowerShell
expect "hook: no marker blocks apex export"                  2 hook_in_proj "sql <<< 'apex export -dir x'"
expect "hook: unrelated command passes"                      0 hook_in_proj "ls -la"

# --- mentioning the subcommand is not invoking it. These five all used to be
# blocked, because the matcher looked for the bare phrase anywhere in the
# command text. That made ordinary work impossible while the guard was on: a
# grep whose PATTERN contains the phrase, a commit message that explains what
# the guard does, and — the one that forced the change — editing the guard's own
# source. A gate that obstructs reading itself is a gate people disable.
# The rule now is that a flag the subcommand cannot run without must also be
# present, which every real invocation carries.
expect "hook: a grep whose pattern mentions it passes"       0 hook_in_proj "grep -n 'apex export' file.sh"
expect "hook: a commit message that mentions it passes"      0 hook_in_proj "git commit -m 'why apex import clobbers the replica'"
expect "hook: reading the guard source passes"               0 hook_in_proj "sed -n '1,40p' apex-sync-check.sh"

# The flag is searched for anywhere in the command, not right after the
# subcommand: grep is line-based, so a heredoc that puts the flag on the next
# line would otherwise slip through the narrowed matcher.
expect "hook: flag on the next line of a heredoc still blocks" 2 hook_in_proj "sql <<EOF\napex import -input src/app\nEOF"
expect "hook: outside an onboarded repo passes"              0 hook_out_repo

# --- Oracle's 26.1 apexlang-generation routes its import through apexctl, which runs
# `apex import` inside a SQLcl subprocess — the literal string never appears in the
# command the hook sees, so matching only that string stopped catching real imports.
RT='node tools/apexctl.mjs runtime roundtrip --app-path /a --db-connection-name c --import-intent validate-and-import'
expect "hook: apexctl roundtrip blocked without a marker"    2 hook_in_proj "$RT"
# The default intent is validate-only; blocking the bare roundtrip anyway is deliberate.
expect "hook: bare roundtrip (default validate-only) still blocked" 2 hook_in_proj "node tools/apexctl.mjs runtime roundtrip --app-path /a --db-connection-name c"
"$CHK" check-import >/dev/null
expect "hook: apexctl roundtrip allowed with a fresh marker" 0 hook_in_proj "$RT"
expect "hook: offline apexctl validate passes"               0 hook_in_proj "node tools/apexctl.mjs apexlang validate --app-path /a"

# --- every other import lane. A payload is built with real JSON escaping here, so
# commands can carry quotes and real newlines.
json_esc() { local s=$1; s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; s=${s//$'\t'/\\t}; s=${s//$'\r'/\\r}; printf '%s' "$s"; }
hook_at()  { printf '{"tool_name":"%s","tool_input":{"command":"%s"},"cwd":"%s"}' "${3:-Bash}" "$(json_esc "$2")" "$(json_esc "$1")" | "$HOOK"; }
hook_cmd() { hook_at "$WORK/proj" "$@"; }
rm -f "$MK"/check-ok.*
# Oracle's apexlang-deploy (26.1/26.2) runs `apex import` inside its own heredoc: the
# phrase never reaches the hook. Naming the script is an import unless every segment
# of the command is a plain reader.
DEPLOY='SQLCL_BIN=/opt/sqlcl/bin/sql SQLCL_CONNECTION_STRING=x bash /o/apexlang-deploy/scripts/deploy-apex-app.sh src/demo'
expect "hook: Oracle deploy script blocked without a marker"   2 hook_cmd "$DEPLOY"
expect "hook: deploy via a quoted path with spaces blocked"    2 hook_cmd 'bash "/my dir/deploy-apex-app.sh" "src/demo"'
expect "hook: deploy via bash -c blocked"                      2 hook_cmd 'bash -c "deploy-apex-app.sh src/demo"'
expect "hook: deploy from PowerShell blocked"                  2 hook_cmd "& 'C:\\o\\deploy-apex-app.sh' src/demo" PowerShell
expect "hook: deploy piped into a shell blocked"               2 hook_cmd 'cat deploy-apex-app.sh | bash -s src/demo'
expect "hook: deploy inside an if blocked"                     2 hook_cmd 'if ./deploy-apex-app.sh src/demo; then echo ok; fi'
expect "hook: reading the deploy script passes (cat)"          0 hook_cmd 'cat skills/x/deploy-apex-app.sh'
expect "hook: reading the deploy script passes (grep | head)"  0 hook_cmd "grep -n 'apex import' deploy-apex-app.sh | head -5"
expect "hook: reading the deploy script passes (sed)"          0 hook_cmd "sed -n '1,40p' deploy-apex-app.sh"
expect "hook: linting the deploy script passes"                0 hook_cmd 'shellcheck deploy-apex-app.sh'
expect "hook: Oracle's compile script is never gated"          0 hook_cmd 'bash /o/apexlang-compile/scripts/validate-apex-app.sh src/demo'
# A bare `apex import` imports the current directory: with a SQLcl launcher in the
# command it is a real import even without a flag.
expect "hook: bare apex import fed to sql blocked"             2 hook_cmd 'sql -name fake <<< "apex import"'
expect "hook: bare apex import piped to sql blocked"           2 hook_cmd 'echo "apex import" | sql /nolog'
expect "hook: \$SQLCL_BIN heredoc import blocked"              2 hook_cmd $'"$SQLCL_BIN" "$C" <<EOF\napex import\nEOF'
expect "hook: apex export-application blocked"                 2 hook_cmd 'sql -name fake <<< "apex export-application -api 100"'
expect "hook: --runtime-action validate-and-import blocked"    2 hook_cmd 'node tools/apexctl.mjs runtime --runtime-action validate-and-import'
"$CHK" check-import >/dev/null
expect "hook: the deploy script allowed with a fresh marker"   0 hook_cmd "$DEPLOY"

# --- an agent must not overrule the guard: forcing a syncpoint and writing the
# guard's own markers/refs/state are refused even with a fresh marker.
expect "hook: record-sync --force refused"                     2 hook_cmd 'skills/apex-sync-guard/scripts/apex-sync-check.sh record-sync --force'
expect "hook: touching a marker refused"                       2 hook_cmd 'touch .git/apex-sync/demo/check-ok.import'
expect "hook: writing a marker by redirection refused"         2 hook_cmd 'echo {} > .git/apex-sync/demo/check-ok.import'
expect "hook: deleting the syncpoint ref refused"              2 hook_cmd 'git update-ref -d refs/apex-sync/demo'
expect "hook: reading a marker passes"                         0 hook_cmd 'cat .git/apex-sync/demo/check-ok.import'
expect "hook: removing a marker passes (it only withdraws)"    0 hook_cmd 'rm -f .git/apex-sync/demo/check-ok.export'
expect "hook: running the check itself passes"                 0 hook_cmd 'skills/apex-sync-guard/scripts/apex-sync-check.sh check-import'

# --- the hook fails closed once a command is relevant: an onboarded repo it cannot
# read, a config it cannot parse, a marker age it cannot compute — all block.
expect "hook: config {} blocks an import"                      2 with_config '{}' hook_cmd 'apex import -input src/demo'
expect "hook: apps that is not an array blocks"                2 with_config '{ "apps": "x" }' hook_cmd 'apex import -input src/demo'
mkdir -p "$WORK/notgit" && printf '{ "appId": 1, "appAlias": "x" }\n' > "$WORK/notgit/apex-sync.json"
expect "hook: apex-sync.json where git cannot resolve a repo blocks" 2 hook_at "$WORK/notgit" 'apex import -input src/demo'
mkdir -p "$WORK/badgit"
printf '#!/usr/bin/env bash\necho "fatal: detected dubious ownership" >&2\nexit 128\n' > "$WORK/badgit/git" && chmod +x "$WORK/badgit/git"
# shellcheck disable=SC2030,SC2031
with_bad_git() { ( export PATH="$WORK/badgit:$PATH"; "$@" ); }
expect "hook: an onboarded repo git refuses blocks"            2 with_bad_git hook_cmd 'apex import -input src/demo'
mkdir -p "$WORK/badstat"
printf '#!/usr/bin/env bash\necho garbage\n' > "$WORK/badstat/stat" && chmod +x "$WORK/badstat/stat"
# shellcheck disable=SC2030,SC2031
with_bad_stat() { ( export PATH="$WORK/badstat:$PATH"; "$@" ); }
expect "hook: a marker age that cannot be computed blocks"     2 with_bad_stat hook_cmd 'apex import -input src/demo'
rm -f "$MK"/check-ok.*
# shellcheck disable=SC2030,SC2031
deploy_no_json() { ( export PATH="$WORK/stub:$PATH"; hook_cmd 'cat deploy-apex-app.sh' ); }
expect "hook: without a JSON parser even a read of the deploy script blocks" 2 deploy_no_json

# --- setup.md §4 is how a user proves the wiring on a real install. Its commands
# must be the ones written there AND must trip the hook as its table says: a smoke
# command the hook lets through "passes" on a broken install. (`echo "apex export"`
# was that command once the bare mention stopped counting as an export.)
SMOKE_EXPORT='echo "apex export -applicationid 1"'
SMOKE_IMPORT='echo "apex import -input x"'
expect "setup.md §4 documents the export smoke command"         0 grep -qF "$SMOKE_EXPORT" "$SKILL_DIR/setup.md"
expect "setup.md §4 documents the import smoke command"         0 grep -qF "$SMOKE_IMPORT" "$SKILL_DIR/setup.md"
rm -f "$MK"/check-ok.*
expect "setup.md §4 row 1: no marker -> blocked"                2 hook_cmd "$SMOKE_EXPORT"
"$CHK" check-export >/dev/null
expect "setup.md §4 row 2: fresh export marker -> allowed"      0 hook_cmd "$SMOKE_EXPORT"
touch -d '11 minutes ago' "$MK/check-ok.export"
expect "setup.md §4 row 3: marker past the TTL -> blocked"      2 hook_cmd "$SMOKE_EXPORT"
"$CHK" check-export >/dev/null
expect "setup.md §4 row 4: export marker only, import -> blocked" 2 hook_cmd "$SMOKE_IMPORT"
expect "and the bare mention it warns against is not an export" 0 hook_cmd 'echo "apex export"'

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
