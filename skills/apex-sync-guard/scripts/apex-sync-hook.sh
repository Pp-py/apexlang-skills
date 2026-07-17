#!/usr/bin/env bash
# apex-sync-guard — Claude Code PreToolUse hook (matcher: Bash).
# Blocks `apex import` / `apex export` unless a fresh matching sync-check
# PASS marker exists (TTL 10 min). Direction-aware: an import needs a
# check-import PASS, an export needs a check-export PASS.
# Exit 0 = allow, exit 2 = block (stderr goes back to the agent).
set -uo pipefail

TTL=600

mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }   # GNU stat / BSD (macOS) stat

json_get() {  # $1 = json file ('-' = stdin), $2 = dotted key path
  if command -v jq >/dev/null; then
    jq -r ".$2 // empty" "$1" 2>/dev/null
  else
    python3 -c '
import json, sys
src = sys.stdin if sys.argv[1] == "-" else open(sys.argv[1])
data = json.load(src)
for k in sys.argv[2].split("."):
    data = data.get(k) if isinstance(data, dict) else None
    if data is None: break
print("" if data is None else data)' "$1" "$2" 2>/dev/null
  fi
}

input=$(cat)
cmd=$(printf '%s' "$input" | json_get - tool_input.command) || exit 0
[[ -z "$cmd" ]] && exit 0

needs=()
grep -qiE 'apex[[:space:]]+import' <<<"$cmd" && needs+=(import)
grep -qiE 'apex[[:space:]]+export' <<<"$cmd" && needs+=(export)
[[ ${#needs[@]} -eq 0 ]] && exit 0

cwd=$(printf '%s' "$input" | json_get - cwd)
ROOT=$(git -C "${cwd:-.}" rev-parse --show-toplevel 2>/dev/null) || exit 0  # not a repo → not ours to police
CFG="$ROOT/apex-sync.json"
[[ -f "$CFG" ]] || exit 0                                                   # project not onboarded → allow
ALIAS=$(json_get "$CFG" appAlias)
[[ -z "$ALIAS" ]] && exit 0

now=$(date +%s)
for d in "${needs[@]}"; do
  m="$ROOT/.git/apex-sync/$ALIAS/check-ok.$d"
  if [[ ! -f "$m" ]] || (( now - $(mtime "$m") >= TTL )); then
    echo "apex-sync-guard: BLOCKED apex $d — no check-$d PASS in the last $((TTL/60)) min for app '$ALIAS'." >&2
    echo "Run first (from the repo root): <apex-sync-guard skill dir>/scripts/apex-sync-check.sh check-$d" >&2
    echo "Then retry. Rationale: the $d would silently overwrite the other replica (skill: apex-sync-guard)." >&2
    exit 2
  fi
done
exit 0
