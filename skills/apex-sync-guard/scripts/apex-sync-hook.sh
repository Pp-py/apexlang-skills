#!/usr/bin/env bash
# apex-sync-guard — Claude Code PreToolUse hook (matcher: Bash|PowerShell).
# Shell-agnostic by design: it reads tool_input.command — the field BOTH shell
# tools carry — and decides by matching that text. Nothing from the caller's
# shell is ever executed here, which is what makes covering a second tool a
# matcher change and not a rewrite.
#
# Blocks an import or export (in any of the lanes below) unless a fresh matching
# check PASS marker exists (TTL 5 min) for the LOCAL it compared. Direction-aware: an import needs a
# check-import PASS, an export needs a check-export PASS. With several apps in
# apex-sync.json, it needs the marker of the app the command acts on — read from
# the command, never guessed. It also refuses the commands that would let an agent
# overrule the guard: record-sync --force and writes to the guard's own markers,
# refs and state.
#
# Exit 0 = allow, exit 2 = block (stderr goes back to the agent). Claude Code
# blocks ONLY on exit 2 — any other exit lets the command run — so once a command
# looks relevant, every unplanned exit is turned into a block (on_exit, below).
set -uo pipefail

TTL=300   # seconds a check PASS authorizes; must equal TTL_SECONDS in apex-sync-check.sh

# This runs before every shell command of the session, so it spawns as few processes
# as it can: under Git Bash each one costs tens of milliseconds. Helpers hand their
# result back in a global instead of printing it into a $(...).

# Native tooling on Windows writes CRLF, and a trailing \r survives command
# substitution — it would break the repo lookup and the pattern match below.
strip_cr() { tr -d '\r'; }

