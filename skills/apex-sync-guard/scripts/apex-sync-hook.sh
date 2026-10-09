#!/usr/bin/env bash
# apex-sync-guard — Claude Code PreToolUse hook (matcher: Bash|PowerShell).
# Shell-agnostic by design: it reads tool_input.command — the field BOTH shell
# tools carry — and decides by matching that text. Nothing from the caller's
# shell is ever executed here, which is what makes covering a second tool a
# matcher change and not a rewrite.
#
# Blocks an import or export (in any of the lanes below) unless a fresh matching
# check PASS marker exists (TTL 10 min). Direction-aware: an import needs a
# check-import PASS, an export needs a check-export PASS. It also refuses the
# commands that would let an agent overrule the guard: record-sync --force and
# writes to the guard's own markers, refs and state.
#
# Exit 0 = allow, exit 2 = block (stderr goes back to the agent). Claude Code
# blocks ONLY on exit 2 — any other exit lets the command run — so once a command
# looks relevant, every unplanned exit is turned into a block (on_exit, below).
set -uo pipefail

TTL=600   # seconds a check PASS authorizes; must equal TTL_SECONDS in apex-sync-check.sh
# Same pattern as apex-sync-check.sh (a contract test asserts it): an alias names
# a directory under .git/apex-sync/, so anything looser is a path to somewhere else.
RE_APP_ALIAS='^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$'

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

# Native tooling on Windows writes CRLF, and a trailing \r survives command
# substitution — it would break the repo lookup and the pattern match below.
strip_cr() { tr -d '\r'; }

