#!/usr/bin/env bash
# apex-sync-guard — Builder↔Git divergence guard for APEXlang apps.
#
# Usage (from anywhere inside the project repo):
#   apex-sync-check.sh check-import   # gate before `apex import`
#   apex-sync-check.sh check-export   # gate before `apex export`
#   apex-sync-check.sh record-sync    # after a successful import/export
#   apex-sync-check.sh status         # inspect syncpoint + both replicas
#   apex-sync-check.sh doctor         # validate this machine's wiring end to end
#   apex-sync-check.sh apps           # the apps apex-sync.json declares, as resolved
# Options (before or after the subcommand):
#   --app <alias>  which app; required for check-*/record-sync when apex-sync.json
#                  declares several (status/doctor/apps then cover all of them)
#   --task <id>  check-*/record-sync: also write the result to
#                <evidenceDir>/<id>/sync-<appAlias>-<subcommand>.json
#   --force      record-sync only: record the syncpoint although nothing proves the
#                Builder holds no unsynchronized work. The user's call, never an agent's.
#
# Exit codes: 0 PASS · 1 FAIL/CONFLICT · 2 BLOCKED (precondition missing) ·
#             3 UNKNOWN (started, outcome undeterminable — nothing authorized).
# Every gate run (check-import, check-export, record-sync) also leaves its verdict
# as JSON in <git-dir>/apex-sync/<appAlias>/last-<subcommand>.json — the sync-result
# contract, framework/schemas/sync-result.schema.json. The JSON is the verdict;
# the exit code mirrors it.
#
# Runs under bash: Linux, macOS, and Windows via Git Bash or WSL (not PowerShell/cmd).
#
# Reads apex-sync.json at the repo root. Sync state is machine-local, never committed:
# the git ref refs/apex-sync/<appAlias> holding the BASE tree and the syncpoint record
# <git-common-dir>/apex-sync/<appAlias>/state.json, shared by every worktree; the
# markers and last results in <git-dir>/apex-sync/<appAlias>/, one set per worktree,
# since each worktree has its own LOCAL. In a plain clone both dirs are .git.
#
# The core check is always a full `apex export` + diff against BASE:
# timestamp views (APEX_APPLICATION_PAGES / APEX_APPLICATIONS) miss some
# shared-component edits, so they are used for the who/when report only.
set -euo pipefail

TTL_SECONDS=600   # how long a check PASS authorizes; must equal TTL in apex-sync-hook.sh
FRAMEWORK_VERSION="0.6.1"   # the apexlang-skills release this script belongs to (.claude-plugin/plugin.json)

# --- verdicts. A gate command (check-import, check-export, record-sync) ends in
# exactly one status, and the EXIT trap (on_exit, below) turns it into the exit
# code and — only for a check that PASSed — the hook's freshness marker:
#   PASS 0 · FAIL/CONFLICT 1 · BLOCKED 2 · UNKNOWN 3
# An exit the code did not classify (set -e tripping, a signal) is UNKNOWN: the
# run started but nobody can say what it established, so nothing is authorized.
R_OP=""        # the gate command being run; empty for status/doctor
R_STATUS=""    # PASS | FAIL | CONFLICT | BLOCKED | UNKNOWN
R_REASON=""    # reason code (the catalog is in framework/schemas/sync-result.schema.json)
R_MESSAGE=""   # the verdict in words, as the result file carries it
classify() { R_STATUS=$1; R_REASON=$2; R_MESSAGE=${3:-}; }
# A precondition is missing; the check stopped before any effect.
die()     { [[ -n "$R_OP" ]] && classify BLOCKED "${DIE_REASON:-USAGE}" "$*"; echo "apex-sync-guard: ERROR: $*" >&2; exit 2; }
blocked() { local r=$1; shift; DIE_REASON=$r die "$@"; }
# The check started but cannot say what the Builder holds (an export or a git
# step failed part-way): not a verdict on the replicas, and never a PASS.
unknown() { local r=$1; shift; classify UNKNOWN "$r" "$*"; echo "apex-sync-guard: ERROR: $*" >&2; exit 3; }
# The check ran to the end and the operation must not proceed. $1 = FAIL|CONFLICT.
fail()    { local s=$1 r=$2; shift 2; classify "$s" "$r" "$*"; echo ""; echo "$s: $*" >&2; exit 1; }
pass()    { classify PASS "$1" "$2"; echo "PASS: $2"; }
note() { echo "  $*"; }
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }   # GNU stat / BSD (macOS) stat

# Helpers below hand their result back in a global (named on each) rather than print
# it into a $(...): every process costs tens of milliseconds under Git Bash. One
# caution comes with it — bash runs a $(...) without errexit, so a helper that ran
# there "best effort" says so now with an explicit `|| …`.

# The clock without a process where bash has one: EPOCHSECONDS (bash 5) and
# printf %(…)T (bash 4.2); bash 3.2 (macOS) has neither and runs date. TZ=UTC0 goes on
# the printf itself: a `local TZ` is not exported, and bash 5 then formats local time.
if TZ=UTC0 printf -v _t '%(%Y)T' 0 2>/dev/null && [[ "$_t" == 1970 ]]; then PRINTF_T=1; else PRINTF_T=0; fi
EPOCH=""; ISO=""
epoch_now() {  # → EPOCH ('' if the clock cannot be read)
  EPOCH=""; (( BASH_VERSINFO[0] >= 5 )) && EPOCH=${EPOCHSECONDS:-}
  [[ "$EPOCH" =~ ^[0-9]+$ ]] || EPOCH=$(date +%s) || EPOCH=""
}
now_iso() {  # → ISO: now, UTC (BSD date has no -Iseconds)
  if (( PRINTF_T )); then TZ=UTC0 printf -v ISO '%(%Y-%m-%dT%H:%M:%SZ)T' -1
  else ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ) || ISO=""; fi
}

# A path that crosses into a native Windows binary must be converted first.
# The export dir reaches SQLcl (a Java program) inside the SQL text on stdin,
# where MSYS does no argv mangling at all, so /tmp/... arrives as C:\tmp\... .
# Forward slashes (-m, not -w) so nothing has to survive backslash escaping.
NP=""
native_path() {  # $1 = a path → NP
  if command -v cygpath >/dev/null 2>&1; then NP=$(cygpath -m "$1"); else NP=$1; fi
}

LINES=()
lines_of() {  # $1 = text → LINES: its non-empty lines (word splitting on newlines, globbing off)
  local IFS=$'\n' noglob=0
  [[ $- == *f* ]] && noglob=1
  set -f
  # shellcheck disable=SC2206   # split on newlines on purpose, with globbing off
  LINES=($1)
  (( noglob )) || set +f
}

TMP_KEEP=""                       # scratch dirs preserved on FAIL for resolution
TMPS=()
RESULT_FILES=()                   # where this run's sync-result goes (results_init)
ROOT=""; STATE_DIR=""             # known once the repo and the app are
GIT_DIR_ABS=""; GIT_COMMON=""; STATE_REL=".git"   # this worktree's git dir, the shared one

# A check that does not end in PASS leaves no authorization behind: not the marker it
# set out to renew, nor one an earlier or a concurrent run left — what it guards is
# unknown again. Stopped before its app was known (a bad option, no SQLcl, an invalid
# config, --app missing), it withdraws that direction for every app the file names,
# read without a parser: one may not exist yet.
# A check always starts by withdrawing its own authorization: a FAIL, a BLOCKED or
# a crash must never leave an earlier PASS's marker fresh for the hook to trust.
# (rm only when there is something to remove: it is a process.)
revoke_marker() { if [[ -e "$STATE_DIR/check-ok.$1" || -L "$STATE_DIR/check-ok.$1" ]]; then rm -f "$STATE_DIR/check-ok.$1"; fi; }

withdraw_markers() {  # $1 = import|export
  local root gd a
  if [[ -n "$STATE_DIR" ]]; then revoke_marker "$1"; return 0; fi
  root=${ROOT:-$(git rev-parse --show-toplevel 2>/dev/null)}
  gd=${GIT_DIR_ABS:-$(git rev-parse --absolute-git-dir 2>/dev/null)}
  [[ -n "$root" && -n "$gd" && -f "$root/apex-sync.json" ]] || return 0
  while IFS= read -r a; do
    [[ "$a" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]] && rm -f "$gd/apex-sync/$a/check-ok.$1"
  done < <(grep -o '"appAlias"[[:space:]]*:[[:space:]]*"[^"]*"' "$root/apex-sync.json" 2>/dev/null \
           | sed 's/.*"\([^"]*\)"$/\1/' | tr -d '\r')
  return 0
}

