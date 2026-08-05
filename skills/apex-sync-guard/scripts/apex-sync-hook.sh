#!/usr/bin/env bash
# apex-sync-guard — Claude Code PreToolUse hook (matcher: Bash).
# Blocks `apex import` / `apex export` unless a fresh matching sync-check
# PASS marker exists (TTL 10 min). Direction-aware: an import needs a
# check-import PASS, an export needs a check-export PASS.
# Exit 0 = allow, exit 2 = block (stderr goes back to the agent).
set -uo pipefail

TTL=600

mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }   # GNU stat / BSD (macOS) stat

# Resolved by EXECUTION, not by `command -v`: the Microsoft Store `python3` stub
# satisfies presence checks and then exits without running. Deliberately duplicated
# from apex-sync-check.sh — a hook must stay self-contained; it may be registered by
# absolute path or symlink, with no readable sibling to source.
JSON_TOOL=()
if command -v jq >/dev/null 2>&1 && printf '{}' | jq -e . >/dev/null 2>&1; then
  JSON_TOOL=(jq)
else
  for _c in "python3" "python" "py -3"; do
    read -ra _cand <<<"$_c"
    command -v "${_cand[0]}" >/dev/null 2>&1 || continue
    if "${_cand[@]}" -c 'import json' >/dev/null 2>&1; then JSON_TOOL=("${_cand[@]}"); break; fi
  done
fi

json_get() {  # $1 = json file ('-' = stdin), $2 = dotted key path; 1 = no parser
  [[ ${#JSON_TOOL[@]} -gt 0 ]] || return 1
  if [[ "${JSON_TOOL[0]}" == "jq" ]]; then
    jq -r ".$2 // empty" "$1" 2>/dev/null
  else
    "${JSON_TOOL[@]}" -c '
import json, sys
src = sys.stdin if sys.argv[1] == "-" else open(sys.argv[1])
data = json.load(src)
for k in sys.argv[2].split("."):
    data = data.get(k) if isinstance(data, dict) else None
    if data is None: break
print("" if data is None else data)' "$1" "$2" 2>/dev/null
  fi
}

raw_get() {  # $1 = field name — flat string extraction when there is no parser at all
  sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\(\([^"\]\|\\.\)*\)".*/\1/p' <<<"$input" | head -1
}

input=$(cat)
DEGRADED=0
if cmd=$(printf '%s' "$input" | json_get - tool_input.command); then
  [[ -z "$cmd" ]] && exit 0
else
  # No usable JSON parser. A guard that cannot read its input must not therefore
  # wave the call through — that is exactly how an unchecked import gets in.
  DEGRADED=1
  cmd=$(raw_get command)
  [[ -z "$cmd" ]] && cmd=$input          # scan the whole payload rather than allow blindly
fi

# What counts as an import, by the text of the command:
#   * SQLcl directly — `apex import`.
#   * The APEXlang package's canonical lane (2026.08.01 runtime-gates §9) —
#     `apexctl … runtime roundtrip`, which builds a SQLcl script containing
#     `apex import -input …` and runs it in a subprocess. The literal string never
#     reaches this hook, so matching only it stopped catching real imports.
#     Gated whatever the --import-intent says: the flag defaults to importing, and
#     one extra 20 s check-import is the cheap side of this trade.
needs=()
if grep -qiE 'apex[[:space:]]+import' <<<"$cmd" \
   || grep -qiE 'apexctl[^;|&]*runtime[[:space:]]+roundtrip' <<<"$cmd" \
   || grep -qiE 'import-intent[[:space:]=]+validate-and-import' <<<"$cmd"; then
  needs+=(import)
fi
grep -qiE 'apex[[:space:]]+export' <<<"$cmd" && needs+=(export)
[[ ${#needs[@]} -eq 0 ]] && exit 0

if (( DEGRADED )); then cwd=$(raw_get cwd); else cwd=$(printf '%s' "$input" | json_get - cwd); fi
ROOT=$(git -C "${cwd:-.}" rev-parse --show-toplevel 2>/dev/null) || exit 0  # not a repo → not ours to police
CFG="$ROOT/apex-sync.json"
[[ -f "$CFG" ]] || exit 0                                                   # project not onboarded → allow
ALIAS=$(json_get "$CFG" appAlias) || ALIAS=""
[[ -z "$ALIAS" ]] && ALIAS=$(sed -n 's/.*"appAlias"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CFG" | head -1)
[[ -z "$ALIAS" ]] && exit 0

now=$(date +%s)
for d in "${needs[@]}"; do
  m="$ROOT/.git/apex-sync/$ALIAS/check-ok.$d"
  if [[ ! -f "$m" ]] || (( now - $(mtime "$m") >= TTL )); then
    echo "apex-sync-guard: BLOCKED apex $d — no check-$d PASS in the last $((TTL/60)) min for app '$ALIAS'." >&2
    echo "Run first (from the repo root): <apex-sync-guard skill dir>/scripts/apex-sync-check.sh check-$d" >&2
    echo "Then retry. Rationale: the $d would silently overwrite the other replica (skill: apex-sync-guard)." >&2
    (( DEGRADED )) && echo "(No working jq/python was found, so this decision was made by scanning the raw tool payload.)" >&2
    exit 2
  fi
done
exit 0
