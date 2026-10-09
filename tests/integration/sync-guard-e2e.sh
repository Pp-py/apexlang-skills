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

# --- APEXlang 2026.08.01 routes the canonical import through apexctl, which runs
# `apex import` inside a SQLcl subprocess — the literal string never appears in the
# command the hook sees, so matching only that string stopped catching real imports.
RT='node tools/apexctl.mjs runtime roundtrip --app-path /a --db-connection-name c --import-intent validate-and-import'
expect "hook: apexctl roundtrip blocked without a marker"    2 hook_in_proj "$RT"
expect "hook: bare roundtrip (default intent) blocked"       2 hook_in_proj "node tools/apexctl.mjs runtime roundtrip --app-path /a --db-connection-name c"
"$CHK" check-import >/dev/null
expect "hook: apexctl roundtrip allowed with a fresh marker" 0 hook_in_proj "$RT"
expect "hook: offline apexctl validate passes"               0 hook_in_proj "node tools/apexctl.mjs apexlang validate --app-path /a"

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