# The single exit path. The verdict is persisted HERE, and the freshness marker the
# hook trusts is written here and nowhere else: after the verdict line, the deploy
# payload and everything else the run printed, after the result file says PASS, and
# only when the run actually ended in a check PASS. A crash after the PASS line (an
# unreadable state.json, a full disk) therefore never leaves the gate open — it ends
# UNKNOWN, exit 3, no marker.
on_exit() {
  local rc=$? t f
  set +e
  if [[ -n "$R_OP" ]]; then
    if [[ -z "$R_STATUS" ]]; then
      if (( rc >= 128 )); then t=INTERRUPTED; else t=UNEXPECTED_ERROR; fi
      classify UNKNOWN "$t" "$R_OP ended (exit $rc) before reaching a verdict; nothing is authorized."
      echo "apex-sync-guard: ERROR: $R_OP ended (exit $rc) before reaching a verdict — UNKNOWN ($R_REASON); nothing is authorized." >&2
    elif [[ "$R_STATUS" == PASS && $rc -ne 0 ]]; then
      classify UNKNOWN UNEXPECTED_ERROR "$R_OP reached PASS ($R_REASON), then failed (exit $rc); nothing is authorized, re-run it."
      echo "apex-sync-guard: ERROR: $R_OP reached PASS, then failed (exit $rc) — UNKNOWN ($R_REASON); nothing is authorized, re-run it." >&2
    fi
    case "$R_STATUS" in PASS) rc=0 ;; FAIL|CONFLICT) rc=1 ;; BLOCKED) rc=2 ;; *) rc=3 ;; esac
    if [[ "$R_OP" == check-* && "$R_STATUS" != PASS ]]; then withdraw_markers "${R_OP#check-}"; fi
    if (( ${#RESULT_FILES[@]} )); then
      if write_results; then
        for f in "${RESULT_FILES[@]}"; do note "result: $f"; done
      elif [[ "$R_STATUS" == PASS ]]; then
        # The placeholder (UNKNOWN) stays behind, which is the truth now.
        classify UNKNOWN UNEXPECTED_ERROR "the PASS could not be written to its result file"; rc=3
        echo "apex-sync-guard: ERROR: could not write the result file — UNKNOWN; no marker, the hook keeps blocking." >&2
      else
        echo "apex-sync-guard: WARNING: could not write the result file(s): ${RESULT_FILES[*]}" >&2
      fi
    fi
    if [[ "$R_STATUS" == PASS && "$R_OP" == check-* ]]; then
      if ! write_marker "${R_OP#check-}"; then
        rm -f "$STATE_DIR/check-ok.${R_OP#check-}"
        classify UNKNOWN UNEXPECTED_ERROR "the PASS could not be turned into the hook's freshness marker"; rc=3
        (( ${#RESULT_FILES[@]} )) && write_results
        echo "apex-sync-guard: ERROR: could not write the freshness marker — UNKNOWN; the hook will keep blocking." >&2
      fi
    fi
  fi
  f=(); for t in "${TMPS[@]:-}"; do [[ -n "$t" && "$t" != "$TMP_KEEP" ]] && f+=("$t"); done
  (( ${#f[@]} )) && rm -rf "${f[@]}"
  exit "$rc"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# ------------------------------------------------------------ arguments
# Parsed before any setup, so a usage error never depends on SQLcl or a parser.
SELF=${0##*/}
USAGE="usage: $SELF check-import|check-export|record-sync|status|doctor|apps [--app <alias>] [--task <id>] [--force]"
SUB=""; OPT_FORCE=0; OPT_TASK=""; OPT_APP=""
while (( $# )); do
  case "$1" in
    --force)   OPT_FORCE=1 ;;
    --app)     [[ -n "${2:-}" ]] || die "--app needs a value — $USAGE"; OPT_APP=$2; shift ;;
    --app=*)   OPT_APP=${1#--app=}; [[ -n "$OPT_APP" ]] || die "--app needs a value — $USAGE" ;;
    --task)    [[ -n "${2:-}" ]] || die "--task needs a value — $USAGE"; OPT_TASK=$2; shift ;;
    --task=*)  OPT_TASK=${1#--task=}; [[ -n "$OPT_TASK" ]] || die "--task needs a value — $USAGE" ;;
    -h|--help) echo "$USAGE"; exit 0 ;;
    -*)        die "unknown option: $1 — $USAGE" ;;
    *)         [[ -z "$SUB" ]] || die "unexpected argument: $1 — $USAGE"; SUB=$1
               case "$SUB" in check-import|check-export|record-sync) R_OP=$SUB ;; esac ;;
  esac
  shift
done
case "$SUB" in
  check-import|check-export|record-sync) R_OP=$SUB ;;
  status|doctor|apps) ;;
  *) die "$USAGE" ;;
esac
(( OPT_FORCE == 0 )) || [[ "$SUB" == record-sync ]] || die "--force is only valid with record-sync"
# A task id names a directory under the evidence dir: nothing that could leave it.
RE_TASK='^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
if [[ -n "$OPT_TASK" ]]; then
  [[ -n "$R_OP" ]] || die "--task is only valid with check-import, check-export or record-sync"
  [[ "$OPT_TASK" =~ $RE_TASK ]] || die "--task must match $RE_TASK (got '$OPT_TASK')"
fi

# ---------------------------------------------------------------- setup
[[ -n "${BASH_VERSION:-}" ]] || die "run this under bash (on Windows: Git Bash or WSL — PowerShell and cmd cannot execute it)"
case "${OSTYPE:-}" in
  msys*|cygwin*) command -v cygpath >/dev/null 2>&1 || blocked UNSUPPORTED_SHELL "cygpath not found — run this from Git Bash (Git for Windows), not from a bare MSYS shell" ;;
esac
# apex-sync.json is read by lib/sync-config.sh, shared with the hook. Found next to
# the real file even when this one is reached through a symlink.
_self=${BASH_SOURCE[0]}
while [[ -L "$_self" ]]; do
  _d=$(cd -P "$(dirname "$_self")" && pwd); _self=$(readlink "$_self"); [[ "$_self" == /* ]] || _self="$_d/$_self"
done
case "$_self" in */*) _d=${_self%/*}; _d=${_d:-/} ;; *) _d=. ;; esac   # dirname
_here=$PWD; CDPATH='' cd -P -- "$_d"; SCRIPT_DIR=$PWD; cd -- "$_here"
# shellcheck source=skills/apex-sync-guard/scripts/lib/sync-config.sh
. "$SCRIPT_DIR/lib/sync-config.sh" || die "incomplete installation: $SCRIPT_DIR/lib/sync-config.sh is missing"
[[ -z "$OPT_APP" || "$OPT_APP" =~ $RE_APP_ALIAS ]] || die "--app must be an app alias ($RE_APP_ALIAS) — got '$OPT_APP'"
case "$SUB" in   # doctor reports a missing SQLcl instead of dying on it; apps never needs it
  check-import|check-export|record-sync|status) command -v sql >/dev/null || blocked NO_SQLCL "SQLcl (sql) is required on PATH" ;;
esac

# The JSON parser is resolved ONCE and by EXECUTION, never by `command -v`:
# on Windows the Microsoft Store `python3` stub satisfies `command -v` and then
# exits without running anything, which surfaced as a cryptic exit deep in a run.
resolve_json_tool() {
  local c cand=()
  if command -v jq >/dev/null 2>&1 && jq -e . <<<'{}' >/dev/null 2>&1; then
    JSON_TOOL=(jq); return 0
  fi
  for c in "python3" "python" "py -3"; do
    read -ra cand <<<"$c"
    command -v "${cand[0]}" >/dev/null 2>&1 || continue
    "${cand[@]}" -c 'import json' >/dev/null 2>&1 && { JSON_TOOL=("${cand[@]}"); return 0; }
  done
  return 1
}
JSON_TOOL=()
resolve_json_tool || blocked NO_JSON_PARSER "no working JSON parser — need jq, or a python that actually runs.
      A 'python3' that exists but does nothing when executed is typically the
      Microsoft Store stub: install real Python (or jq) and put it ahead of it on PATH."

JG=""
json_get() {  # $1 = json file ('-' = stdin), $2 = dotted key path → JG; non-zero if it cannot be read
  if [[ "${JSON_TOOL[0]}" == "jq" ]]; then
    JG=$(jq -r ".$2 // empty" "$1") || return
  else
    JG=$("${JSON_TOOL[@]}" -c '
import json, sys
src = sys.stdin if sys.argv[1] == "-" else open(sys.argv[1])
data = json.load(src)
for k in sys.argv[2].split("."):
    data = data.get(k) if isinstance(data, dict) else None
    if data is None: break
print("" if data is None else data)' "$1" "$2") || return
  fi
  JG=${JG//$'\r'/}      # native tooling on Windows writes CRLF
}

_rp=$(git rev-parse --show-toplevel --absolute-git-dir 2>/dev/null) || blocked NO_GIT "not inside a git repository"
ROOT=${_rp%%$'\n'*}; GIT_DIR_ABS=${_rp#*$'\n'}
# A linked worktree's git dir names the shared one in its `commondir` file (GAP-7): the
# syncpoint lives there, next to the shared ref; this worktree's markers stay in its own.
GIT_COMMON=$GIT_DIR_ABS
if [[ -f "$GIT_DIR_ABS/commondir" ]]; then
  read -r _cd < "$GIT_DIR_ABS/commondir" || _cd=""; _cd=${_cd%$'\r'}
  if [[ "$_cd" == /* || "$_cd" =~ ^[A-Za-z]: ]]; then GIT_COMMON=$_cd; else GIT_COMMON="$GIT_DIR_ABS/$_cd"; fi
  STATE_REL=".git/worktrees/${GIT_DIR_ABS##*/}"
fi
CFG="$ROOT/apex-sync.json"
[[ -f "$CFG" ]] || blocked NO_CONFIG "apex-sync.json not found at repo root ($ROOT) — see setup.md"

# ------------------------------------------------------------- config
cfg_load
if (( ${#CFG_ERRORS[@]} )) && [[ "$SUB" != doctor ]]; then
  blocked CONFIG_INVALID "apex-sync.json is invalid — nothing was checked:$(printf '\n      - %s' "${CFG_ERRORS[@]}")"
fi

# Which apps this run acts on. A gate acts on exactly one: with several declared,
# guessing would check one app and authorize an operation on another.
SEL=()
if (( ! ${#CFG_ERRORS[@]} )); then
  if [[ -n "$OPT_APP" ]]; then
    app_index "$OPT_APP" || blocked APP_UNKNOWN "apex-sync.json declares no app '$OPT_APP' — it declares: ${APPS_ALIAS[*]}"
    SEL=("$APP_I")
  elif (( ${#APPS_ALIAS[@]} == 1 )); then
    SEL=(0)
  elif [[ -n "$R_OP" ]]; then
    blocked APP_REQUIRED "apex-sync.json declares ${#APPS_ALIAS[@]} apps — name the one to $R_OP: --app <$(IFS='|'; echo "${APPS_ALIAS[*]}")>"
  else
    for (( _i = 0; _i < ${#APPS_ALIAS[@]}; _i++ )); do SEL+=("$_i"); done
  fi
fi

APP_ID=""; ALIAS=""; SRCDIR=""; SRC_REL=""; CONN=""; IGNORE_PATHS=(); EXPORT_SCOPE=()
select_app() {  # $1 = index into the APPS_* arrays; sets the per-app globals
  local i o
  APP_ID=${APPS_ID[$1]}; ALIAS=${APPS_ALIAS[$1]}; SRCDIR=${APPS_DIR[$1]}; CONN=${APPS_CONN[$1]}
  app_src "$1"; SRC_REL=$SR             # the app's source dir, repo-relative
  # Paths (relative to the app dir) that exist only on one side by design,
  # e.g. repo-only artifacts like "apex-exports/". Excluded from comparisons.
  # (while-read, not mapfile: macOS ships bash 3.2)
  lines_of "${APPS_IGNORE[$1]}"; IGNORE_PATHS=(${LINES[@]+"${LINES[@]}"})
  # What an export may write over: the apexlangDir it is given — minus the dirs of
  # the other apps that share it, which an export of this app does not touch.
  EXPORT_SCOPE=("${SRCDIR:-.}")
  for (( i = 0; i < ${#APPS_ALIAS[@]}; i++ )); do
    (( i == $1 )) && continue
    app_src "$i"; o=$SR
    [[ -z "$SRCDIR" || "$o/" == "$SRCDIR/"* ]] && EXPORT_SCOPE+=(":(exclude)$o")
  done
  APP_SRC="$ROOT/$SRC_REL"
  STATE_DIR="$GIT_DIR_ABS/apex-sync/$ALIAS"       # this worktree: markers, last results
  STATE="$GIT_COMMON/apex-sync/$ALIAS/state.json"  # every worktree: the syncpoint
  REF="refs/apex-sync/$ALIAS"
  [[ -d "$STATE_DIR" ]] || mkdir -p "$STATE_DIR"
  [[ -d "${STATE%/*}" ]] || mkdir -p "${STATE%/*}"
  # BASE round-trips through git objects (add → write-tree → archive). Content
  # filters would rewrite the bytes on the way in or out, so every git call that
  # stores or restores a replica runs with them off and with attribute lookup
  # pinned to an empty file — the syncpoint must return exactly what was exported.
  : > "$STATE_DIR/empty-attributes"
  GIT_HERMETIC=(-c core.autocrlf=false -c core.eol=lf -c core.safecrlf=false
                -c "core.attributesfile=$STATE_DIR/empty-attributes")
}
APP_SRC=""; STATE_DIR=""; STATE=""; REF=""; GIT_HERMETIC=()
export GIT_ATTR_NOSYSTEM=1
[[ -z "$R_OP" ]] || select_app "${SEL[0]}"


# ------------------------------------------------------------ sql layer
run_sql() {  # stdin-less silent SQLcl; $1 = statements; prints raw output
  sql -S -name "$CONN" <<EOF
set heading off feedback off pagesize 0 verify off trimspool on define off
whenever sqlerror exit 1
$1
exit
EOF
}

# Does the app exist in the target workspace at all?
#
# A workspace that has never received this app is not a failure mode: there is
# no second replica, so the premise of this whole gate — Builder-side work that
# an import would silently overwrite — is absent. Without this, export_builder
# died on the empty scratch dir and check-import could never PASS, which made
# the guard block the only operation able to populate the workspace. That is
# exactly the shape of a fresh PROD deploy: create the workspace, then publish.
# Three outcomes, not two, and the difference is the whole point:
#   0 = the app is there        1 = definitively absent        2 = cannot tell
#
# Only a clean numeric 0 counts as absent. An empty answer, a SQLcl error or
# anything non-numeric returns 2 and the caller takes the normal path, which
# ends in an informative die if the export really is empty. Collapsing this to
# a two-way `[[ "$n" == "1" ]]` made every unreadable answer look like "no app
# here", i.e. it opened the gate on failure — the exact mistake this script
# warns about where it refuses to wave a call through without a JSON parser.
remote_app_exists() {
  local n rc=0 q="select count(*) from apex_applications where application_id=$APP_ID"
  n=$(run_sql "select /* apex-sync-appcount */ count(*) from apex_applications where application_id=$APP_ID;") || rc=1
  n=${n//[[:space:]]/}
  # Only a clean count is kept as evidence: an error text can carry a hostname.
  if (( rc == 0 )) && [[ "$n" =~ ^[0-9]+$ ]]; then evidence sql 0 "$q" "$n"; else evidence sql "$rc" "$q" "unreadable"; fi
  (( rc == 0 )) || return 2
  case "$n" in
    0)            return 1 ;;
    ''|*[!0-9]*)  return 2 ;;
    *)            return 0 ;;
  esac
}

# Latest Builder modification the dictionary can see. Best-effort: APEXlang
# import recreates components with NULL audit columns, so right after an
# import this is 'unavailable' until someone edits in the Builder. The guard's
# core check (export+diff vs BASE) does not depend on it — this only feeds
# the who/when report.
BS=""
builder_stamp() {  # → BS
  local s
  s=$(run_sql "select to_char(greatest(
             nvl((select max(last_updated_on) from apex_application_pages where application_id=$APP_ID), date '1900-01-01'),
             nvl((select last_updated_on from apex_applications where application_id=$APP_ID), date '1900-01-01')
           ),'YYYY-MM-DD\"T\"HH24:MI:SS') from dual;") || :      # best effort: who/when only
  s=${s//[[:space:]]/}
  [[ "$s" == 1900-01-01* ]] && s="unavailable"
  BS=$s
}

pages_changed_since() {  # $1 = stamp 'YYYY-MM-DD"T"HH24:MI:SS' (skipped if unavailable)
  [[ "$1" == "unavailable" ]] && { echo "    (Builder audit timestamps unavailable — see diff above for the authoritative list)"; return 0; }
  run_sql "select '    p'||lpad(page_id,5,'0')||'  '||rpad(substr(page_name,1,38),40)||nvl(last_updated_by,'?')||'  '||to_char(last_updated_on,'YYYY-MM-DD HH24:MI')
           from apex_application_pages
           where application_id=$APP_ID
             and last_updated_on > to_date('$1','YYYY-MM-DD\"T\"HH24:MI:SS')
           order by last_updated_on;"
}

# The three helpers below run in THIS shell and hand their result back in a
# global, never through $(...): bash clears errexit inside a command
# substitution, so a failed step there went unnoticed (a git failure printed
# "syncpoint recorded" with an empty commit), and the TMPS+= they did was lost
# with the subshell, so every scratch export leaked into $TMPDIR.
REMOTE_DIR=""     # export_builder: scratch dir holding the Builder export (<alias>/…)
BASE_APP_DIR=""   # materialize_base: the BASE tree's <alias>/ dir
SNAP_COMMIT=""    # snapshot_export: the syncpoint commit just recorded

export_builder() {  # exports REMOTE (the Builder) to a scratch dir; sets REMOTE_DIR
  local scratch native; scratch=$(mktemp -d "${TMPDIR:-/tmp}/apex-sync-remote-XXXXXX"); TMPS+=("$scratch")
  native_path "$scratch"; native=$NP
  # Quoted only when it has to be: how SQLcl's `apex export -dir` tokenizes a path
  # with spaces is unverified here, so the quoting is a best effort and the error
  # below points at TMPDIR if it still fails.
  [[ "$native" == *" "* ]] && native="\"$native\""
  # The same session reports which SQLcl and which APEX produced the export — for
  # the result's evidence, never for the verdict: after the export, so neither line
  # can stop it, and under `sqlerror continue`, so neither can fail it.
  local out rc=0
  out=$(run_sql "apex export -applicationid $APP_ID -expType APEXLANG -dir $native
whenever sqlerror continue
version
select 'apex-sync-apex-version '||version_no from apex_release;") || rc=$?
  evidence command "$rc" "apex export -applicationid $APP_ID -expType APEXLANG -dir <scratch>"
  (( rc == 0 )) || unknown EXPORT_FAILED "the Builder export failed (SQLcl exited non-zero) — check the connection with: $SELF doctor"
  local l re_sqlcl='\(SQLcl\) version: .* build: *([0-9][0-9.]*[0-9])' re_apex='^[[:space:]]*apex-sync-apex-version ([0-9][0-9.]*[0-9])'
  lines_of "${out//$'\r'/}"
  for l in ${LINES[@]+"${LINES[@]}"}; do        # the first line that names each
    [[ -z "$R_SQLCL_VERSION" && "$l" =~ $re_sqlcl ]] && R_SQLCL_VERSION=${BASH_REMATCH[1]}
    [[ -z "$R_APEX_VERSION" && "$l" =~ $re_apex ]] && R_APEX_VERSION=${BASH_REMATCH[1]}
  done
  [[ -f "$scratch/$ALIAS/application.apx" ]] || unknown EXPORT_FAILED "the Builder export produced no $ALIAS/application.apx in $scratch (SQLcl was given -dir $native) — check the connection and app id; if app $APP_ID does not exist in the workspace yet, remote_app_exists should have caught it before here; if that path holds spaces, point TMPDIR at one that does not"
  REMOTE_DIR=$scratch
}

# ------------------------------------------------------------ git layer
have_base() { git -C "$ROOT" rev-parse -q --verify "$REF" >/dev/null; }

materialize_base() {  # extracts the BASE tree to a scratch dir; sets BASE_APP_DIR
  local t; t=$(mktemp -d "${TMPDIR:-/tmp}/apex-sync-base-XXXXXX"); TMPS+=("$t")
  # An empty BASE would hide a page deleted in the Builder (missing on both sides),
  # so a failed extraction stops the check instead of comparing against nothing.
  # -m: mtimes are irrelevant to a byte comparison, and restoring them only made tar
  # warn "time stamp in the future" when the syncpoint commit was seconds old.
  git -C "$ROOT" "${GIT_HERMETIC[@]}" archive "$REF" | tar -x -m -C "$t" \
    || unknown UNEXPECTED_ERROR "could not extract the syncpoint $REF"
  [[ -d "$t/$ALIAS" ]] || unknown UNEXPECTED_ERROR "the syncpoint $REF holds no $ALIAS/ tree"
  BASE_APP_DIR="$t/$ALIAS"
}

# BASE is always snapshotted from an `apex export` scratch dir, never from the
# raw working tree: hand-edited .apx differ textually (whitespace, fenced vs
# inline blocks, JSON spacing) from the exporter's canonical serialization, so
# only canonical-vs-canonical comparisons are noise-free.
snapshot_export() {  # $1 = scratch dir containing <alias>/…; commits it to $REF; sets SNAP_COMMIT
  local tmpidx tree="" commit=""
  now_iso
  tmpidx=$(mktemp -u "${TMPDIR:-/tmp}/apex-sync-idx-XXXXXX"); TMPS+=("$tmpidx")
  # Every step is checked, and the ref is read back: "recorded" must mean the ref
  # really points at the new commit (commit-tree fails without a git identity).
  if ! { GIT_INDEX_FILE=$tmpidx git "${GIT_HERMETIC[@]}" --git-dir="$ROOT/.git" --work-tree="$1" add -f -A -- . 2>/dev/null \
         && tree=$(GIT_INDEX_FILE=$tmpidx git --git-dir="$ROOT/.git" write-tree) \
         && commit=$(git -C "$ROOT" commit-tree "$tree" -m "apex-sync syncpoint $ALIAS $ISO") \
         && git -C "$ROOT" update-ref "$REF" "$commit" \
         && [[ -n "$commit" && "$(git -C "$ROOT" rev-parse -q --verify "$REF^{commit}")" == "$commit" ]]; }; then
    evidence command 1 "git commit-tree + git update-ref $REF"
    unknown SNAPSHOT_FAILED "could not record the syncpoint in $REF (a git step failed — is user.name/user.email configured in this repo?)"
  fi
  rm -f "$tmpidx"
  evidence command 0 "git commit-tree + git update-ref $REF" "$commit"
  SNAP_COMMIT=$commit; R_RECORDED=1
}

# ------------------------------------------------------- content comparison
# Deliberately NOT `git diff --no-index`: git applies .gitattributes and
# core.autocrlf to whichever side it resolves inside the repo and not to the
# scratch export, so its verdict tracked the user's git config instead of the
# bytes — on Windows core.autocrlf=true alone makes a CRLF and an LF file
# compare equal, and an anchored `text eol=lf` pattern makes the same pair
# compare equal one way and differ the other. The gate needs bytes.

list_files() { (cd "$1" 2>/dev/null && find . -type f | sed 's|^\./||' | LC_ALL=C sort); }

# `cmp` is not guaranteed everywhere this runs (Git for Windows ships a lean
# userland), and assuming a tool is present is the mistake this skill just paid
# for elsewhere. git is a hard requirement and `hash-object --no-filters` is
# byte-exact by definition, so it is the fallback.
BYTES_EQ=""
bytes_eq_tool() {  # → BYTES_EQ, probed on first use (an export check compares nothing)
  [[ -n "$BYTES_EQ" ]] && return 0
  if cmp -s /dev/null /dev/null 2>/dev/null; then BYTES_EQ="cmp"; else BYTES_EQ="git-hash"; fi
}

bytes_equal() {
  bytes_eq_tool
  if [[ "$BYTES_EQ" == cmp ]]; then cmp -s "$1" "$2"
  else [[ "$(git hash-object --no-filters -- "$1")" == "$(git hash-object --no-filters -- "$2")" ]]; fi
}

eol_equal() {  # equal once every CR is dropped
  bytes_eq_tool
  if [[ "$BYTES_EQ" == cmp ]]; then cmp -s <(tr -d '\r' < "$1") <(tr -d '\r' < "$2")
  else [[ "$(tr -d '\r' < "$1" | git hash-object --no-filters --stdin)" \
       == "$(tr -d '\r' < "$2" | git hash-object --no-filters --stdin)" ]]; fi
}

same_content() {  # 0 = identical bytes, 2 = differs only in line endings, 1 = differs
  bytes_equal "$1" "$2" && return 0
  case "$1" in                                  # never normalize a binary
    *.apx|*.sql|*.js|*.css|*.md|*.json|*.txt|*.xml|*.html|*.yml|*.yaml) ;;
    *) return 1 ;;
  esac
  eol_equal "$1" "$2" && return 2
  return 1
}

ignored() {  # $1 = app-relative path; an entry matches whole path segments only
  local p
  for p in "${IGNORE_PATHS[@]:-}"; do
    p=${p%/}
    # A raw prefix match let an entry like "p" hide "p30.apx" and all of "pages/".
    [[ -n "$p" && ( "$1" == "$p" || "$1" == "$p/"* ) ]] && return 0
  done
  return 1
}

TD=""
tree_diff() {  # $1=dirA $2=dirB → TD: "<status>\t<app-relative path>" lines, ignorePaths filtered
  local f rc out="" i j=0 n=0 na nb list="" files=() kind=() hs=()
  # Both listings through one sort, './' kept until after it: it does not change the
  # order, and list_files twice cost a sed and a sort each.
  while IFS= read -r f; do
    f=${f#./}
    [[ -z "$f" ]] && continue
    ignored "$f" && continue
    files+=("$f")
    if   [[ ! -e "$2/$f" ]]; then kind+=(D)          # D = only in A, A = only in B,
    elif [[ ! -e "$1/$f" ]]; then kind+=(A)          # M = differs, E = EOL only
    elif [[ -f "$1/$f" && ! -L "$1/$f" && -f "$2/$f" && ! -L "$2/$f" ]]; then kind+=(H); n=$((n + 1))
    else kind+=(C)                                   # a symlink or a dir on one side
    fi
  done < <( { (cd "$1" 2>/dev/null && exec find . -type f); (cd "$2" 2>/dev/null && exec find . -type f); } | LC_ALL=C sort -u )
  # A regular file on both sides is hashed, all of them by one git: a cmp per file was a
  # process per file, and an app has hundreds. Equal hashes are equal bytes; anything
  # else — or a git that fails — goes through same_content, which also tells E from M.
  # The paths go to git on stdin, where MSYS converts nothing: native form first.
  if (( n )); then
    native_path "$1"; na=$NP; native_path "$2"; nb=$NP
    for (( i = 0; i < ${#files[@]}; i++ )); do
      [[ "${kind[$i]}" == H ]] && list+="$na/${files[$i]}"$'\n'"$nb/${files[$i]}"$'\n'
    done
    lines_of "$(git hash-object --no-filters --stdin-paths <<<"${list%$'\n'}" 2>/dev/null || :)"
    if (( ${#LINES[@]} == 2 * n )); then hs=("${LINES[@]}"); fi
  fi
  for (( i = 0; i < ${#files[@]}; i++ )); do
    f=${files[$i]}
    case "${kind[$i]}" in
      D) out+="D"$'\t'"$f"$'\n'; continue ;;
      A) out+="A"$'\t'"$f"$'\n'; continue ;;
      H) j=$((j + 2))
         if (( ${#hs[@]} )) && [[ "${hs[$((j - 2))]}" == "${hs[$((j - 1))]}" ]]; then continue; fi ;;
    esac
    rc=0; same_content "$1/$f" "$2/$f" || rc=$?
    case $rc in 0) ;; 2) out+="E"$'\t'"$f"$'\n' ;; *) out+="M"$'\t'"$f"$'\n' ;; esac
  done
  TD=${out%$'\n'}
}

# A line-ending-only difference cannot carry a Builder-side change, and blocking
# on it would deadlock: every re-export reintroduces it. So E is reported, never gated.
BL=""
blocking() {  # $1 = tree_diff lines → BL: the ones that gate
  local l out=""
  lines_of "${1:-}"
  for l in ${LINES[@]+"${LINES[@]}"}; do [[ "$l" == $'E\t'* ]] || out+="$l"$'\n'; done
  BL=${out%$'\n'}
}

indent() { local l; while IFS= read -r l; do printf '    %s\n' "$l"; done; }

eol_note() {  # $1 = tree_diff output
  [[ $'\n'"${1:-}" == *$'\nE\t'* ]] || return 0
  echo "  Note: the files marked E differ only in line endings — not a Builder change, so they do not gate."
  echo "        To silence them, add to this repo's .gitattributes:  *.apx text eol=lf"
}

# The guard's other direction. check-import answers "does the Builder hold work an
# import would destroy?" — it says nothing about what the import DEPLOYS. Since
# `apex import` replaces the whole app, a silent PASS can push a backlog that
# accumulated over days, changing behaviour nobody was expecting to change today.
# Reported, never gating: every legitimate import has a payload.
payload_report() {  # $1 = materialized BASE app dir
  local dif n recorded="" commits head="" log
  tree_diff "$1" "$APP_SRC"; blocking "$TD"; dif=$BL
  lines_of "$dif"; n=${#LINES[@]}
  repo_rel "$dif"; R_PAYLOAD=$RR; R_PAYLOAD_SET=1
  echo ""
  if (( n == 0 )); then
    note "Nothing to deploy: LOCAL matches the syncpoint (if you expected changes, they were not generated/saved)."
    return 0
  fi
  if [[ -f "$STATE" ]]; then json_get "$STATE" recordedAt; recorded=$JG; json_get "$STATE" headCommit; head=$JG; fi
  # Count from the recorded revision, not from a timestamp: --since has one-second
  # granularity, so a commit made in the same second as the syncpoint was counted
  # or not depending on how fast the machine ran. Falls back to --since for state
  # files written before headCommit existed.
  # Counted here, one line per commit — `| grep -c . || echo "?"` once printed BOTH the
  # count and the fallback (grep exits 1 on a zero count), splitting the line in two.
  if [[ -n "$head" ]] && git -C "$ROOT" rev-parse -q --verify "$head^{commit}" >/dev/null 2>&1; then
    log=$(git -C "$ROOT" log --oneline "$head..HEAD" -- "$SRC_REL"); lines_of "$log"; commits=${#LINES[@]}
  elif [[ -n "$recorded" ]]; then
    log=$(git -C "$ROOT" log --oneline --since="$recorded" -- "$SRC_REL"); lines_of "$log"; commits=${#LINES[@]}
  else
    commits="?"
  fi
  R_PAYLOAD_COMMITS=$commits
  note "This import DEPLOYS the accumulated LOCAL backlog — \`apex import\` replaces the WHOLE app:"
  note "(A = new in LOCAL, M = differs, D = removed from LOCAL)"
  indent <<<"$dif"
  note "$n file(s), $commits commit(s) touching $SRC_REL since the syncpoint${recorded:+ ($recorded)}"
  note "(may include formatting-only entries: LOCAL is hand-edited, BASE is the exporter's canonical form)"
}

write_marker() {  # $1 = import|export — fails when the marker could not be written
  now_iso
  printf '{"check":"%s","at":"%s"}\n' "$1" "$ISO" > "$STATE_DIR/check-ok.$1" || return 1
  # Printed on purpose: the hook resolves the repo from the tool payload's cwd
  # and this script from its own, so a check run inside a command that `cd`s
  # elsewhere leaves the marker where the hook will not look. Showing both
  # halves of that path turns a silent mismatch into a one-line comparison.
  note "marker: $STATE_DIR/check-ok.$1"
}

SS=""
stored_stamp() { SS=""; if [[ -f "$STATE" ]]; then json_get "$STATE" builderStamp; SS=$JG; fi; }   # → SS

write_state() {  # $1 = syncpoint commit, $2 = builder stamp, $3 = basis (record-sync) or bootstrap
  # headCommit pins the payload's commit count to a revision instead of a clock:
  # `git log --since=<recordedAt>` has one-second granularity, so a commit made in
  # the same second as the syncpoint was counted or not depending on timing.
  local head; head=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo "")
  now_iso
  printf '{"appId":%s,"appAlias":"%s","sqlclConnection":"%s","syncpoint":"%s","builderStamp":"%s","recordedAt":"%s","headCommit":"%s","basis":"%s"}\n' \
    "$APP_ID" "$ALIAS" "$CONN" "$1" "$2" "$ISO" "$head" "${3:-bootstrap}" > "$STATE"
}

# ------------------------------------------------------------ sync-result
# The machine-readable verdict: framework/schemas/sync-result.schema.json, written
# in plain bash (no parser is needed to WRITE JSON). What the verdict rests on is
# collected while the run goes:
R_CHANGES=""            # "<A|D|M|E><TAB><repo-relative path>" lines
R_PAYLOAD=""; R_PAYLOAD_SET=0; R_PAYLOAD_COMMITS=""
R_BASIS=""; R_RECORDED=0
R_SQLCL_VERSION=""; R_APEX_VERSION=""
R_EVIDENCE=""           # "<command|sql><US><exit code><US><text><US><result>" lines
US=$'\x1f'             # unit separator: never in a path or a statement, and IFS does not collapse it

evidence() { R_EVIDENCE+="$1$US$2$US$3$US${4:-}"$'\n'; }   # $1 kind, $2 exit code, $3 text, $4 result

RR=""
repo_rel() {  # $1 = tree_diff lines (app-relative) → RR: the same lines, repo-relative
  local l f out=""
  lines_of "${1:-}"
  for l in ${LINES[@]+"${LINES[@]}"}; do
    [[ "$l" == *$'\t'* ]] || continue
    f=${l#*$'\t'}
    [[ -n "$f" ]] && out+="${l%%$'\t'*}"$'\t'"$SRC_REL/$f"$'\n'
  done
  RR=${out%$'\n'}
}

# Sets J to $1 as a JSON string literal — a global, not $(...): it runs once per
# changed file, and a fork per file is slow under Git Bash. Control characters other
# than \n \r \t become \u00XX.
jstr() {
  local s=$1 out="" c i LC_ALL=C
  s=${s//\\/\\\\}; s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}; s=${s//$'\r'/\\r}; s=${s//$'\t'/\\t}
  if [[ "$s" == *[$'\001'-$'\037']* ]]; then
    for (( i = 0; i < ${#s}; i++ )); do
      c=${s:i:1}
      case "$c" in [$'\001'-$'\037']) printf -v c '\\u%04x' "'$c" ;; esac
      out+=$c
    done
    s=$out
  fi
  J="\"$s\""
}

# Free text (messages, recorded commands) is redacted before it is encoded: a result is
# evidence that may be shared, and a home path names the user. The repo root becomes
# <repo>/ and $HOME/ becomes ~/ — in the shell's form and in the C:/… form native tools
# print — only where a path begins (after a space, a quote, a bracket, = or :), so a
# relative path that merely contains the same letters is left alone.
REDACT=()
redact_add() {  # $1 = a path, $2 = what stands for it — in the shell's form and in the C:/… form
  local n=""
  [[ -n "$1" ]] || return 0
  REDACT+=("$1" "$2")
  if command -v cygpath >/dev/null 2>&1; then n=$(cygpath -m "$1" 2>/dev/null) || n=""; fi
  [[ -n "$n" && "$n" != "$1" ]] && REDACT+=("$n" "$2")
  return 0
}
jtext() {
  local s=$1 out pre p rep i
  if (( ! ${#REDACT[@]} )); then
    redact_add "$ROOT" "<repo>"
    [[ "${HOME:-}" != / ]] && redact_add "${HOME:-}" "~"
    REDACT+=("" "")
  fi
  for (( i = 0; i + 1 < ${#REDACT[@]}; i += 2 )); do
    p=${REDACT[$i]}; rep=${REDACT[$((i + 1))]}
    [[ -n "$p" ]] || continue
    out=""
    while [[ "$s" == *"$p/"* ]]; do
      pre=${s%%"$p/"*}; s=${s#*"$p/"}
      case "${pre: -1}" in
        ""|" "|"("|"'"|'"'|"="|":"|"["|$'\t'|$'\n') out+="$pre$rep/" ;;
        *) out+="$pre$p/" ;;
      esac
    done
    s=$out$s
  done
  jstr "$s"
}
jstr_or_null() { if [[ -n "$1" ]]; then jstr "$1"; else J=null; fi; }

JC=""
json_changes() {  # $1 = "<status><TAB><path>" lines → JC, a JSON array
  local l f out="" sep=""
  lines_of "${1:-}"
  for l in ${LINES[@]+"${LINES[@]}"}; do
    [[ "$l" == *$'\t'* ]] || continue
    f=${l#*$'\t'}
    [[ -z "$f" ]] && continue
    jstr "$f"; out+="$sep{\"status\": \"${l%%$'\t'*}\", \"path\": $J}"; sep=", "
  done
  JC="[$out]"
}

JE=""
json_evidence() {  # → JE, a JSON array of R_EVIDENCE
  local l kind rc text res out="" sep="" key rkey
  lines_of "$R_EVIDENCE"
  for l in ${LINES[@]+"${LINES[@]}"}; do
    kind=${l%%"$US"*}; l=${l#*"$US"}; rc=${l%%"$US"*}; l=${l#*"$US"}; text=${l%%"$US"*}; res=${l#*"$US"}
    [[ -z "$kind" ]] && continue
    case "$kind" in sql) key="statement"; rkey="result" ;; *) key="command"; rkey="output" ;; esac
    jtext "$text"; out+="$sep{\"kind\": \"$kind\", \"$key\": $J, \"exitCode\": $rc"
    if [[ -n "$res" ]]; then jtext "$res"; out+=", \"$rkey\": $J"; fi
    out+="}"; sep=", "
  done
  JE="[$out]"
}

iso_in() {  # $1 = seconds from now → ISO, UTC (GNU date, else BSD date)
  local e
  epoch_now; e=$(( ${EPOCH:-0} + $1 ))
  if (( PRINTF_T )); then TZ=UTC0 printf -v ISO '%(%Y-%m-%dT%H:%M:%SZ)T' "$e"
  else ISO=$(date -u -d "@$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$e" +%Y-%m-%dT%H:%M:%SZ) || ISO=""; fi
}

# The working tree as `git add -A` would commit it — tracked and untracked files, ignored
# ones left out — hashed through a copy of the index, so the real index is never touched
# (GAP-8: a result is fresh only while the tree still hashes the same). The same hash
# framework/lib/result.py records; "" when git cannot say.
WT=""
worktree_tree() {  # → WT
  local idx="$GIT_DIR_ABS/apex-sync-tree.$$.idx"
  WT=""
  rm -f "$idx"
  if [[ -f "$GIT_DIR_ABS/index" ]]; then cp "$GIT_DIR_ABS/index" "$idx" 2>/dev/null || true; fi
  if GIT_INDEX_FILE=$idx env -u GIT_ATTR_NOSYSTEM git -C "$ROOT" add -A >/dev/null 2>&1; then
    WT=$(GIT_INDEX_FILE=$idx env -u GIT_ATTR_NOSYSTEM git -C "$ROOT" write-tree 2>/dev/null) || WT=""
  fi
  rm -f "$idx" "$idx.lock"
  [[ "$WT" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || WT=""
  return 0
}

RJ=""; RES_HEAD=""; RES_MMD=""; RES_TREE=""; RES_ONCE=0
result_json() {  # → RJ: the sync-result for the current R_* state; never fails
  local d head dirty=false spc mmd tgt dir written=false exp=null rec=false pc=null st
  # Read once per run: the revision and the app's mmdVersion do not change while it runs.
  if (( ! RES_ONCE )); then
    RES_HEAD=$(git -C "$ROOT" rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null) || RES_HEAD=""
    if [[ -f "$APP_SRC/.apex/apexlang.json" ]] \
       && json_get "$APP_SRC/.apex/apexlang.json" mmdVersion 2>/dev/null; then   # what Oracle's skills route on
      RES_MMD=$JG
      [[ "$RES_MMD" =~ ^[0-9]+(\.[0-9]+)*(\+[0-9A-Za-z.-]+)?$ ]] || RES_MMD=""
    fi
    worktree_tree; RES_TREE=$WT
    RES_ONCE=1
  fi
  head=$RES_HEAD; mmd=$RES_MMD
  st=$(git -C "$ROOT" status --porcelain --untracked-files=normal 2>/dev/null) || st=""
  [[ -z "$st" ]] || dirty=true
  spc=$(git -C "$ROOT" rev-parse -q --verify "$REF^{commit}" 2>/dev/null) || spc=""
  d=$'{\n  "kind": "sync-result",\n  "schemaVersion": 1,\n'
  d+="  \"operation\": \"$R_OP\","$'\n'"  \"status\": \"$R_STATUS\","$'\n'
  jtext "$R_MESSAGE"; d+="  \"reasons\": [{\"code\": \"$R_REASON\", \"message\": $J}],"$'\n'
  jstr "$ALIAS"; d+="  \"app\": {\"appId\": $APP_ID, \"appAlias\": $J"
  [[ -n "$mmd" ]] && { jstr "$mmd"; d+=", \"mmdVersion\": $J"; }
  d+=$'},\n  "context": {\n'
  jstr_or_null "$OPT_TASK"; d+="    \"task\": $J,"$'\n'
  jstr_or_null "$head"; d+="    \"repo\": {\"commit\": $J, \"dirty\": $dirty"
  [[ -n "$RES_TREE" ]] && d+=", \"tree\": \"$RES_TREE\""
  d+="},"$'\n'
  d+="    \"frameworkVersion\": \"$FRAMEWORK_VERSION\","$'\n'
  now_iso; d+="    \"timestamp\": \"$ISO\","$'\n'
  d+=$'    "producer": {"skill": "apex-sync-guard", "method": "tool"},\n'
  jstr "$CONN"; tgt="\"connectionName\": $J"
  [[ -n "$R_SQLCL_VERSION" ]] && tgt+=", \"sqlclVersion\": \"$R_SQLCL_VERSION\""
  [[ -n "$R_APEX_VERSION" ]] && tgt+=", \"apexVersion\": \"$R_APEX_VERSION\""
  d+="    \"target\": {$tgt}"$'\n  },\n'
  if [[ "$R_OP" == check-* ]]; then
    dir=${R_OP#check-}
    [[ "$R_STATUS" == PASS ]] && { written=true; iso_in "$TTL_SECONDS"; exp="\"$ISO\""; }
    d+="  \"marker\": {\"written\": $written, \"path\": \"$STATE_REL/apex-sync/$ALIAS/check-ok.$dir\", \"ttlSeconds\": $TTL_SECONDS, \"expiresAt\": $exp},"$'\n'
  fi
  (( R_RECORDED )) && rec=true
  jstr_or_null "$spc"; d+="  \"syncpoint\": {\"ref\": \"$REF\", \"commit\": $J, \"recorded\": $rec},"$'\n'
  json_changes "$R_CHANGES"; d+="  \"changes\": $JC,"$'\n'
  if [[ "$R_OP" == check-import ]] && (( R_PAYLOAD_SET )); then
    [[ "$R_PAYLOAD_COMMITS" =~ ^[0-9]+$ ]] && pc=$R_PAYLOAD_COMMITS
    json_changes "$R_PAYLOAD"; d+="  \"payload\": {\"changes\": $JC, \"commits\": $pc},"$'\n'
  fi
  [[ "$R_OP" == record-sync && -n "$R_BASIS" ]] && d+="  \"basis\": \"$R_BASIS\","$'\n'
  json_evidence; d+="  \"evidence\": $JE"$'\n}'
  RJ=$d
}

write_results() {  # the current verdict → every result file, each replaced atomically
  local doc f
  result_json; doc=$RJ
  for f in "${RESULT_FILES[@]}"; do
    { printf '%s\n' "$doc" > "$f.tmp.$$" && mv -f "$f.tmp.$$" "$f"; } || { rm -f "$f.tmp.$$"; return 1; }
  done
  # The contract tier validates every result the integration suite makes the script emit.
  if [[ -n "${SYNC_RESULT_CAPTURE_DIR:-}" ]]; then
    printf '%s\n' "$doc" > "$SYNC_RESULT_CAPTURE_DIR/$$-$RANDOM-$R_OP.json" || true
  fi
}

# Once the app is known: where the result goes, and a placeholder there. Should the
# run die without reaching the EXIT trap (SIGKILL, power loss), the file says
# UNKNOWN — never the verdict of an earlier run.
results_init() {
  local ev="$ROOT/$EVIDENCE_DIR"
  RESULT_FILES=("$STATE_DIR/last-$R_OP.json")
  if [[ -n "$OPT_TASK" ]]; then
    # Created ignored: raw evidence is never committed by accident. Committing
    # some of it is an opt-in — the user edits this .gitignore.
    # Kept, not only created: an agent may have made the dir first. Edit the file to
    # opt in to committing a manifest — a deleted one comes back.
    if ! { mkdir -p "$ev" && { [[ -f "$ev/.gitignore" ]] || printf '*\n' > "$ev/.gitignore"; }; }; then
      blocked STATE_UNWRITABLE "cannot create the evidence dir $EVIDENCE_DIR"
    fi
    mkdir -p "$ev/$OPT_TASK" || blocked STATE_UNWRITABLE "cannot create $EVIDENCE_DIR/$OPT_TASK"
    RESULT_FILES+=("$ev/$OPT_TASK/sync-$ALIAS-$R_OP.json")
  fi
  classify UNKNOWN INTERRUPTED "the run did not finish: this is the placeholder written when it started."
  write_results || blocked STATE_UNWRITABLE "cannot write the result file(s): ${RESULT_FILES[*]}"
  classify "" ""
}

# ------------------------------------------------------------- commands
# The app's id lives in the source too: `apex import -input` takes it from
# deployments/default.json unless -id overrides it. When it disagrees with
# apex-sync.json, the guard would check one app while the import overwrites another.
SID=""
source_app_id() {  # → SID: app.id from deployments/default.json, if the file states one
  local dj="$APP_SRC/deployments/default.json"
  SID=""
  [[ -f "$dj" ]] || return 0
  if json_get "$dj" app.id 2>/dev/null; then SID=$JG; fi
}

require_source_dir() {
  [[ -d "$APP_SRC" ]] || blocked SOURCE_DIR_MISSING "the source dir $SRC_REL does not exist — check apexlangDir/appAlias in apex-sync.json (a first export needs: mkdir -p $SRC_REL)"
}

cmd_check_import() {
  revoke_marker import
  echo "apex-sync-guard: check-import (app $APP_ID '$ALIAS' via $CONN)"
  require_source_dir
  source_app_id; local sid=$SID
  if [[ -n "$sid" && "$sid" != "$APP_ID" ]]; then
    blocked APP_ID_MISMATCH "$SRC_REL/deployments/default.json says app $sid, apex-sync.json says $APP_ID — an import would target app $sid while this check compares app $APP_ID. Fix whichever is wrong."
  fi

  local app_rc=0; remote_app_exists || app_rc=$?
  if (( app_rc == 1 )); then
    # "Not visible" is only a first publication when there was never a sync. With a
    # syncpoint on record the same answer means the connection, the workspace or the
    # appId is wrong — or the app was deleted — and taking the shortcut would let an
    # import land on whatever app the source really names, unchecked.
    if have_base; then
      local was="" via=""; if [[ -f "$STATE" ]] && json_get "$STATE" sqlclConnection; then was=$JG; fi
      [[ -n "$was" ]] && via=", recorded via '$was'"
      blocked SYNCPOINT_WITHOUT_APP "app $APP_ID is not visible through '$CONN', but '$ALIAS' has a syncpoint ($(git -C "$ROOT" rev-parse --short "$REF")$via).
      Wrong saved connection, wrong workspace or wrong appId — or the app was deleted. Check with: $SELF doctor
      If this really is a first publication into a NEW workspace, the user (not an agent) sets the old syncpoint aside:
        git update-ref refs/apex-sync-saved/$ALIAS $REF && git update-ref -d $REF"
    fi
    pass FIRST_PUBLICATION "app $APP_ID does not exist in the target workspace — first publication."
    echo "  Nothing to overwrite: there is no second replica that could hold unexported"
    echo "  Builder work. Run record-sync right afterwards to create the first"
    echo "  syncpoint, so the next one is gated against a real BASE."
    return 0
  fi

  export_builder; local scratch=$REMOTE_DIR
  echo "  Builder exported to scratch: $scratch"

  if ! have_base; then
    echo "  No syncpoint yet — bootstrap mode: comparing BUILDER vs LOCAL working tree."
    echo "  (note: formatting-only differences are expected if .apx were hand-edited;"
    echo "   the Builder export is the canonical serialization)"
    local boot; tree_diff "$APP_SRC" "$scratch/$ALIAS"; boot=$TD
    repo_rel "$boot"; R_CHANGES=$RR
    blocking "$boot"
    if [[ -z "$BL" ]]; then
      local c s; builder_stamp; s=$BS; snapshot_export "$scratch"; c=$SNAP_COMMIT; write_state "$c" "$s"
      pass BOOTSTRAP_IN_SYNC "replicas already agree — first syncpoint recorded ($c). Safe to import."
      eol_note "$boot"
      return 0
    fi
    TMP_KEEP="$scratch"
    echo "  (D = only in LOCAL, A = only in BUILDER, M = differs, E = line endings only)"
    indent <<<"$boot"
    eol_note "$boot"
    fail CONFLICT BOOTSTRAP_DIVERGED "bootstrap: BUILDER ≠ LOCAL and there is no BASE to arbitrate. Reconcile once, file by file (Builder export kept at $scratch): where the Builder wins, copy its file into LOCAL and commit — check-import then PASSes and records the first syncpoint; where LOCAL must win, only the user can say the Builder holds nothing to keep: they run record-sync --force, then check-import, import, record-sync. See setup.md §2."
  fi

  materialize_base; local base=$BASE_APP_DIR dif; tree_diff "$base" "$scratch/$ALIAS"; dif=$TD
  repo_rel "$dif"; R_CHANGES=$RR
  blocking "$dif"
  if [[ -z "$BL" ]]; then
    pass BUILDER_UNCHANGED "Builder untouched since last syncpoint. Safe to import."
    eol_note "$dif"
    payload_report "$base"
    return 0
  fi

  # The Builder moved — but if every Builder-side change is already contained
  # in LOCAL (captured/merged earlier), importing loses nothing: it rewrites
  # those files identically. Without this, the gate would be circular: capture
  # the Builder changes, still FAIL, never import.
  local all_captured=1 _st f L R rc
  while IFS=$'\t' read -r _st f; do
    [[ -z "$f" || "$_st" == "E" ]] && continue
    L="$APP_SRC/$f"; R="$scratch/$ALIAS/$f"
    if [[ -f "$R" ]]; then
      if [[ -f "$L" ]]; then rc=0; same_content "$L" "$R" || rc=$?; else rc=1; fi
      (( rc == 0 || rc == 2 )) || { all_captured=0; break; }
    elif [[ -f "$L" ]]; then
      all_captured=0; break                        # Builder deleted it, LOCAL still has it
    fi
  done <<<"$dif"
  if (( all_captured )); then
    pass BUILDER_CHANGES_CAPTURED "Builder changed since last syncpoint, but LOCAL already contains every Builder-side change. Safe to import (those files are rewritten identically). Remember record-sync afterwards."
    eol_note "$dif"
    payload_report "$base"
    return 0
  fi

  TMP_KEEP="$scratch"
  echo ""
  echo "  Builder changed since the last syncpoint:"
  echo "  (D = only in BASE, A = only in BUILDER, M = differs, E = line endings only)"
  indent <<<"$dif"
  eol_note "$dif"
  local s; stored_stamp; s=$SS
  if [[ -n "$s" ]]; then
    echo ""
    echo "  Pages touched in the Builder since $s (page  name  by  when):"
    pages_changed_since "$s" || true
  fi
  echo ""
  echo "  Builder export kept at: $scratch"
  echo "  Resolution per file (see SKILL.md):"
  echo "   - Changed only in the Builder: copy it from the export into $SRC_REL/, commit as 'capture Builder changes'."
  echo "   - Changed on both sides: git show $REF:$ALIAS/<file> > /tmp/base && git merge-file <local-file> /tmp/base <export-file>"
  echo "   Then re-run check-import (it PASSes once LOCAL contains every Builder change); validate; check-import again right before the import; import; record-sync."
  fail CONFLICT BUILDER_DIVERGED "importing now would overwrite the Builder changes above."
}

cmd_check_export() {
  revoke_marker export
  echo "apex-sync-guard: check-export (app $APP_ID '$ALIAS')"
  # A missing dir has no "uncommitted changes", so git status found nothing and the
  # check PASSed, whatever directory the export was really about to write.
  require_source_dir
  # -z: names are never quoted, and a rename puts its source on the next record.
  local dirty line xy p st skip=0
  # --untracked-files=all: a user's status.showUntrackedFiles=no must not hide new work.
  dirty=$(git -C "$ROOT" status --porcelain -z --untracked-files=all --ignore-submodules=none -- "${EXPORT_SCOPE[@]}" | tr '\0' '\n')
  lines_of "$dirty"; evidence command 0 "git status --porcelain -- ${EXPORT_SCOPE[*]}" "${#LINES[@]} changed"
  if [[ -n "$dirty" ]]; then
    while IFS= read -r line; do
      if (( skip )); then skip=0; continue; fi
      xy=${line:0:2}; p=${line:3}
      printf '    %s %s\n' "$xy" "$p"
      case "$xy" in R*|C*) skip=1 ;; esac
      case "$xy" in "??"|A?|?A|C?) st=A ;; D?|?D) st=D ;; *) st=M ;; esac
      R_CHANGES+="$st"$'\t'"$p"$'\n'
    done <<<"$dirty"
    fail FAIL LOCAL_DIRTY "the APEXlang source dir has uncommitted/untracked changes — the export would clobber them. Commit or stash first, then re-run."
  fi
  have_base || note "(no syncpoint yet — record-sync after this export will create it)"
  local excl=""; (( ${#EXPORT_SCOPE[@]} > 1 )) && excl=" (other apps' dirs excluded)"
  pass LOCAL_CLEAN "working tree clean under ${SRCDIR:-the repo root}$excl. Safe to export."
}

marker_fresh() {  # $1 = import|export — written by a PASS less than TTL_SECONDS ago
  local m="$STATE_DIR/check-ok.$1" t now
  [[ -f "$m" ]] || return 1
  t=$(mtime "$m" 2>/dev/null) || return 1
  epoch_now; now=$EPOCH
  [[ "$t" =~ ^[0-9]+$ && "$now" =~ ^[0-9]+$ ]] || return 1
  (( now - t >= 0 && now - t < TTL_SECONDS ))
}

# record-sync rewrites BASE to whatever the Builder holds right now. Run after a
# real import or export that is exactly right; run after a CONFLICT it "launders"
# the Builder-only work into BASE, the next check-import PASSes, and the import
# destroys that work. So it needs one of these, in this order — the first that
# holds is recorded as the basis of the new syncpoint:
#   fresh-check           a check-import PASSed in the last TTL_SECONDS (the import
#                         it authorized is what is being recorded). An export marker
#                         does NOT count: after a skipped or failed export the
#                         Builder can hold anything.
#   builder-unchanged     the Builder still equals BASE: recording is a no-op.
#   local-equals-builder  LOCAL equals the Builder: no Builder-only work exists
#                         (this is the state right after an export).
#   forced                --force: the user's explicit decision, kept in state.json.
cmd_record_sync() {
  echo "apex-sync-guard: record-sync — exporting the Builder to snapshot its canonical state…"
  local scratch c s basis=""
  export_builder; scratch=$REMOTE_DIR
  if marker_fresh import; then
    basis=fresh-check
  elif have_base && materialize_base && tree_diff "$BASE_APP_DIR" "$scratch/$ALIAS" && blocking "$TD" && [[ -z "$BL" ]]; then
    basis=builder-unchanged
  elif [[ -d "$APP_SRC" ]] && tree_diff "$APP_SRC" "$scratch/$ALIAS" && blocking "$TD" && [[ -z "$BL" ]]; then
    basis=local-equals-builder
  elif (( OPT_FORCE )); then
    basis=forced
    echo "  WARNING: --force — recording the Builder as BASE although nothing proves it holds no"
    echo "  unsynchronized work. Any Builder-only change becomes invisible to the next check-import."
  else
    blocked NO_FRESH_CHECK "nothing proves the Builder holds no unsynchronized work: no check-import PASS in the last $((TTL_SECONDS / 60)) min, and the Builder differs from both BASE and LOCAL.
      record-sync belongs right after a successful import (check-import PASS -> import -> record-sync) or export.
      To resolve a CONFLICT, capture or merge the Builder changes and re-run check-import — never record-sync.
      Only if the user decides the current Builder IS the new truth: they run record-sync --force themselves."
  fi
  R_BASIS=$basis
  builder_stamp; s=$BS; snapshot_export "$scratch"; c=$SNAP_COMMIT; write_state "$c" "$s" "$basis"
  pass SYNCPOINT_RECORDED "syncpoint recorded for '$ALIAS'"
  note "commit:       $c"
  note "builderStamp: $s"
  note "basis:        $basis"
}

DOC_BAD=0
doc_ok()   { printf '  OK    %s\n' "$*"; }
doc_note() { printf '  --    %s\n' "$*"; }
doc_fail() { printf '  FAIL  %s\n' "$*"; DOC_BAD=$((DOC_BAD+1)); }

# One command to validate a machine before trusting the guard on it. Everything is
# probed by doing it, never by "the binary is on PATH" — that is what let a stub
# python3 and an unconvertible scratch path through in the first place.
cmd_doctor() {
  local e i have_sql=0 sid probe n
  echo "apex-sync-guard: doctor"
  doc_ok "bash ${BASH_VERSION%%(*} on ${OSTYPE:-unknown}"
  case "${OSTYPE:-}" in
    msys*|cygwin*) native_path "${TMPDIR:-/tmp}"; doc_ok "cygpath present — SQLcl will be handed e.g. $NP" ;;
    *)             doc_note "not a Windows shell — no path conversion needed" ;;
  esac
  doc_ok "$(git --version)"
  if command -v sql >/dev/null 2>&1; then have_sql=1; doc_ok "SQLcl: $(command -v sql)"
  else doc_fail "SQLcl (sql) is not on PATH — every check needs it"; fi
  doc_ok "JSON parser (probed by execution): ${JSON_TOOL[*]}"
  bytes_eq_tool
  doc_ok "byte comparator: $( [[ "$BYTES_EQ" == cmp ]] && echo "cmp" || echo "git hash-object --no-filters (cmp unavailable)" )"
  for e in "${CFG_NOTES[@]:-}"; do [[ -n "$e" ]] && doc_note "$e"; done
  if (( ${#CFG_ERRORS[@]} )); then
    for e in "${CFG_ERRORS[@]}"; do doc_fail "$e"; done
    echo ""; echo "$DOC_BAD check(s) failed — fix apex-sync.json first (setup.md §1)."
    return 1
  fi
  doc_ok "config: $CFG — ${#APPS_ALIAS[@]} app(s): ${APPS_ALIAS[*]}"
  for i in "${SEL[@]}"; do
    select_app "$i"
    echo ""
    echo "  app $APP_ID '$ALIAS' — source $SRC_REL, connection $CONN"
    source_app_id; sid=$SID
    if [[ -n "$sid" && "$sid" != "$APP_ID" ]]; then
      doc_fail "deployments/default.json says app $sid, apex-sync.json says $APP_ID"
    fi
    if [[ -d "$APP_SRC" ]]; then
      doc_ok "source dir $SRC_REL ($(list_files "$APP_SRC" | grep -c . || true) files)"
    else
      doc_fail "source dir missing: $SRC_REL"
    fi
    if [[ -w "$STATE_DIR" ]]; then doc_ok "state dir writable: $STATE_REL/apex-sync/$ALIAS"
    else doc_fail "state dir not writable: $STATE_DIR"; fi
    if (( ! have_sql )); then
      doc_note "connection '$CONN' not probed — no SQLcl"
    elif probe=$(run_sql "select 'apex-sync-doctor '||(select count(*) from apex_applications where application_id=$APP_ID) from dual;" 2>&1) \
         && grep -q apex-sync-doctor <<<"$probe"; then
      doc_ok "SQLcl connection '$CONN' answers"
      n=$(sed -n 's/.*apex-sync-doctor \([0-9]*\).*/\1/p' <<<"$probe" | head -1)
      if [[ "$n" == "0" ]]; then
        doc_fail "app $APP_ID is not visible through '$CONN' — wrong connection, wrong workspace, or wrong appId"
      else
        doc_ok "app $APP_ID visible through '$CONN'"
      fi
    else
      doc_fail "SQLcl connection '$CONN' failed: $(head -3 <<<"$probe" | tr '\n' ' ')"
    fi
    if have_base; then doc_ok "syncpoint: $(git -C "$ROOT" rev-parse --short "$REF")"
    else doc_note "no syncpoint yet — run check-import once to bootstrap (setup.md §2)"; fi
  done

  echo ""
  if (( DOC_BAD )); then echo "$DOC_BAD check(s) failed."; return 1; fi
  echo "All checks passed."
}

cmd_apps() {  # per app, tab-separated: alias, appId, source dir, connection, testUser, runtimeUrl
  local i
  for i in "${SEL[@]}"; do
    app_src "$i"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${APPS_ALIAS[$i]}" "${APPS_ID[$i]}" "$SR" \
      "${APPS_CONN[$i]}" "${APPS_USER[$i]}" "${APPS_URL[$i]}"
  done
}

cmd_status() {
  echo "apex-sync-guard: status (app $APP_ID '$ALIAS' via $CONN)"
  note "repo root:  $ROOT"
  note "source dir: $SRC_REL"
  if have_base; then
    local rec='?' basis=""
    if [[ -f "$STATE" ]] && json_get "$STATE" recordedAt; then rec=$JG; fi
    note "syncpoint:  $(git -C "$ROOT" rev-parse --short "$REF")  recorded $rec"
    if [[ -f "$STATE" ]] && json_get "$STATE" basis; then basis=$JG; fi
    if [[ "$basis" == forced ]]; then
      note "            FORCED by record-sync --force — Builder-only work at that moment was not checked"
    fi
    stored_stamp || SS=""
    note "stored builderStamp:  $SS"
  else
    note "syncpoint:  NONE — bootstrap pending (run check-import once)"
  fi
  builder_stamp; note "current builderStamp: $BS"
  local dirty; dirty=$(git -C "$ROOT" status --porcelain --untracked-files=all -- "${EXPORT_SCOPE[@]}" | wc -l | tr -d '[:space:]')
  note "LOCAL dirty files an export would overwrite: $dirty"
  for d in import export; do
    local m="$STATE_DIR/check-ok.$d"
    if [[ -f "$m" ]]; then
      local age=$(( $(date +%s) - $(mtime "$m") ))
      note "last check-$d PASS: ${age}s ago"
    fi
  done
  # What an import from here would deploy — no Builder export needed for this half.
  # (an `if`, not `have_base && …`: as the last statement of the function, a false
  #  `&&` would become status's exit code and report a bootstrap-pending repo as failed)
  if have_base; then materialize_base; payload_report "$BASE_APP_DIR"; fi
}

[[ -n "$R_OP" ]] && results_init
case "$SUB" in
  check-import) cmd_check_import ;;
  check-export) cmd_check_export ;;
  record-sync)  cmd_record_sync ;;
  status)       for _i in "${!SEL[@]}"; do (( _i )) && echo ""; select_app "${SEL[$_i]}"; cmd_status; done ;;
  doctor)       cmd_doctor ;;
  apps)         cmd_apps ;;
esac
