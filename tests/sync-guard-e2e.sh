#!/usr/bin/env bash
# E2E harness for apex-sync-guard: exercises the full protocol offline.
# A stubbed SQLcl answers `apex export` by copying from a fixture "remote"
# dir (the fake Builder), so no database or real SQLcl is needed.
set -euo pipefail

SKILL_DIR=$(cd "$(dirname "$0")/../skills/apex-sync-guard" && pwd)
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
  if grep -q -- '-dir "' <<<"$stmts"; then          # the guard quotes paths holding spaces
    dir=$(sed -n 's/.*-dir "\([^"]*\)".*/\1/p' <<<"$stmts")
  else
    dir=$(sed -n 's/.*-dir \([^ ]*\).*/\1/p' <<<"$stmts")
  fi
  mkdir -p "$dir/demo" && cp -r "$FAKE_REMOTE/demo/." "$dir/demo/"
elif grep -q 'greatest' <<<"$stmts"; then
  echo "2026-07-17T10:00:00"
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
  local got=0; "$@" >/dev/null 2>&1 || got=$?
  if [[ "$got" == "$want" ]]; then
    echo "ok   $desc"; pass=$((pass+1))
  else
    echo "FAIL $desc (exit $got, wanted $want)"; fail=$((fail+1))
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
hook_in_proj()  { printf '{"tool_input":{"command":"%s"},"cwd":"%s"}' "$1" "$WORK/proj" | "$HOOK"; }
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

# --- doctor: one command that validates a machine, probing by doing
expect     "doctor passes on a wired project"                      0 "$CHK" doctor
expect_out "doctor names the resolved JSON parser"                 'JSON parser \(probed by execution\)' "$CHK" doctor
expect     "doctor fails when the app is invisible to the connection" 1 \
           env FAKE_APP_COUNT=0 "$CHK" doctor
expect_out "doctor reports the platform"                           'bash .* on ' "$CHK" doctor

# --- enforcement hook
expect "hook: fresh marker allows apex import"               0 hook_in_proj "apex import -applicationid 100"
rm -f "$WORK/proj/.git/apex-sync/demo/"check-ok.*
expect "hook: no marker blocks apex import"                  2 hook_in_proj "apex import -applicationid 100"
expect "hook: no marker blocks apex export"                  2 hook_in_proj "sql <<< 'apex export -dir x'"
expect "hook: unrelated command passes"                      0 hook_in_proj "ls -la"
expect "hook: outside an onboarded repo passes"              0 hook_out_repo

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