json_get() {  # $1 = json file ('-' = stdin), $2 = dotted key path; 1 = no parser
  [[ ${#JSON_TOOL[@]} -gt 0 ]] || return 1
  if [[ "${JSON_TOOL[0]}" == "jq" ]]; then
    jq -r ".$2 // empty" "$1" 2>/dev/null | strip_cr
  else
    "${JSON_TOOL[@]}" -c '
import json, sys
src = sys.stdin if sys.argv[1] == "-" else open(sys.argv[1])
data = json.load(src)
for k in sys.argv[2].split("."):
    data = data.get(k) if isinstance(data, dict) else None
    if data is None: break
print("" if data is None else data)' "$1" "$2" 2>/dev/null | strip_cr
  fi
}

raw_get() {  # $1 = field name — flat string extraction when there is no parser at all
  sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\(\([^"\]\|\\.\)*\)".*/\1/p' <<<"$input" | head -1 | strip_cr
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

# Cheap prefilter: nothing this hook polices can be written without one of these.
# Everything else (the vast majority of commands) is allowed untouched.
shopt -s nocasematch
[[ "$cmd" == *apex* || "$cmd" == *check-ok* ]] || exit 0
shopt -u nocasematch

# From here on the command is relevant, and a crash of this script must block.
# shellcheck disable=SC2317   # invoked by the EXIT trap
on_exit() {
  local rc=$?
  if (( rc != 0 && rc != 2 )); then
    echo "apex-sync-guard: BLOCKED — the guard itself failed (exit $rc) while checking this command; blocking to stay safe." >&2
    echo "Run: <apex-sync-guard skill dir>/scripts/apex-sync-check.sh doctor" >&2
    exit 2
  fi
}
trap on_exit EXIT

block() {  # never echoes the command: it may carry a connection string with a password
  echo "apex-sync-guard: BLOCKED — $*" >&2
  (( DEGRADED )) && echo "(No working jq/python was found, so this decision was made by scanning the raw tool payload.)" >&2
  exit 2
}

# Case-insensitive ERE match against the command text. grep exits 2 when a pattern
# is rejected (an older regex engine); that must read as a match — block — never
# as "no match", which would allow.
rx() {
  local rc=0
  grep -qiE -- "$1" <<<"$cmd" || rc=$?
  (( rc == 2 )) && return 0
  return "$rc"
}

# ---------------------------------------------------------------- lanes
# A SQLcl launcher anywhere in the command: `sql`, `sql.exe`, `sql.bat`, `sqlcl`
# as a word, or $SQLCL_BIN (how Oracle's scripts name it).
SQLCL_LAUNCHER='(^|[;&|(`[:space:]/\\])(sql|sql\.exe|sql\.bat|sqlcl)["'"'"']?([[:space:]]|$)|\$\{?SQLCL_BIN\}?'

# A subcommand only counts as an invocation when a flag it runs with is present,
# or when a SQLcl launcher is. Matching the bare phrase blocked commands that merely
# MENTIONED it: a grep pattern, a `git commit -m` message — and editing this very
# file. A guard that obstructs reading its own source is a guard people switch off.
# The launcher alternative closes the opposite hole: a bare `apex import` with no
# flag imports the CURRENT DIRECTORY (SQLcl's own help), so `sql -name dev <<<
# "apex import"` is a real import with no flag in it.
#
# The flag is looked for anywhere in the command, not right after the subcommand,
# so a heredoc that puts it on the next line still counts (grep is line-based).
apex_subcommand() {  # $1 = import|export ; $2… = the flags that make it real
  local sub="$1"; shift
  local flags; flags=$(IFS='|'; echo "$*")
  # The subcommand ends at any non-word character: `<<< "apex import"` ends in a quote.
  case "$sub" in
    import) rx "apex[[:space:]]+import([^[:alnum:]_-]|$)" || return 1 ;;
    # export-application, export-components, … are exports too
    export) rx "apex[[:space:]]+export(-[[:alpha:]-]+)?([^[:alnum:]_-]|$)" || return 1 ;;
  esac
  # DEGRADED means no JSON parser was found and `$cmd` is the raw payload (or a
  # regex-scraped guess at it), so there is no telling what is a command and
  # what is incidental text: suspicion beats precision, the bare phrase is enough.
  (( DEGRADED )) && return 0
  rx "(^|[[:space:]])($flags)([[:space:]=]|$)" || rx "$SQLCL_LAUNCHER"
}

# Oracle's apexlang-deploy (26.1 and 26.2) imports through a script: the literal
# `apex import` lives in its heredoc and never reaches this hook. Any command that
# names the script is an import UNLESS every one of its segments starts with a
# plain reader — so `cat`/`grep`/`sed` of the script pass, while `bash … x`,
# `cd d && ./deploy-apex-app.sh x`, `if ./deploy-apex-app.sh …`, `cat … | bash -s`
# and `& 'C:\…\deploy-apex-app.sh'` (PowerShell) all count.
# One command segment per line: every separator becomes a newline (sets of equal
# length on purpose — BSD tr does not pad the second set).
# shellcheck disable=SC2020
segments() { printf '%s\n' "$cmd" | tr ';&|`(){}' '\n\n\n\n\n\n\n\n'; }
READERS='cat|less|more|head|tail|grep|egrep|fgrep|rg|ag|sed|awk|wc|ls|file|stat|shellcheck|git|echo|printf|cd|pushd|popd|diff|cmp|sha256sum|shasum|md5sum|sort|uniq|cut|tr|nl|bat|code|vi|vim|nano|get-content|gc|select-string|sls|type'
deploy_invoked() {
  rx 'deploy-apex-app\.sh' || return 1
  (( DEGRADED )) && return 0
  local seg first assign='^[A-Za-z_][A-Za-z0-9_]*=("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:]]*)[[:space:]]+(.*)$'
  while IFS= read -r seg; do
    seg=${seg#"${seg%%[![:space:]]*}"}
    [[ -z "$seg" ]] && continue
    while [[ "$seg" =~ $assign ]]; do seg=${BASH_REMATCH[2]}; done   # VAR=value prefixes
    first=${seg%%[[:space:]]*}
    first=${first##*/}                                                 # /usr/bin/cat
    first=$(printf '%s' "$first" | tr '[:upper:]' '[:lower:]')
    [[ "$first" =~ ^($READERS)$ ]] || return 0
  done < <(segments)
  return 1
}

needs=()
if apex_subcommand import -input -id -applicationid -alias \
   || rx 'apexctl[^;|&]*runtime[[:space:]]+roundtrip' \
   || rx '(import-intent|runtime-action)[[:space:]=]+validate-and-import' \
   || deploy_invoked; then
  # `runtime roundtrip` is gated whatever --import-intent says. Its default is
  # validate-only (apexctl.mjs), so a bare roundtrip is over-blocked on purpose:
  # one 20 s check-import is cheaper than trusting our reading of an upstream default.
  needs+=(import)
fi
apex_subcommand export -applicationid -api -dir -exptype -expcomponents -id -split -woi -workspaceid \
  && needs+=(export)

# Commands that would let an agent overrule the guard. They are refused even with a
# fresh marker: forcing a syncpoint, or writing the markers/refs/state the guard
# reads, is the user's decision.
guard_override=""
if rx 'apex-sync-check(\.sh)?[^;&|]*record-sync' && rx '(^|[[:space:]])--force([[:space:]=]|$)'; then
  guard_override="record-sync --force records the Builder as BASE without any proof that it holds no unsynchronized work."
elif rx '(touch|cp|mv|ln|tee|install|truncate|dd)[^;&|]*(check-ok\.|\.git/apex-sync/)' \
     || rx '>>?[[:space:]]*[^;&|[:space:]]*(check-ok\.|\.git/apex-sync/)' \
     || rx 'update-ref[^;&|]*refs/apex-sync|refs/apex-sync[^;&|]*update-ref'; then
  guard_override="the markers, refs/apex-sync/* and state under .git/apex-sync/ are written only by apex-sync-check.sh."
fi

[[ ${#needs[@]} -eq 0 && -z "$guard_override" ]] && exit 0

# ---------------------------------------------------------------- repo
if (( DEGRADED )); then cwd=$(raw_get cwd); else cwd=$(printf '%s' "$input" | json_get - cwd); fi
cwd=${cwd:-.}
if ! ROOT=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null); then
  # Not a repo — or git refused it (dubious ownership on /mnt/c is common under
  # WSL). Only ours to police when an apex-sync.json sits up the tree; then git's
  # failure must block, never quietly allow.
  d=$(cd "$cwd" 2>/dev/null && pwd) || d=""
  found=""
  for (( i = 0; i < 64 && ${#d} > 0; i++ )); do
    [[ -f "$d/apex-sync.json" ]] && { found="$d/apex-sync.json"; break; }
    [[ "$d" == / || "$d" == "$(dirname "$d")" ]] && break
    d=$(dirname "$d")
  done
  [[ -z "$found" ]] && exit 0                                             # not ours to police
  err=$(git -C "$cwd" rev-parse --show-toplevel 2>&1 | head -1)
  block "found $found, but git cannot resolve the repository here (${err:-no error text}), so the guard cannot check anything. Fix git first — e.g. git config --global --add safe.directory <repo> — then retry."
fi
CFG="$ROOT/apex-sync.json"
[[ -f "$CFG" ]] || exit 0                                                   # project not onboarded → allow

[[ -n "$guard_override" ]] && block "$guard_override It is the user's call: ask them to run it in their own terminal."

# ---------------------------------------------------------------- config
# Every alias the config declares — the single-app key, or each apps[] entry. The
# check script validates the whole file; here only what the hook needs, and any
# doubt blocks: a config the check refuses must not leave the hook allowing.
config_aliases() {
  if [[ "${JSON_TOOL[0]}" == "jq" ]]; then
    jq -r 'if type != "object" then error("not an object")
           elif has("apps") then (.apps | if type == "array" then .[] | .appAlias else error("apps") end)
           else .appAlias end | if type == "string" then . else error("alias") end' "$CFG" 2>/dev/null | strip_cr
  else
    "${JSON_TOOL[@]}" -c '
import json, sys
c = json.load(open(sys.argv[1]))
assert isinstance(c, dict)
apps = c["apps"] if "apps" in c else [c]
assert isinstance(apps, list)
for a in apps:
    assert isinstance(a, dict) and isinstance(a.get("appAlias"), str)
    print(a["appAlias"])' "$CFG" 2>/dev/null | strip_cr
  fi
}
ALIASES=()
if (( ${#JSON_TOOL[@]} )); then
  _list=$(config_aliases) || block "apex-sync.json is unreadable or invalid, so the guard cannot tell what to check. Run: <apex-sync-guard skill dir>/scripts/apex-sync-check.sh doctor"
  while IFS= read -r _a; do [[ -n "$_a" ]] && ALIASES+=("$_a"); done <<<"$_list"
else
  # No parser at all: take every "appAlias" in the file. In practice the check
  # script cannot run without a parser either, so this mostly decides how to block.
  while IFS= read -r _a; do [[ -n "$_a" ]] && ALIASES+=("$_a"); done \
    < <(grep -o '"appAlias"[[:space:]]*:[[:space:]]*"[^"]*"' "$CFG" | sed 's/.*"\([^"]*\)"$/\1/' | strip_cr)
fi
(( ${#ALIASES[@]} )) || block "apex-sync.json declares no appAlias, so the guard cannot tell what to check. Run: <apex-sync-guard skill dir>/scripts/apex-sync-check.sh doctor"
for _a in "${ALIASES[@]}"; do
  [[ "$_a" =~ $RE_APP_ALIAS ]] || block "apex-sync.json has an invalid appAlias ('$_a'). Run: <apex-sync-guard skill dir>/scripts/apex-sync-check.sh doctor"
done

# ---------------------------------------------------------------- freshness
# Every app the config declares needs a fresh marker in the needed direction.
now=$(date +%s)
[[ "$now" =~ ^[0-9]+$ ]] || block "cannot read the clock, so the marker's age is unknown."
for d in "${needs[@]}"; do
  for a in "${ALIASES[@]}"; do
    m="$ROOT/.git/apex-sync/$a/check-ok.$d"
    t=""; [[ -f "$m" ]] && t=$(mtime "$m" 2>/dev/null)
    # A missing, unreadable, expired — or future-dated (clock skew) — marker is no marker.
    if [[ ! -f "$m" || ! "$t" =~ ^[0-9]+$ ]] || (( now - t >= TTL || now - t < -60 )); then
      echo "apex-sync-guard: BLOCKED apex $d — no check-$d PASS in the last $((TTL/60)) min for app '$a'." >&2
      echo "Run first (from the repo root): <apex-sync-guard skill dir>/scripts/apex-sync-check.sh check-$d" >&2
      # Naming the path is not noise. This hook resolves the repo from the tool
      # payload's cwd, while the check resolves it from ITS OWN cwd — so running
      # the check inside a command that `cd`s elsewhere writes the marker in one
      # repo while this looks in another, and the block is indistinguishable from
      # never having run the check. The path makes that visible in one read.
      echo "  (looked for the marker at: $m — this repo was resolved from cwd '$cwd')" >&2
      echo "Then retry. Rationale: the $d would silently overwrite the other replica (skill: apex-sync-guard)." >&2
      (( DEGRADED )) && echo "(No working jq/python was found, so this decision was made by scanning the raw tool payload.)" >&2
      exit 2
    fi
  done
done
exit 0