# ASCII letters lowered, in LV — what tr did here: bash 3.2 has no ${x,,}.
LV=""
lower_v() {
  local s=$1
  s=${s//A/a}; s=${s//B/b}; s=${s//C/c}; s=${s//D/d}; s=${s//E/e}; s=${s//F/f}; s=${s//G/g}
  s=${s//H/h}; s=${s//I/i}; s=${s//J/j}; s=${s//K/k}; s=${s//L/l}; s=${s//M/m}; s=${s//N/n}
  s=${s//O/o}; s=${s//P/p}; s=${s//Q/q}; s=${s//R/r}; s=${s//S/s}; s=${s//T/t}; s=${s//U/u}
  s=${s//V/v}; s=${s//W/w}; s=${s//X/x}; s=${s//Y/y}; s=${s//Z/z}
  LV=$s
}

# The payload, read without a process where bash allows it: $(<file) forks nothing
# from bash 5.2 on. /dev/stdin cannot be opened when stdin is a socket (Linux): cat.
{ input=$(</dev/stdin); } 2>/dev/null || input=$(cat)

PY_GET='
import json, sys
src = sys.stdin if sys.argv[1] == "-" else open(sys.argv[1])
data = json.load(src)
for k in sys.argv[2].split("."):
    data = data.get(k) if isinstance(data, dict) else None
    if data is None: break
print("" if data is None else data)'
JV=""
json_get() {  # $1 = dotted key path, read from the payload → JV; 1 = the parser failed
  if [[ "${JSON_TOOL[0]}" == "jq" ]]; then
    JV=$(jq -r ".$1 // empty" <<<"$input" 2>/dev/null) || return 1
  else
    JV=$("${JSON_TOOL[@]}" -c "$PY_GET" - "$1" <<<"$input" 2>/dev/null) || return 1
  fi
  JV=${JV//$'\r'/}
}

raw_get() {  # $1 = field name — flat string extraction when there is no parser at all
  sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\(\([^"\]\|\\.\)*\)".*/\1/p' <<<"$input" | head -1 | strip_cr
}

# The parser is resolved by EXECUTION, not by `command -v`: the Microsoft Store
# `python3` stub satisfies presence checks and then exits without running. Its first
# run is the read of the command — needed anyway to know whether the command is
# relevant at all — and the probe on '{}' runs only when that read fails, to tell a
# broken parser (try the next) from a payload the parser cannot read (scan it raw).
# apex-sync.json is only read (lib/, below) for commands that are relevant.
JSON_TOOL=(); _parsed=0
for _c in jq "python3" "python" "py -3"; do
  read -ra _cand <<<"$_c"
  command -v "${_cand[0]}" >/dev/null 2>&1 || continue
  JSON_TOOL=("${_cand[@]}")
  if json_get tool_input.command; then _parsed=1; break; fi
  if [[ "$_c" == jq ]]; then jq -e . <<<'{}' >/dev/null 2>&1 && break
  else "${_cand[@]}" -c 'import json' >/dev/null 2>&1 && break; fi
  JSON_TOOL=()
done

DEGRADED=0
if (( _parsed )); then
  cmd=$JV
  if [[ -z "$cmd" ]]; then
    # Empty is a real no-op only when the payload carries no command either; a parser
    # that reads nothing out of one that does is broken — scan the raw text instead.
    cmd=$(raw_get command)
    [[ -z "$cmd" ]] && exit 0
    DEGRADED=1
  fi
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

split_lines() {  # $1 = text → SL: its non-empty lines (word splitting on newlines, globbing off)
  local IFS=$'\n' noglob=0
  [[ $- == *f* ]] && noglob=1
  set -f
  # shellcheck disable=SC2206   # split on newlines on purpose, with globbing off
  SL=($1)
  (( noglob )) || set +f
}
# The command's lines, split once. Every pattern below is matched line by line, as
# grep matched them — they depend on it: [^;&|]* stops at a newline, ^ and $ anchor
# each line.
split_lines "$cmd"; CMD_LINES=(${SL[@]+"${SL[@]}"})

# Case-insensitive ERE match against the command, in bash: a grep per pattern was a
# process per pattern, a dozen per command. A pattern the regex engine rejects
# (status 2, an older engine) must read as a match — block — never as "no match",
# which would allow.
rx() {
  local l rc=1
  shopt -s nocasematch
  for l in ${CMD_LINES[@]+"${CMD_LINES[@]}"}; do
    [[ "$l" =~ $1 ]] 2>/dev/null && { rc=0; break; }
    (( $? == 2 )) && { rc=0; break; }
  done
  shopt -u nocasematch
  return "$rc"
}

# ---------------------------------------------------------------- lanes
# A SQLcl launcher anywhere in the command: `sql`, `sql.exe`, `sql.bat`, `sqlcl`
# as a word, or $SQLCL_BIN (how Oracle's scripts name it).
SQLCL_LAUNCHER='(^|[;&|(`[:space:]/\\])(sql|sql\.exe|sql\.bat|sqlcl)["'"'"']?([[:space:]]|$)|\$\{?SQLCL_BIN\}?'

# SQLcl's own names (`help apex`, SQLcl 26.2): every subcommand has a short form,
# and so does every option. Missing them let `apex imp -i dir` through.
IMPORT_SUB='(import|imp)'
EXPORT_SUB='(export(-[[:alpha:]-]+)?|ex|exaa|exaw|exap|exco|exfe|exin|exsf|exwo)'
IMPORT_FLAGS='-input|-i|-id|-alias|-al|-deployment|-d|-name|-n|-schema|-sch|-proxy|-pr|-image-prefix|-impr|-workspace|-ws|-workspaceid|-woi|-applicationid|-api'
EXPORT_FLAGS='-applicationid|-api|-dir|-di|-exptype|-exty|-expcomponents|-exc|-split|-sp|-workspaceid|-woi|-expworkspace|-exwo|-instance|-in|-expsupportingobjects|-exso|-expfiles|-exfi|-expminimal|-exmi|-skipexportdate|-sked|-overwrite-files|-ovf'

# A subcommand only counts as an invocation when one of its options follows it on
# the same line, or when a SQLcl launcher is in the command. Matching the bare phrase
# blocked commands that merely MENTIONED it: a grep pattern, a `git commit -m`
# message — and editing this very file. A guard that obstructs reading its own source
# is a guard people switch off. Options are looked for AFTER the subcommand: short
# forms like -i are everywhere else (`grep -i "apex import" …` is a search). The
# launcher alternative closes the opposite hole: a bare `apex import` imports the
# CURRENT DIRECTORY, so `sql -name dev <<< "apex import"` is a real import with no
# option in it — and a heredoc whose options sit on a continuation line has its
# launcher on the first.
apex_subcommand() {  # $1 = subcommand ERE, $2 = its options ERE
  rx "apex[[:space:]]+$1([^[:alnum:]_-]|$)" || return 1
  # DEGRADED means no JSON parser was found and `$cmd` is the raw payload (or a
  # regex-scraped guess at it), so there is no telling what is a command and
  # what is incidental text: suspicion beats precision, the bare phrase is enough.
  (( DEGRADED )) && return 0
  rx "apex[[:space:]]+$1[^;&|]*[[:space:]]($2)([[:space:]=]|$)" || rx "$SQLCL_LAUNCHER"
}

# Oracle's apexlang-deploy (26.1 and 26.2) imports through a script: the literal
# `apex import` lives in its heredoc and never reaches this hook. Any command that
# names the script is an import UNLESS every one of its segments starts with a
# plain reader — so `cat`/`grep`/`sed` of the script pass, while `bash … x`,
# `cd d && ./deploy-apex-app.sh x`, `if ./deploy-apex-app.sh …`, `cat … | bash -s`
# and `& 'C:\…\deploy-apex-app.sh'` (PowerShell) all count.
# The command's segments, one per element: every separator splits.
SEPARATORS='[;&|`(){}]'
WORD_SEPARATORS=$'[;&|(){}<>\t`]'   # and, for path-like words, redirections and tabs too
segments() { split_lines "${cmd//$SEPARATORS/$'\n'}"; SEGS=(${SL[@]+"${SL[@]}"}); }
READERS='cat|less|more|head|tail|grep|egrep|fgrep|rg|ag|sed|awk|wc|ls|file|stat|shellcheck|git|echo|printf|cd|pushd|popd|diff|cmp|sha256sum|shasum|md5sum|sort|uniq|cut|tr|nl|bat|code|vi|vim|nano|get-content|gc|select-string|sls|type'
deploy_invoked() {
  rx 'deploy-apex-app\.sh' || return 1
  (( DEGRADED )) && return 0
  local seg first assign='^[A-Za-z_][A-Za-z0-9_]*=("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:]]*)[[:space:]]+(.*)$'
  segments
  for seg in ${SEGS[@]+"${SEGS[@]}"}; do
    seg=${seg#"${seg%%[![:space:]]*}"}
    [[ -z "$seg" ]] && continue
    while [[ "$seg" =~ $assign ]]; do seg=${BASH_REMATCH[2]}; done   # VAR=value prefixes
    first=${seg%%[[:space:]]*}
    first=${first##*/}                                                 # /usr/bin/cat
    lower_v "$first"
    [[ "$LV" =~ ^($READERS)$ ]] || return 0
  done
  return 1
}

# `runtime roundtrip` is gated whatever --import-intent says. Its default is
# validate-only (apexctl.mjs), so a bare roundtrip is over-blocked on purpose:
# one 20 s check-import is cheaper than trusting our reading of an upstream default.
APEXCTL_IMPORT=0
if rx 'apexctl[^;|&]*runtime[[:space:]]+roundtrip' || rx '(import-intent|runtime-action)[[:space:]=]+validate-and-import'; then
  APEXCTL_IMPORT=1
fi
needs=()
if apex_subcommand "$IMPORT_SUB" "$IMPORT_FLAGS" || (( APEXCTL_IMPORT )) || deploy_invoked; then
  needs+=(import)
fi
apex_subcommand "$EXPORT_SUB" "$EXPORT_FLAGS" && needs+=(export)

# Commands that would let an agent overrule the guard. They are refused even with a
# fresh marker: forcing a syncpoint, or writing the markers/refs/state the guard
# reads, is the user's decision.
guard_override=""
if rx 'apex-sync-check(\.sh)?[^;&|]*record-sync' && rx '(^|[[:space:]])--force([[:space:]=]|$)'; then
  guard_override="record-sync --force records the Builder as BASE without any proof that it holds no unsynchronized work."
elif rx '(touch|cp|mv|ln|tee|install|truncate|dd)[^;&|]*(check-ok\.|\.git/(worktrees/[^/;&|[:space:]]+/)?apex-sync/)' \
     || rx '>>?[[:space:]]*[^;&|[:space:]]*(check-ok\.|\.git/(worktrees/[^/;&|[:space:]]+/)?apex-sync/)' \
     || rx 'update-ref[^;&|]*refs/apex-sync|refs/apex-sync[^;&|]*update-ref'; then
  guard_override="the markers, refs/apex-sync/* and state under .git/apex-sync/ (.git/worktrees/<name>/apex-sync/ in a worktree) are written only by apex-sync-check.sh."
fi

[[ ${#needs[@]} -eq 0 && -z "$guard_override" ]] && exit 0

# ---------------------------------------------------------------- repo
if (( DEGRADED )); then cwd=$(raw_get cwd); else json_get cwd || JV=""; cwd=$JV; fi
cwd=${cwd:-.}

# The physical form of an existing dir, in PD, as `cd "$1" && pwd -P` gave it in a
# subshell — but in this shell, which then returns: cd there (logically, so '..'
# comes off before symlinks are resolved), re-enter it physically, come back.
HERE=$PWD; PD=""
phys_dir() {  # $1 = a dir → PD; 1 if it cannot be entered
  PD=""
  CDPATH='' cd -- "$1" 2>/dev/null || return 1
  CDPATH='' cd -P . 2>/dev/null && PD=$PWD
  cd -- "$HERE" 2>/dev/null || exit 1    # lost the session's footing: the trap blocks
  [[ -n "$PD" ]]
}

CRO=""
cfg_root_of() {  # $1 = an existing dir → CRO: the nearest ancestor holding apex-sync.json (physical path), or ''
  local d p i
  CRO=""
  phys_dir "$1" || return 0
  d=$PD
  for (( i = 0; i < 64; i++ )); do
    [[ -f "$d/apex-sync.json" ]] && { CRO=$d; return 0; }
    p=${d%/*}; [[ -n "$p" ]] || p=/                 # dirname
    [[ "$d" == / || "$d" == "$p" ]] && return 0
    d=$p
  done
}

# One git call gives the root and this worktree's git dir, where its markers live (GAP-7).
if _rp=$(git -C "$cwd" rev-parse --show-toplevel --absolute-git-dir 2>/dev/null); then
  ROOT=${_rp%%$'\n'*}; GITDIR=${_rp#*$'\n'}
else
  # Not a repo — or git refused it (dubious ownership on /mnt/c is common under
  # WSL). Ours to police when an apex-sync.json sits up the tree; then git's
  # failure must block, never quietly allow.
  cfg_root_of "$cwd"; found=$CRO
  if [[ -n "$found" ]]; then
    err=$(git -C "$cwd" rev-parse --show-toplevel 2>&1 | head -1)
    block "found $found/apex-sync.json, but git cannot resolve the repository here (${err:-no error text}), so the guard cannot check anything. Fix git first — e.g. git config --global --add safe.directory <repo> — then retry."
  fi
  ROOT=""; GITDIR=""
fi
SESSION=""; [[ -n "$ROOT" && -f "$ROOT/apex-sync.json" ]] && phys_dir "$ROOT" && SESSION=$PD

# ---------------------------------------------------------------- reach
# The markers checked below are the session repo's — the hook resolves its repo from
# the session's cwd. A command that moves into another onboarded repo (cd, pushd) or
# points at one (a path argument) would be checked against the wrong markers, or —
# from a session outside any onboarded repo — against none: it must run from inside
# that repo. A `cd` whose target is computed at run time cannot be followed: it blocks.
ED=""
existing_dir() {  # $1 = a path as written, relative to the session cwd → ED: the deepest existing dir on it
  local p=${1//\\//}
  # shellcheck disable=SC2088   # a literal '~/' as the command wrote it
  [[ "$p" == "~" || "$p" == "~/"* ]] && p="$HOME${p#\~}"
  [[ "$p" == /* || "$p" =~ ^[A-Za-z]: ]] || p="$cwd/$p"
  while [[ -n "$p" && ! -d "$p" ]]; do
    [[ "$p" == */* ]] || { p=""; break; }
    p=${p%/*}
  done
  ED=$p
}

# Every match of an ERE in the command, as `grep -o` printed them: line by line,
# leftmost first, each search resuming where the last match ended. A resumed search
# runs behind a sentinel character, so ^ cannot match there — grep's ^ is the
# start of the line only. Case-insensitive with $2 = nocase. → MATCHES
MATCHES=()
matches() {  # $1 = ERE, $2 = nocase|''
  local l rest m pre sent hit
  MATCHES=()
  for l in ${CMD_LINES[@]+"${CMD_LINES[@]}"}; do
    rest=$l; sent=""
    while :; do
      [[ "${2:-}" == nocase ]] && shopt -s nocasematch
      [[ "$sent$rest" =~ $1 ]] 2>/dev/null; hit=$?
      shopt -u nocasematch
      (( hit == 0 )) || break
      m=${BASH_REMATCH[0]}
      [[ -n "$m" ]] || break
      MATCHES+=("$m")
      pre=${rest%%"$m"*}                         # where the match is: its first occurrence
      rest=${rest:$(( ${#pre} + ${#m} ))}; sent=x
    done
  done
}

REACH=()
reach_paths() {  # → REACH: every path the command names, "cd <dir>" targets first, then "path <word>"
  local m w words=()
  REACH=()
  matches '(^|[;&|({`[:space:]])(cd|pushd)[[:space:]]+("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:];&|)]+)'
  for m in ${MATCHES[@]+"${MATCHES[@]}"}; do
    [[ "$m" =~ ^.*(cd|pushd)[[:space:]]+ ]] && m=${m:${#BASH_REMATCH[0]}}   # up to the last cd/pushd
    m=${m#[\"\']}; m=${m%[\"\']}
    REACH+=("cd $m")
  done
  # The words, split on blanks once the shell's separators are blanks too.
  local IFS=$' \n' noglob=0
  [[ $- == *f* ]] && noglob=1
  set -f
  # shellcheck disable=SC2206   # split on blanks on purpose, with globbing off
  words=(${cmd//$WORD_SEPARATORS/ })
  (( noglob )) || set +f
  for w in ${words[@]+"${words[@]}"}; do
    w=${w#[\"\']}; w=${w%[\"\']}
    [[ "$w" =~ ^[^=/]*= ]] && w=${w:${#BASH_REMATCH[0]}}                   # VAR=value
    [[ "$w" == */* || "$w" == "~"* ]] && REACH+=("path $w")
  done
}
reach_paths
for _r in ${REACH[@]+"${REACH[@]}"}; do
  _kind=${_r%% *}; _p=${_r#* }
  case "$_p" in
    *'$'*|*'`'*|-) [[ "$_kind" == cd ]] && block "the command changes into a directory computed at run time ($_p), so the guard cannot tell which repository it acts on. Write the path out, or run it from inside the repo." ; continue ;;
  esac
  existing_dir "$_p"; _d=$ED; [[ -n "$_d" ]] || continue
  cfg_root_of "$_d"; _c=$CRO; [[ -n "$_c" && "$_c" != "$SESSION" ]] || continue
  block "the command reaches $_c, a repository the guard watches, but this session runs in '${cwd}'${SESSION:+ (repository $SESSION)} — the guard can only check the repository it runs in. Run the command from inside $_c."
done

[[ -n "$SESSION" ]] || exit 0                                               # not ours to police
CFG="$ROOT/apex-sync.json"

[[ -n "$guard_override" ]] && block "$guard_override It is the user's call: ask them to run it in their own terminal."

# ---------------------------------------------------------------- config
# apex-sync.json is read by the same code as apex-sync-check.sh (lib/), so the hook
# and the check cannot disagree on which apps exist or where their source lives.
# Found next to the real file even through a symlink; if it is missing, block.
_self=${BASH_SOURCE[0]}
while [[ -L "$_self" ]]; do
  _d=$(cd -P "$(dirname "$_self")" && pwd); _self=$(readlink "$_self"); [[ "$_self" == /* ]] || _self="$_d/$_self"
done
case "$_self" in */*) _d=${_self%/*}; _d=${_d:-/} ;; *) _d=. ;; esac   # dirname
_libdir=""; CDPATH='' cd -P -- "$_d" && _libdir=$PWD; cd -- "$HERE" 2>/dev/null || exit 1
_lib="$_libdir/lib/sync-config.sh"
# shellcheck source=skills/apex-sync-guard/scripts/lib/sync-config.sh
. "$_lib" 2>/dev/null || block "incomplete installation: $_lib is missing, so the guard cannot read apex-sync.json."

if (( DEGRADED )); then
  # No parser: take every "appAlias" in the file, and require all of their markers.
  # In practice the check script cannot run without a parser either, so this mostly
  # decides how to block.
  while IFS= read -r _a; do [[ -n "$_a" ]] && APPS_ALIAS+=("$_a"); done \
    < <(grep -o '"appAlias"[[:space:]]*:[[:space:]]*"[^"]*"' "$CFG" | sed 's/.*"\([^"]*\)"$/\1/' | strip_cr)
  (( ${#APPS_ALIAS[@]} )) || block "apex-sync.json declares no appAlias, so the guard cannot tell what to check. Run: <apex-sync-guard skill dir>/scripts/apex-sync-check.sh doctor"
  for _a in "${APPS_ALIAS[@]}"; do
    [[ "$_a" =~ $RE_APP_ALIAS ]] || block "apex-sync.json has an invalid appAlias ('$_a'). Run: <apex-sync-guard skill dir>/scripts/apex-sync-check.sh doctor"
  done
else
  cfg_load
  # A config the check refuses must not leave the hook allowing.
  (( ${#CFG_ERRORS[@]} )) && block "apex-sync.json is invalid, so the guard cannot tell what to check:$(printf '\n  - %s' "${CFG_ERRORS[@]}")
Run: <apex-sync-guard skill dir>/scripts/apex-sync-check.sh doctor"
fi
NAPPS=${#APPS_ALIAS[@]}

# ---------------------------------------------------------------- targets
# With one app, every operation is that app's. With several, each needs the marker
# of the app it acts on, read from the command: a source dir (or a file in one) in
# -input/-i, --app-path or the deploy script's argument; an app id in -id or
# -applicationid/-api. What cannot be read is not guessed — it blocks, naming what
# would make it readable. (Without a parser there is no reading at all: DEGRADED
# needs every app's marker.)
# Paths are compared in one form: physical (symlinks resolved — macOS's /var is
# /private/var) and shell-native (Git Bash's /tmp and git's C:/… become the same
# string), through `cd … && pwd -P`; Windows compares without case.
NOCASE=""; case "${OSTYPE:-}" in msys*|cygwin*) NOCASE=1 ;; esac; [[ "$ROOT" =~ ^[A-Za-z]: ]] && NOCASE=1

LN=""
lex_norm() {  # an absolute '/'-separated path → LN: '.' and '..' resolved lexically
  local p=$1 out="" seg
  while [[ -n "$p" ]]; do
    seg=${p%%/*}
    if [[ "$p" == */* ]]; then p=${p#*/}; else p=""; fi
    case "$seg" in ""|.) ;; ..) out=${out%/*} ;; *) out+="/$seg" ;; esac
  done
  LN=${out:-/}
}
PH=""
phys() {  # $1 = a path as a command wrote it (relative to the session cwd) → PH, comparable with ROOT_N
  local p=${1//\\//} rest="" d
  # shellcheck disable=SC2088   # a literal '~/' as the command wrote it
  [[ "$p" == "~" || "$p" == "~/"* ]] && p="$HOME${p#\~}"
  [[ "$p" == /* || "$p" =~ ^[A-Za-z]: ]] || p="$CWD_N/$p"
  while [[ -n "$p" && ! -d "$p" ]]; do          # the part that exists is resolved, the rest kept
    [[ "$p" == */* ]] || { p=""; break; }
    rest="/${p##*/}$rest"; p=${p%/*}
  done
  if phys_dir "${p:-/}"; then d=$PD; else d=${p:-/}; fi
  lex_norm "$d$rest"
  if [[ -n "$NOCASE" ]]; then lower_v "$LN"; PH=$LV; else PH=$LN; fi
}
ROOT_N=""; CWD_N=""
if (( ! DEGRADED && NAPPS > 1 )); then
  if phys_dir "$cwd"; then CWD_N=$PD; else phys_dir "$ROOT"; CWD_N=$PD; fi
  phys "$ROOT"; ROOT_N=$PH
fi

# shellcheck disable=SC2034   # read and written by name: T_$direction
T_import=" " T_export=" "
UNRESOLVED=""
add_target() { local v="T_$1"; [[ "${!v}" == *" $2 "* ]] || printf -v "$v" '%s%s ' "${!v}" "$2"; }
unresolved() { [[ -n "$UNRESOLVED" ]] || UNRESOLVED=$1; }

# Each invocation's own text: from the subcommand (or script) to the end of its
# command segment, so another command's options (`grep -i x; apex import …`) are
# never read as its arguments — the spans are `matches … nocase`.
FV=()
flag_values() {  # $1 = text, $2 = options ERE → FV: every value they take
  local rest=$1 re
  FV=()
  re="(^|[[:space:]])($2)([[:space:]]+|=)(\"([^\"]*)\"|'([^']*)'|([^[:space:];&|()\`<>\"']+))"
  shopt -s nocasematch
  while [[ "$rest" =~ $re ]]; do
    FV+=("${BASH_REMATCH[5]}${BASH_REMATCH[6]}${BASH_REMATCH[7]}")
    rest=${rest#*"${BASH_REMATCH[0]}"}
  done
  shopt -u nocasematch
}
FA=""
first_arg() {  # $1 = a deploy-script span → FA: the argument after the script, if any
  local re="^deploy-apex-app\.sh[\"']?[[:space:]]+(\"([^\"]*)\"|'([^']*)'|([^[:space:];&|()\`<>\"']+))"
  FA=""
  [[ "$1" =~ $re ]] && FA="${BASH_REMATCH[2]}${BASH_REMATCH[3]}${BASH_REMATCH[4]}"
  return 0
}

target_of_path() {  # $1 = direction, $2 = a source path from the command
  local v=$2 r p i src
  case "$v" in
    *'$'*|*'`'*)  unresolved "a path is computed at run time ($v)"; return ;;
    *.zip|*.ZIP)  unresolved "a .zip ($v) cannot be traced to an app's source dir"; return ;;
  esac
  phys "$v"; p=$PH
  if [[ "$p" != "$ROOT_N"/* ]]; then unresolved "$v is not inside this repository"; return; fi
  r=${p#"$ROOT_N"/}
  for (( i = 0; i < NAPPS; i++ )); do
    app_src "$i"; src=$SR; [[ -n "$NOCASE" ]] && { lower_v "$src"; src=$LV; }
    if [[ "$r" == "$src" || "$r" == "$src/"* ]]; then add_target "$1" "${APPS_ALIAS[$i]}"; return; fi
  done
  unresolved "$v is not inside any app's source dir"
}
target_of_id() {  # $1 = direction, $2 = an app id from the command
  local i hit="" n=0
  for (( i = 0; i < NAPPS; i++ )); do
    [[ "${APPS_ID[$i]}" == "$2" ]] && { hit=${APPS_ALIAS[$i]}; n=$((n + 1)); }
  done
  if (( n == 1 )); then add_target "$1" "$hit"; else unresolved "app id $2 is not declared exactly once in apex-sync.json"; fi
}

# Every invocation must name its app — one that does cannot vouch for another in the
# same command (`apex import -input a && cd b && apex import`).
resolve_import() {
  local s v n seg first runs=0 spans
  matches "apex[[:space:]]+$IMPORT_SUB([^[:alnum:]_-][^;&|]*)?" nocase; spans=(${MATCHES[@]+"${MATCHES[@]}"})
  for s in ${spans[@]+"${spans[@]}"}; do
    [[ -z "$s" ]] && continue
    runs=1; n=0
    flag_values "$s" '-input|-i'
    for v in ${FV[@]+"${FV[@]}"}; do [[ -n "$v" ]] && { n=1; target_of_path import "$v"; }; done
    flag_values "$s" '-id|-applicationid|-api'
    for v in ${FV[@]+"${FV[@]}"}; do [[ -n "$v" ]] && { n=1; target_of_id import "$v"; }; done
    (( n )) || unresolved "an apex import names no app — no -input, no -id (a bare apex import imports the current directory)"
  done
  if (( APEXCTL_IMPORT )); then
    matches 'apexctl[^;&|]*' nocase; spans=(${MATCHES[@]+"${MATCHES[@]}"})
    for s in ${spans[@]+"${spans[@]}"}; do
      [[ -z "$s" ]] && continue
      runs=1; n=0
      flag_values "$s" '--app-path'
      for v in ${FV[@]+"${FV[@]}"}; do [[ -n "$v" ]] && { n=1; target_of_path import "$v"; }; done
      (( n )) || unresolved "an apexctl run names no --app-path"
    done
  fi
  # The deploy script: every segment that runs it (not a plain reader) names its dir.
  n=0
  segments
  for seg in ${SEGS[@]+"${SEGS[@]}"}; do
    [[ "$seg" == *deploy-apex-app.sh* ]] || continue
    first=${seg#"${seg%%[![:space:]]*}"}; first=${first%%[[:space:]]*}; lower_v "${first##*/}"; first=$LV
    [[ "$first" =~ ^($READERS)$ ]] && continue
    runs=1; n=1
    first_arg "deploy-apex-app.sh${seg#*deploy-apex-app.sh}"; v=$FA
    if [[ -n "$v" ]]; then target_of_path import "$v"; else unresolved "the deploy script is run without an app directory"; fi
  done
  if deploy_invoked && (( n == 0 )); then
    unresolved "the deploy script is run in a way the guard cannot read (piped or computed)"
  fi
  (( runs )) || unresolved "the command names no app — no -input, -id, --app-path or deploy-script argument"
}

resolve_export() {
  local s v ids spans
  matches "apex[[:space:]]+$EXPORT_SUB([^[:alnum:]_-][^;&|]*)?" nocase; spans=(${MATCHES[@]+"${MATCHES[@]}"})
  for s in ${spans[@]+"${spans[@]}"}; do
    [[ -z "$s" ]] && continue
    flag_values "$s" '-applicationid|-api'
    ids=""; for v in ${FV[@]+"${FV[@]}"}; do ids+=$v; done
    if [[ -z "$ids" ]]; then
      # No app id: a workspace-, instance- or all-applications export writes the
      # tree of every app it holds — every declared app needs its check.
      for v in "${APPS_ALIAS[@]}"; do add_target export "$v"; done
    else
      for v in ${FV[@]+"${FV[@]}"}; do [[ -n "$v" ]] && target_of_id export "$v"; done
    fi
  done
}

if (( DEGRADED || NAPPS == 1 )); then
  for d in "${needs[@]}"; do for _a in "${APPS_ALIAS[@]}"; do add_target "$d" "$_a"; done; done
else
  for d in "${needs[@]}"; do
    case "$d" in import) resolve_import ;; export) resolve_export ;; esac
    if [[ -n "$UNRESOLVED" ]]; then
      _dirs=""; _ids=""
      for (( i = 0; i < NAPPS; i++ )); do app_src "$i"; _dirs+="${_dirs:+, }$SR"; _ids+="${_ids:+, }${APPS_ID[$i]}"; done
      if [[ "$d" == import ]]; then _how="its source dir ($_dirs) as the -input, deploy-apex-app.sh or --app-path argument, or its id ($_ids) as -id"
      else _how="its id ($_ids) as -applicationid"; fi
      block "apex-sync.json declares $NAPPS apps (${APPS_ALIAS[*]}) and this $d cannot be traced to one of them: $UNRESOLVED.
Name the app in the command, so the guard can require that app's check: $_how."
    fi
  done
fi

# ---------------------------------------------------------------- connection
# A check speaks for the Builder it compared, through the connection apex-sync.json
# names. `sql -name prod … apex import` after a check through dev would overwrite a
# Builder nobody checked. (A connect string, as Oracle's deploy script takes, cannot
# be compared with a saved name: GAP-6.)
CN=()
conn_names() {  # → CN: the saved-connection names the command's SQLcl launchers are given
  local s pre re='(^|[[:space:]])-name[[:space:]=]+("([^"]*)"|'"'"'([^'"'"']*)'"'"'|([^[:space:]]+))'
  CN=()
  matches '(^|[;&|(`[:space:]/\\])(sql|sql\.exe|sql\.bat|sqlcl)["'"'"']?[[:space:]][^;&|]*' nocase
  for s in ${MATCHES[@]+"${MATCHES[@]}"}; do
    pre=${s%%[<\"\'@]*}
    if [[ "$pre" =~ $re ]]; then CN+=("${BASH_REMATCH[3]}${BASH_REMATCH[4]}${BASH_REMATCH[5]}"); fi
  done
}
if (( ! DEGRADED )); then
  conn_names
  for _n in ${CN[@]+"${CN[@]}"}; do
    [[ -z "$_n" ]] && continue
    for d in "${needs[@]}"; do
      _v="T_$d"
      for a in ${!_v}; do
        app_index "$a" || continue
        app_envs "$a"; [[ -n "$ENVS" ]] && continue      # an app with environments: below
        [[ "${APPS_CONN[$APP_I]}" == "$_n" ]] && continue
        block "this $d connects through '$_n', but app '$a' is checked through '${APPS_CONN[$APP_I]}' (apex-sync.json): a check speaks only for the Builder it compared. Connect through '${APPS_CONN[$APP_I]}', or describe the other target as its own app in apex-sync.json."
      done
    done
  done
fi

# ---------------------------------------------------------------- environments
# An app with environments (R-1) has a Builder per environment, and a check speaks for
# one of them. Which one a command deploys to is read from the saved connection it
# names (sql -name <conn>): one of the app's environments, or it blocks — so does a
# command naming none (a connect string, as Oracle's deploy script takes, cannot be
# compared), and so does any import or export into a protected environment, which is
# the user's to run, never an agent's. K_<direction>: the state keys whose markers
# are needed — the alias, or alias.env.
# shellcheck disable=SC2034   # read and written by name: K_$direction
K_import=" " K_export=" "
if (( DEGRADED )) && grep -q '"environments"' "$ROOT/apex-sync.json" 2>/dev/null; then
  block "apex-sync.json declares environments, and without jq or a python that runs the guard cannot tell which one this command reaches. Install one, then retry."
fi
(( DEGRADED )) || conn_names
for d in "${needs[@]}"; do
  _v="T_$d"; _k="K_$d"
  for a in ${!_v}; do
    ENVS=""; (( DEGRADED )) || app_envs "$a"
    if [[ -z "$ENVS" ]]; then printf -v "$_k" '%s' "${!_k}$a "; continue; fi
    _hit=""
    for _n in ${CN[@]+"${CN[@]}"}; do
      for (( i = 0; i < NAPPS; i++ )); do
        [[ "${APPS_ALIAS[$i]}" == "$a" && "${APPS_CONN[$i]}" == "$_n" ]] && _hit=$i
      done
    done
    if [[ -z "$_hit" ]]; then
      _c=""; for (( i = 0; i < NAPPS; i++ )); do [[ "${APPS_ALIAS[$i]}" == "$a" ]] && _c+="${_c:+, }${APPS_ENV[$i]} → sql -name ${APPS_CONN[$i]}"; done
      _named=""; (( ${#CN[@]} )) && _named=" (it names ${CN[*]})"
      block "app '$a' declares environments, and this $d names none of their connections$_named: the guard cannot tell which Builder it reaches. Name the environment's saved connection: $_c."
    fi
    if [[ "${APPS_PROT[$_hit]}" == 1 ]]; then
      block "environment '${APPS_ENV[$_hit]}' of app '$a' is protected (apex-sync.json): an $d there is the user's to run, outside the agent — whatever the checks say."
    fi
    printf -v "$_k" '%s' "${!_k}${APPS_KEY[$_hit]} "
  done
done

# ---------------------------------------------------------------- freshness
# Every app the operation acts on needs a fresh marker in the needed direction.
# The clock without a process where bash has one: EPOCHSECONDS (bash 5).
now=""; (( BASH_VERSINFO[0] >= 5 )) && now=${EPOCHSECONDS:-}
[[ "$now" =~ ^[0-9]+$ ]] || now=$(date +%s)
[[ "$now" =~ ^[0-9]+$ ]] || block "cannot read the clock, so the marker's age is unknown."
for d in "${needs[@]}"; do
  _v="K_$d"
  for a in ${!_v}; do                 # a state key: the alias, or alias.env
    _env=""; [[ "$a" == *.* ]] && _env=" --env ${a#*.}"
    m="$GITDIR/apex-sync/$a/check-ok.$d"
    t=""   # its mtime: GNU stat, else BSD (macOS) stat
    if [[ -f "$m" ]]; then t=$(stat -c %Y "$m" 2>/dev/null) || t=$(stat -f %m "$m" 2>/dev/null) || t=""; fi
    # A missing, unreadable, expired — or future-dated (clock skew) — marker is no marker.
    if [[ ! -f "$m" || ! "$t" =~ ^[0-9]+$ ]] || (( now - t >= TTL || now - t < -60 )); then
      _app=""; (( NAPPS > 1 )) && _app=" --app ${a%%.*}$_env"
      echo "apex-sync-guard: BLOCKED apex $d — no check-$d PASS in the last $((TTL/60)) min for app '${a%%.*}'${_env:+ (environment ${a#*.})}." >&2
      echo "Run first (from the repo root): <apex-sync-guard skill dir>/scripts/apex-sync-check.sh check-$d$_app" >&2
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
    # Fresh in time is not enough (GAP-9): the marker speaks only for the LOCAL the check
    # compared. Hashed again here — only for an import or an export, about 0.2 s on Git
    # for Windows — a source dir that changed since, or that git cannot hash, blocks.
    # The source dir comes from apex-sync.json; read without a parser (degraded), from the
    # marker, which only the check writes.
    mt=$(sed -n 's/.*"tree":"\([0-9a-f]*\)".*/\1/p' "$m" 2>/dev/null) || mt=""
    SR=""; if (( ! DEGRADED )) && key_index "$a"; then app_src "$APP_I"; else SR=$(sed -n 's/.*"src":"\([^"]*\)".*/\1/p' "$m" 2>/dev/null) || SR=""; fi
    ST=""; [[ -n "$SR" && "$SR" != *..* ]] && src_tree "$ROOT" "$GITDIR" "$SR"
    if [[ -z "$mt" || -z "$ST" || "$mt" != "$ST" ]]; then
      _app=""; (( NAPPS > 1 )) && _app=" --app ${a%%.*}$_env"
      echo "apex-sync-guard: BLOCKED apex $d — the source of app '${a%%.*}' changed since its check-$d PASS (or the marker predates this check, or git cannot hash it): that PASS does not speak for what is there now." >&2
      echo "Run again (from the repo root): <apex-sync-guard skill dir>/scripts/apex-sync-check.sh check-$d$_app" >&2
      exit 2
    fi
  done
done
exit 0
