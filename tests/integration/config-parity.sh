#!/usr/bin/env bash
# apex-sync.json has two readers: apex-sync-guard's (lib/sync-config.sh, behind
# `apex-sync-check.sh apps` and the hook) and apex-sentinel's (pw.sh — its own, so
# that skill works alone). If they drift, the guard checks one app while sentinel
# logs into another. Both are held to the same fixtures (fixtures/config/), under jq
# and under python, since each script falls back from one to the other:
#   valid-*.json    both resolve them; <name>.apps is the check's view, and pw.sh
#                   must agree on alias, testUser and runtimeUrl
#   invalid-*.json  both refuse them (exit 2)
#   *.json + .pw    pw.sh-only: a file sentinel reads but the guard rightly refuses
#                   (no appId/connection) — the one divergence, on purpose
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
CHK="$REPO/skills/apex-sync-guard/scripts/apex-sync-check.sh"
PW="$REPO/skills/apex-sentinel/scripts/pw.sh"
FIX="$REPO/tests/integration/fixtures/config"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/config-parity-XXXXXX")
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/proj" "$WORK/nojq"
git -C "$WORK/proj" init -q
printf '#!/usr/bin/env bash\nexit 127\n' > "$WORK/nojq/jq" && chmod +x "$WORK/nojq/jq"   # jq present but broken

pass=0; fail=0
ok()  { echo "ok   $1"; pass=$((pass + 1)); }
bad() {
  local l
  echo "FAIL $1"; fail=$((fail + 1))
  [[ -n "${2:-}" ]] && while IFS= read -r l; do printf '       | %s\n' "$l"; done <<<"$2"
  return 0
}

# shellcheck disable=SC2030,SC2031   # the subshell-local PATH is the point
in_proj() {  # $1 = jq|python, rest = command → stdout+stderr; exit code preserved
  local how=$1; shift
  ( cd "$WORK/proj"
    [[ "$how" == python ]] && export PATH="$WORK/nojq:$PATH"
    "$@" ) 2>&1
}

PARSERS=()   # each leg needs its parser; a leg that cannot run is named, never passed
if command -v jq >/dev/null 2>&1 && jq -e . <<<'{}' >/dev/null 2>&1; then PARSERS+=(jq); else echo "skip the jq leg (no jq)"; fi
if python3 -c 'import json' >/dev/null 2>&1; then PARSERS+=(python); else echo "skip the python leg (no python3)"; fi
(( ${#PARSERS[@]} )) || { echo "config-parity: BLOCKED — neither jq nor python3 runs" >&2; exit 2; }

for f in "$FIX"/*.json; do
  name=$(basename "$f" .json)
  cp "$f" "$WORK/proj/apex-sync.json"
  for how in "${PARSERS[@]}"; do
    rc=0; out=$(in_proj "$how" "$CHK" apps) || rc=$?
    prc=0; pout=$(in_proj "$how" "$PW" apps) || prc=$?
    case "$name" in
      valid-*)
        want=$(cat "$FIX/$name.apps")
        if (( rc == 0 )) && [[ "$out" == "$want" ]]; then ok "$name ($how): the check resolves it as expected"
        else bad "$name ($how): the check (exit $rc) disagrees with $name.apps" "$out"; fi
        want=$(cut -f1,5,6 <<<"$want")
        if (( prc == 0 )) && [[ "$pout" == "$want" ]]; then ok "$name ($how): pw.sh agrees on alias, testUser, runtimeUrl"
        else bad "$name ($how): pw.sh (exit $prc) disagrees with the check" "$pout"; fi ;;
      invalid-*)
        if (( rc == 2 )); then ok "$name ($how): the check refuses it"
        else bad "$name ($how): the check accepted it (exit $rc)" "$out"; fi
        if (( prc == 2 )); then ok "$name ($how): pw.sh refuses it too"
        else bad "$name ($how): pw.sh accepted it (exit $prc)" "$pout"; fi ;;
      *)
        if (( rc == 2 )); then ok "$name ($how): the check refuses it (it guards no app)"
        else bad "$name ($how): the check accepted it (exit $rc)" "$out"; fi
        if (( prc == 0 )) && [[ "$pout" == "$(cat "$FIX/$name.pw")" ]]; then ok "$name ($how): pw.sh still reads it"
        else bad "$name ($how): pw.sh (exit $prc) does not read it as $name.pw says" "$pout"; fi ;;
    esac
  done
done

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
