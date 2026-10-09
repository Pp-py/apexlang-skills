#!/usr/bin/env bash
# apex-sync-guard — Builder↔Git divergence guard for APEXlang apps.
#
# Usage (from anywhere inside the project repo):
#   apex-sync-check.sh check-import   # gate before `apex import`
#   apex-sync-check.sh check-export   # gate before `apex export`
#   apex-sync-check.sh record-sync    # after a successful import/export
#   apex-sync-check.sh status         # inspect syncpoint + both replicas
#   apex-sync-check.sh doctor         # validate this machine's wiring end to end
# Options (before or after the subcommand):
#   --task <id>  check-*/record-sync: also write the result to
#                <evidenceDir>/<id>/sync-<appAlias>-<subcommand>.json
#   --force      record-sync only: record the syncpoint although nothing proves the
#                Builder holds no unsynchronized work. The user's call, never an agent's.
#
# Exit codes: 0 PASS · 1 FAIL/CONFLICT · 2 BLOCKED (precondition missing) ·
#             3 UNKNOWN (started, outcome undeterminable — nothing authorized).
# Every gate run (check-import, check-export, record-sync) also leaves its verdict
# as JSON in .git/apex-sync/<appAlias>/last-<subcommand>.json — the sync-result
# contract, framework/schemas/sync-result.schema.json. The JSON is the verdict;
# the exit code mirrors it.
#
# Runs under bash: Linux, macOS, and Windows via Git Bash or WSL (not PowerShell/cmd).
#
# Reads apex-sync.json at the repo root. Sync state lives in
# .git/apex-sync/<appAlias>/ (machine-local, never committed) plus the
# git ref refs/apex-sync/<appAlias> holding the BASE tree.
#
# The core check is always a full `apex export` + diff against BASE:
# timestamp views (APEX_APPLICATION_PAGES / APEX_APPLICATIONS) miss some
# shared-component edits, so they are used for the who/when report only.
set -euo pipefail

TTL_SECONDS=600   # how long a check PASS authorizes; must equal TTL in apex-sync-hook.sh
FRAMEWORK_VERSION="0.6.0"   # the apexlang-skills release this script belongs to (.claude-plugin/plugin.json)

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
fail()    { local s=$1 r=$2; shift 2; classify "$s" "$r" "$*"; echo ""; echo "FAIL: $*" >&2; exit 1; }
pass()    { classify PASS "$1" "$2"; echo "PASS: $2"; }
note() { echo "  $*"; }
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }   # GNU stat / BSD (macOS) stat
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }                    # BSD date has no -Iseconds

# A path that crosses into a native Windows binary must be converted first.
# The export dir reaches SQLcl (a Java program) inside the SQL text on stdin,
# where MSYS does no argv mangling at all, so /tmp/... arrives as C:\tmp\... .
# Forward slashes (-m, not -w) so nothing has to survive backslash escaping.
native_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

# ------------------------------------------------------------ arguments
# Parsed before any setup, so a usage error never depends on SQLcl or a parser.
USAGE="usage: $(basename "$0") check-import|check-export|record-sync|status|doctor [--task <id>] [--force]"
SUB=""; OPT_FORCE=0; OPT_TASK=""
while (( $# )); do
  case "$1" in
    --force)   OPT_FORCE=1 ;;
    --task)    [[ -n "${2:-}" ]] || die "--task needs a value — $USAGE"; OPT_TASK=$2; shift ;;
    --task=*)  OPT_TASK=${1#--task=}; [[ -n "$OPT_TASK" ]] || die "--task needs a value — $USAGE" ;;
    -h|--help) echo "$USAGE"; exit 0 ;;
    -*)        die "unknown option: $1 — $USAGE" ;;
    *)         [[ -z "$SUB" ]] || die "unexpected argument: $1 — $USAGE"; SUB=$1 ;;
  esac
  shift
done
case "$SUB" in
  check-import|check-export|record-sync) R_OP=$SUB ;;
  status|doctor) ;;
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
command -v sql >/dev/null || blocked NO_SQLCL "SQLcl (sql) is required on PATH"

# The JSON parser is resolved ONCE and by EXECUTION, never by `command -v`:
# on Windows the Microsoft Store `python3` stub satisfies `command -v` and then
# exits without running anything, which surfaced as a cryptic exit deep in a run.
resolve_json_tool() {
  local c cand=()
  if command -v jq >/dev/null 2>&1 && printf '{}' | jq -e . >/dev/null 2>&1; then
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

# Every JSON read is stripped of carriage returns: native tooling on Windows writes
# CRLF, and a trailing \r survives command substitution. Windows then hides the
# damage for filesystem paths — the OS trims trailing whitespace — while the plain
# string comparison in ignored() kept failing, so a repo-only ignorePaths entry was
# reported as a Builder-side deletion and every LOCAL comparison FAILed.
strip_cr() { tr -d '\r'; }

json_get() {  # $1 = json file ('-' = stdin), $2 = dotted key path
  if [[ "${JSON_TOOL[0]}" == "jq" ]]; then
    jq -r ".$2 // empty" "$1" | strip_cr
  else
    "${JSON_TOOL[@]}" -c '
import json, sys
src = sys.stdin if sys.argv[1] == "-" else open(sys.argv[1])
data = json.load(src)
for k in sys.argv[2].split("."):
    data = data.get(k) if isinstance(data, dict) else None
    if data is None: break
print("" if data is None else data)' "$1" "$2" | strip_cr
  fi
}

# One reading of apex-sync.json, identical under jq and python: every node becomes
# "path<TAB>type<TAB>value" ($.appId, $.ignorePaths.0, …). All semantics — types,
# defaults, validation — then live once, here in bash. Reading keys one at a time
# with each parser had let them disagree: python iterated a string-valued
# ignorePaths character by character, so nearly every file was excluded from the
# comparison and the check PASSed without comparing anything.
json_flatten() {  # $1 = json file; non-zero exit if it is not valid JSON
  if [[ "${JSON_TOOL[0]}" == "jq" ]]; then
    jq -r 'def row($p; $v): [ (["$"] + ($p | map(tostring)) | join(".")), ($v | type),
             ($v | if type == "string" then . elif type == "array" or type == "object" then (length | tostring)
                   elif type == "null" then "" else tostring end) ] | @tsv;
           row([]; .), (paths as $p | row($p; getpath($p)))' "$1" | strip_cr
  else
    "${JSON_TOOL[@]}" -c '
import json, sys
def esc(s): return s.replace("\\", "\\\\").replace("\t", "\\t").replace("\n", "\\n").replace("\r", "\\r")
def kind(v):
    if v is None: return "null"
    if isinstance(v, bool): return "boolean"
    if isinstance(v, (int, float)): return "number"
    if isinstance(v, str): return "string"
    return "array" if isinstance(v, list) else "object"
out = []
def walk(path, v):
    k = kind(v)
    val = esc(v) if k == "string" else ("true" if v else "false") if k == "boolean" else "" if k == "null" \
        else str(len(v)) if k in ("array", "object") else json.dumps(v)
    out.append(esc(".".join(["$"] + [str(p) for p in path])) + "\t" + k + "\t" + val)
    for key, sub in (v.items() if k == "object" else enumerate(v) if k == "array" else []):
        walk(path + [key], sub)
walk([], json.load(open(sys.argv[1], encoding="utf-8")))
sys.stdout.buffer.write(("\n".join(out) + "\n").encode("utf-8"))' "$1" | strip_cr
  fi
}

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || blocked NO_GIT "not inside a git repository"
CFG="$ROOT/apex-sync.json"
[[ -f "$CFG" ]] || blocked NO_CONFIG "apex-sync.json not found at repo root ($ROOT) — see setup.md"

# ------------------------------------------------------------- config
# The rules every key must satisfy. The same alias and connection-name patterns
# appear in apex-sync-hook.sh, apex-sentinel's pw.sh and framework/schemas —
# a contract test asserts they stay identical.
RE_APP_ID='^[1-9][0-9]{0,9}$'
RE_APP_ALIAS='^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$'
RE_CONNECTION='^[^/@[:space:]\"'"'"']{1,128}$'   # a saved-connection NAME: never user/password@host

CFG_FLAT=""
CFG_ERRORS=()   # every problem found, reported together
CFG_NOTES=()    # unknown top-level keys: tolerated, listed by doctor
APPS_ID=(); APPS_ALIAS=(); APPS_DIR=(); APPS_CONN=(); APPS_IGNORE=()   # APPS_IGNORE[i]: newline-separated
EVIDENCE_DIR=".apex-evidence"

cfg_type()  { awk -F'\t' -v p="$1" '$1 == p { print $2; exit }' <<<"$CFG_FLAT"; }
cfg_value() { awk -F'\t' -v p="$1" '$1 == p { print $3; exit }' <<<"$CFG_FLAT"; }
cfg_err()   { CFG_ERRORS+=("$*"); }

rel_path_ok() {  # relative, forward slashes, no '..' segment, no drive letter
  local p=$1
  [[ -n "$p" && "$p" != /* && "$p" != *\\* && "$p" != *:* && "/$p/" != */../* ]]
}

# A string setting of the app at JSON path $1: its own value, else the top-level
# default. Prints the value; a wrong type is an error, absence prints nothing.
cfg_string() {  # $1 = app path, $2 = key, $3 = label for messages
  local p t
  for p in "$1.$2" "\$.$2"; do
    t=$(cfg_type "$p")
    [[ -z "$t" ]] && continue
    if [[ "$t" == string ]]; then cfg_value "$p"; else cfg_err "$3: $2 must be a string"; fi
    return 0
  done
}

cfg_app() {  # $1 = JSON path of the app object; appends one app or records errors
  local at=$1 label="apex-sync.json" t id alias dir conn ign="" i n v
  [[ "$at" == "\$" ]] || label="apex-sync.json ${at#\$.}"
  t=$(cfg_type "$at.appId"); id=$(cfg_value "$at.appId")
  case "$t" in
    number|string) [[ "$id" =~ $RE_APP_ID ]] || cfg_err "$label: appId must be a positive integer (got '$id')" ;;
    "")            cfg_err "$label: appId is missing" ;;
    *)             cfg_err "$label: appId must be a positive integer" ;;
  esac
  t=$(cfg_type "$at.appAlias"); alias=$(cfg_value "$at.appAlias")
  if [[ -z "$t" ]]; then cfg_err "$label: appAlias is missing"
  elif [[ "$t" != string || ! "$alias" =~ $RE_APP_ALIAS ]]; then
    cfg_err "$label: appAlias must match $RE_APP_ALIAS (letters, digits, '_' and '-'; it names a git ref and a directory)"
  fi
  dir=$(cfg_string "$at" apexlangDir "$label")
  if [[ -z "$dir" ]]; then cfg_err "$label: apexlangDir is missing"
  elif ! rel_path_ok "$dir"; then cfg_err "$label: apexlangDir must be a relative path with forward slashes and no '..' (got '$dir')"; fi
  conn=$(cfg_string "$at" sqlclConnection "$label")
  if [[ -z "$conn" ]]; then cfg_err "$label: sqlclConnection is missing"
  elif [[ ! "$conn" =~ $RE_CONNECTION ]]; then
    cfg_err "$label: sqlclConnection must be a saved connection NAME (sql -name <name>), never a connect string — no '/', '@', quotes or spaces"
  fi
  # ignorePaths: the app's own list replaces the top-level one (no merging).
  local ip="$at.ignorePaths"
  [[ -n "$(cfg_type "$ip")" ]] || ip="\$.ignorePaths"
  t=$(cfg_type "$ip")
  if [[ -n "$t" && "$t" != array ]]; then
    cfg_err "$label: ignorePaths must be an array of paths, e.g. [\"apex-exports/\"] (got a $t)"
  elif [[ "$t" == array ]]; then
    n=$(cfg_value "$ip")
    for (( i = 0; i < n; i++ )); do
      v=$(cfg_value "$ip.$i")
      if [[ "$(cfg_type "$ip.$i")" != string ]] || ! rel_path_ok "$v"; then
        cfg_err "$label: ignorePaths[$i] must be a relative path with forward slashes and no '..'"
      else
        ign+="$v"$'\n'
      fi
    done
  fi
  v=$(cfg_string "$at" runtimeUrl "$label")
  [[ "$v" != *session=* ]] || cfg_err "$label: runtimeUrl must not carry a session token (session=…): the file is committed"
  cfg_string "$at" testUser "$label" >/dev/null
  APPS_ID+=("$id"); APPS_ALIAS+=("$alias"); APPS_DIR+=("$dir"); APPS_CONN+=("$conn"); APPS_IGNORE+=("$ign")
}

cfg_load() {
  local k
  CFG_FLAT=$(json_flatten "$CFG") || { cfg_err "apex-sync.json is not valid JSON"; return 0; }
  [[ "$(cfg_type '$')" == object ]] || { cfg_err "apex-sync.json must hold a JSON object"; return 0; }
  if [[ -n "$(cfg_type '$.apps')" ]]; then
    cfg_err "apex-sync.json: \"apps\" (several apps per repo) is not supported by this version of apex-sync-guard"
    return 0
  fi
  cfg_app '$'
  if [[ -n "$(cfg_type '$.evidenceDir')" ]]; then
    EVIDENCE_DIR=$(cfg_string '$' evidenceDir "apex-sync.json")
    rel_path_ok "$EVIDENCE_DIR" || cfg_err "apex-sync.json: evidenceDir must be a relative path with forward slashes and no '..'"
  fi
  while IFS= read -r k; do
    case "$k" in
      appId|appAlias|apexlangDir|sqlclConnection|ignorePaths|testUser|runtimeUrl|evidenceDir|apps) ;;
      *) CFG_NOTES+=("unknown key '$k' ignored (typo?)") ;;
    esac
  done < <(awk -F'\t' '$1 ~ /^\$\.[^.]+$/ { sub(/^\$\./, "", $1); print $1 }' <<<"$CFG_FLAT")
}
cfg_load
if (( ${#CFG_ERRORS[@]} )) && [[ "$SUB" != doctor ]]; then
  blocked CONFIG_INVALID "apex-sync.json is invalid — nothing was checked:$(printf '\n      - %s' "${CFG_ERRORS[@]}")"
fi

APP_ID=""; ALIAS=""; SRCDIR=""; CONN=""; IGNORE_PATHS=()
select_app() {  # $1 = index into the APPS_* arrays; sets the per-app globals
  local p
  APP_ID=${APPS_ID[$1]}; ALIAS=${APPS_ALIAS[$1]}; SRCDIR=${APPS_DIR[$1]}; CONN=${APPS_CONN[$1]}
  # Paths (relative to the app dir) that exist only on one side by design,
  # e.g. repo-only artifacts like "apex-exports/". Excluded from comparisons.
  # (while-read, not mapfile: macOS ships bash 3.2)
  IGNORE_PATHS=()
  while IFS= read -r p; do [[ -n "$p" ]] && IGNORE_PATHS+=("$p"); done <<<"${APPS_IGNORE[$1]}"
  APP_SRC="$ROOT/$SRCDIR/$ALIAS"
  STATE_DIR="$ROOT/.git/apex-sync/$ALIAS"
  STATE="$STATE_DIR/state.json"
  REF="refs/apex-sync/$ALIAS"
  mkdir -p "$STATE_DIR"
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
(( ${#CFG_ERRORS[@]} )) || select_app 0

TMP_KEEP=""                       # scratch dirs preserved on FAIL for resolution
TMPS=()
RESULT_FILES=()                   # where this run's sync-result goes (results_init)

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
  for t in "${TMPS[@]:-}"; do [[ -n "$t" && "$t" != "$TMP_KEEP" ]] && rm -rf "$t"; done
  exit "$rc"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# A check always starts by withdrawing its own authorization: a FAIL, a BLOCKED or
# a crash must never leave an earlier PASS's marker fresh for the hook to trust.
revoke_marker() { rm -f "$STATE_DIR/check-ok.$1"; }

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
  n=$(tr -d '[:space:]' <<<"$n")
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
builder_stamp() {
  local s
  s=$(run_sql "select to_char(greatest(
             nvl((select max(last_updated_on) from apex_application_pages where application_id=$APP_ID), date '1900-01-01'),
             nvl((select last_updated_on from apex_applications where application_id=$APP_ID), date '1900-01-01')
           ),'YYYY-MM-DD\"T\"HH24:MI:SS') from dual;" | tr -d '[:space:]')
  [[ "$s" == 1900-01-01* ]] && s="unavailable"
  echo "$s"
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
  native=$(native_path "$scratch")
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
  (( rc == 0 )) || unknown EXPORT_FAILED "the Builder export failed (SQLcl exited non-zero) — check the connection with: $(basename "$0") doctor"
  out=$(tr -d '\r' <<<"$out")
  R_SQLCL_VERSION=$(sed -n 's/.*(SQLcl) version: .* build: *\([0-9][0-9.]*[0-9]\).*/\1/p' <<<"$out" | head -1)
  R_APEX_VERSION=$(sed -n 's/^[[:space:]]*apex-sync-apex-version \([0-9][0-9.]*[0-9]\).*/\1/p' <<<"$out" | head -1)
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
  tmpidx=$(mktemp -u "${TMPDIR:-/tmp}/apex-sync-idx-XXXXXX"); TMPS+=("$tmpidx")
  # Every step is checked, and the ref is read back: "recorded" must mean the ref
  # really points at the new commit (commit-tree fails without a git identity).
  if ! { GIT_INDEX_FILE=$tmpidx git "${GIT_HERMETIC[@]}" --git-dir="$ROOT/.git" --work-tree="$1" add -f -A -- . 2>/dev/null \
         && tree=$(GIT_INDEX_FILE=$tmpidx git --git-dir="$ROOT/.git" write-tree) \
         && commit=$(git -C "$ROOT" commit-tree "$tree" -m "apex-sync syncpoint $ALIAS $(now_iso)") \
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
if cmp -s /dev/null /dev/null 2>/dev/null; then BYTES_EQ="cmp"; else BYTES_EQ="git-hash"; fi

bytes_equal() {
  if [[ "$BYTES_EQ" == cmp ]]; then cmp -s "$1" "$2"
  else [[ "$(git hash-object --no-filters -- "$1")" == "$(git hash-object --no-filters -- "$2")" ]]; fi
}

eol_equal() {  # equal once every CR is dropped
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

tree_diff() {  # $1=dirA $2=dirB → "<status>\t<app-relative path>", ignorePaths filtered
  local f rc                # D = only in A, A = only in B, M = differs, E = EOL only
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    ignored "$f" && continue
    if   [[ ! -e "$2/$f" ]]; then printf 'D\t%s\n' "$f"
    elif [[ ! -e "$1/$f" ]]; then printf 'A\t%s\n' "$f"
    else
      rc=0; same_content "$1/$f" "$2/$f" || rc=$?
      case $rc in 0) ;; 2) printf 'E\t%s\n' "$f" ;; *) printf 'M\t%s\n' "$f" ;; esac
    fi
  done < <( { list_files "$1"; list_files "$2"; } | LC_ALL=C sort -u )
}

# A line-ending-only difference cannot carry a Builder-side change, and blocking
# on it would deadlock: every re-export reintroduces it. So E is reported, never gated.
blocking() { grep -v $'^E\t' <<<"${1:-}" || true; }

indent() { local l; while IFS= read -r l; do printf '    %s\n' "$l"; done; }

eol_note() {  # $1 = tree_diff output
  grep -q $'^E\t' <<<"${1:-}" || return 0
  echo "  Note: the files marked E differ only in line endings — not a Builder change, so they do not gate."
  echo "        To silence them, add to this repo's .gitattributes:  *.apx text eol=lf"
}

# The guard's other direction. check-import answers "does the Builder hold work an
# import would destroy?" — it says nothing about what the import DEPLOYS. Since
# `apex import` replaces the whole app, a silent PASS can push a backlog that
# accumulated over days, changing behaviour nobody was expecting to change today.
# Reported, never gating: every legitimate import has a payload.
payload_report() {  # $1 = materialized BASE app dir
  local dif n recorded commits
  dif=$(tree_diff "$1" "$APP_SRC")
  dif=$(blocking "$dif")
  n=$(grep -c . <<<"$dif" || true)
  R_PAYLOAD=$(repo_rel <<<"$dif"); R_PAYLOAD_SET=1
  echo ""
  if (( n == 0 )); then
    note "Nothing to deploy: LOCAL matches the syncpoint (if you expected changes, they were not generated/saved)."
    return 0
  fi
  recorded=""; [[ -f "$STATE" ]] && recorded=$(json_get "$STATE" recordedAt)
  local head=""; [[ -f "$STATE" ]] && head=$(json_get "$STATE" headCommit)
  # Count from the recorded revision, not from a timestamp: --since has one-second
  # granularity, so a commit made in the same second as the syncpoint was counted
  # or not depending on how fast the machine ran. Falls back to --since for state
  # files written before headCommit existed.
  # wc, not `grep -c`: grep exits 1 on a zero count, so `| grep -c . || echo "?"`
  # printed BOTH the count and the fallback, splitting the line in two.
  if [[ -n "$head" ]] && git -C "$ROOT" rev-parse -q --verify "$head^{commit}" >/dev/null 2>&1; then
    commits=$(git -C "$ROOT" log --oneline "$head..HEAD" -- "$SRCDIR" | wc -l | tr -d '[:space:]')
  elif [[ -n "$recorded" ]]; then
    commits=$(git -C "$ROOT" log --oneline --since="$recorded" -- "$SRCDIR" | wc -l | tr -d '[:space:]')
  else
    commits="?"
  fi
  R_PAYLOAD_COMMITS=$commits
  note "This import DEPLOYS the accumulated LOCAL backlog — \`apex import\` replaces the WHOLE app:"
  note "(A = new in LOCAL, M = differs, D = removed from LOCAL)"
  indent <<<"$dif"
  note "$n file(s), $commits commit(s) touching $SRCDIR since the syncpoint${recorded:+ ($recorded)}"
  note "(may include formatting-only entries: LOCAL is hand-edited, BASE is the exporter's canonical form)"
}

write_marker() {  # $1 = import|export
  printf '{"check":"%s","at":"%s"}\n' "$1" "$(now_iso)" > "$STATE_DIR/check-ok.$1"
  # Printed on purpose: the hook resolves the repo from the tool payload's cwd
  # and this script from its own, so a check run inside a command that `cd`s
  # elsewhere leaves the marker where the hook will not look. Showing both
  # halves of that path turns a silent mismatch into a one-line comparison.
  note "marker: $STATE_DIR/check-ok.$1"
}

stored_stamp() { if [[ -f "$STATE" ]]; then json_get "$STATE" builderStamp; fi; }

write_state() {  # $1 = syncpoint commit, $2 = builder stamp, $3 = basis (record-sync) or bootstrap
  # headCommit pins the payload's commit count to a revision instead of a clock:
  # `git log --since=<recordedAt>` has one-second granularity, so a commit made in
  # the same second as the syncpoint was counted or not depending on timing.
  local head; head=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo "")
  printf '{"appId":%s,"appAlias":"%s","sqlclConnection":"%s","syncpoint":"%s","builderStamp":"%s","recordedAt":"%s","headCommit":"%s","basis":"%s"}\n' \
    "$APP_ID" "$ALIAS" "$CONN" "$1" "$2" "$(now_iso)" "$head" "${3:-bootstrap}" > "$STATE"
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

repo_rel() {  # tree_diff lines (app-relative) → the same lines, repo-relative
  local st f
  while IFS=$'\t' read -r st f; do [[ -n "$f" ]] && printf '%s\t%s/%s/%s\n' "$st" "$SRCDIR" "$ALIAS" "$f"; done
  return 0
}

# Sets J to $1 as a JSON string literal — a global, not $(...): it runs once per
# changed file, and a fork per file is slow under Git Bash. The repo root and
# $HOME are redacted: a result is evidence that may be shared, a home path names
# the user. Control characters other than \n \r \t become \u00XX.
jstr() {
  local s=$1 out="" c i LC_ALL=C
  [[ -n "${ROOT:-}" ]] && s=${s//"$ROOT"/<repo>}
  [[ -n "${HOME:-}" && "$HOME" != / ]] && s=${s//"$HOME/"/\~/}
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
jstr_or_null() { if [[ -n "$1" ]]; then jstr "$1"; else J=null; fi; }

json_changes() {  # $1 = "<status><TAB><path>" lines → a JSON array
  local st f out="" sep=""
  while IFS=$'\t' read -r st f; do
    [[ -z "$f" ]] && continue
    jstr "$f"; out+="$sep{\"status\": \"$st\", \"path\": $J}"; sep=", "
  done <<<"$1"
  printf '[%s]' "$out"
}

json_evidence() {
  local kind rc text res out="" sep="" key rkey
  while IFS=$US read -r kind rc text res; do
    [[ -z "$kind" ]] && continue
    case "$kind" in sql) key="statement"; rkey="result" ;; *) key="command"; rkey="output" ;; esac
    jstr "$text"; out+="$sep{\"kind\": \"$kind\", \"$key\": $J, \"exitCode\": $rc"
    if [[ -n "$res" ]]; then jstr "$res"; out+=", \"$rkey\": $J"; fi
    out+="}"; sep=", "
  done <<<"$R_EVIDENCE"
  printf '[%s]' "$out"
}

iso_in() {  # $1 = seconds from now → UTC ISO-8601 (GNU date, else BSD date)
  local e=$(( $(date +%s) + $1 ))
  date -u -d "@$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$e" +%Y-%m-%dT%H:%M:%SZ
}

result_json() {  # prints the sync-result for the current R_* state; never fails
  local d head dirty=false spc mmd="" tgt dir written=false exp=null rec=false pc=null
  head=$(git -C "$ROOT" rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null) || head=""
  [[ -z "$(git -C "$ROOT" status --porcelain 2>/dev/null | head -1)" ]] || dirty=true
  spc=$(git -C "$ROOT" rev-parse -q --verify "$REF^{commit}" 2>/dev/null) || spc=""
  if [[ -f "$APP_SRC/.apex/apexlang.json" ]]; then     # what Oracle's skills route on
    mmd=$(json_get "$APP_SRC/.apex/apexlang.json" mmdVersion 2>/dev/null) || mmd=""
    [[ "$mmd" =~ ^[0-9]+(\.[0-9]+)*(\+[0-9A-Za-z.-]+)?$ ]] || mmd=""
  fi
  d=$'{\n  "kind": "sync-result",\n  "schemaVersion": 1,\n'
  d+="  \"operation\": \"$R_OP\","$'\n'"  \"status\": \"$R_STATUS\","$'\n'
  jstr "$R_MESSAGE"; d+="  \"reasons\": [{\"code\": \"$R_REASON\", \"message\": $J}],"$'\n'
  jstr "$ALIAS"; d+="  \"app\": {\"appId\": $APP_ID, \"appAlias\": $J"
  [[ -n "$mmd" ]] && { jstr "$mmd"; d+=", \"mmdVersion\": $J"; }
  d+=$'},\n  "context": {\n'
  jstr_or_null "$OPT_TASK"; d+="    \"task\": $J,"$'\n'
  jstr_or_null "$head"; d+="    \"repo\": {\"commit\": $J, \"dirty\": $dirty},"$'\n'
  d+="    \"frameworkVersion\": \"$FRAMEWORK_VERSION\","$'\n'
  d+="    \"timestamp\": \"$(now_iso)\","$'\n'
  d+=$'    "producer": {"skill": "apex-sync-guard", "method": "tool"},\n'
  jstr "$CONN"; tgt="\"connectionName\": $J"
  [[ -n "$R_SQLCL_VERSION" ]] && tgt+=", \"sqlclVersion\": \"$R_SQLCL_VERSION\""
  [[ -n "$R_APEX_VERSION" ]] && tgt+=", \"apexVersion\": \"$R_APEX_VERSION\""
  d+="    \"target\": {$tgt}"$'\n  },\n'
  if [[ "$R_OP" == check-* ]]; then
    dir=${R_OP#check-}
    [[ "$R_STATUS" == PASS ]] && { written=true; exp="\"$(iso_in "$TTL_SECONDS")\""; }
    d+="  \"marker\": {\"written\": $written, \"path\": \".git/apex-sync/$ALIAS/check-ok.$dir\", \"ttlSeconds\": $TTL_SECONDS, \"expiresAt\": $exp},"$'\n'
  fi
  (( R_RECORDED )) && rec=true
  jstr_or_null "$spc"; d+="  \"syncpoint\": {\"ref\": \"$REF\", \"commit\": $J, \"recorded\": $rec},"$'\n'
  d+="  \"changes\": $(json_changes "$R_CHANGES"),"$'\n'
  if [[ "$R_OP" == check-import ]] && (( R_PAYLOAD_SET )); then
    [[ "$R_PAYLOAD_COMMITS" =~ ^[0-9]+$ ]] && pc=$R_PAYLOAD_COMMITS
    d+="  \"payload\": {\"changes\": $(json_changes "$R_PAYLOAD"), \"commits\": $pc},"$'\n'
  fi
  [[ "$R_OP" == record-sync && -n "$R_BASIS" ]] && d+="  \"basis\": \"$R_BASIS\","$'\n'
  d+="  \"evidence\": $(json_evidence)"$'\n}'
  printf '%s\n' "$d"
}

write_results() {  # the current verdict → every result file, each replaced atomically
  local doc f
  doc=$(result_json)
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
    if [[ ! -d "$ev" ]]; then
      if ! { mkdir -p "$ev" && printf '*\n' > "$ev/.gitignore"; }; then
        blocked STATE_UNWRITABLE "cannot create the evidence dir $EVIDENCE_DIR"
      fi
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
source_app_id() {  # prints app.id from deployments/default.json, if the file states one
  local dj="$APP_SRC/deployments/default.json"
  [[ -f "$dj" ]] || return 0
  json_get "$dj" app.id 2>/dev/null || true
}

require_source_dir() {
  [[ -d "$APP_SRC" ]] || blocked SOURCE_DIR_MISSING "the source dir $SRCDIR/$ALIAS does not exist — check apexlangDir/appAlias in apex-sync.json (a first export needs: mkdir -p $SRCDIR/$ALIAS)"
}

cmd_check_import() {
  revoke_marker import
  echo "apex-sync-guard: check-import (app $APP_ID '$ALIAS' via $CONN)"
  require_source_dir
  local sid; sid=$(source_app_id)
  if [[ -n "$sid" && "$sid" != "$APP_ID" ]]; then
    blocked APP_ID_MISMATCH "$SRCDIR/$ALIAS/deployments/default.json says app $sid, apex-sync.json says $APP_ID — an import would target app $sid while this check compares app $APP_ID. Fix whichever is wrong."
  fi

  local app_rc=0; remote_app_exists || app_rc=$?
  if (( app_rc == 1 )); then
    # "Not visible" is only a first publication when there was never a sync. With a
    # syncpoint on record the same answer means the connection, the workspace or the
    # appId is wrong — or the app was deleted — and taking the shortcut would let an
    # import land on whatever app the source really names, unchecked.
    if have_base; then
      local was="" via=""; [[ -f "$STATE" ]] && was=$(json_get "$STATE" sqlclConnection || true)
      [[ -n "$was" ]] && via=", recorded via '$was'"
      blocked SYNCPOINT_WITHOUT_APP "app $APP_ID is not visible through '$CONN', but '$ALIAS' has a syncpoint ($(git -C "$ROOT" rev-parse --short "$REF")$via).
      Wrong saved connection, wrong workspace or wrong appId — or the app was deleted. Check with: $(basename "$0") doctor
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
    local boot; boot=$(tree_diff "$APP_SRC" "$scratch/$ALIAS")
    R_CHANGES=$(repo_rel <<<"$boot")
    if [[ -z "$(blocking "$boot")" ]]; then
      local c s; s=$(builder_stamp); snapshot_export "$scratch"; c=$SNAP_COMMIT; write_state "$c" "$s"
      pass BOOTSTRAP_IN_SYNC "replicas already agree — first syncpoint recorded ($c). Safe to import."
      eol_note "$boot"
      return 0
    fi
    TMP_KEEP="$scratch"
    echo "  (D = only in LOCAL, A = only in BUILDER, M = differs, E = line endings only)"
    indent <<<"$boot"
    eol_note "$boot"
    fail CONFLICT BOOTSTRAP_DIVERGED "bootstrap: BUILDER ≠ LOCAL and there is no BASE to arbitrate. Reconcile once by hand (Builder export kept at $scratch), commit, then record-sync. See setup.md §2."
  fi

  materialize_base; local base=$BASE_APP_DIR dif; dif=$(tree_diff "$base" "$scratch/$ALIAS")
  R_CHANGES=$(repo_rel <<<"$dif")
  if [[ -z "$(blocking "$dif")" ]]; then
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
  local s; s=$(stored_stamp)
  if [[ -n "$s" ]]; then
    echo ""
    echo "  Pages touched in the Builder since $s (page  name  by  when):"
    pages_changed_since "$s" || true
  fi
  echo ""
  echo "  Builder export kept at: $scratch"
  echo "  Resolution per file (see SKILL.md):"
  echo "   - Changed only in the Builder: copy it from the export into $SRCDIR/$ALIAS/, commit as 'capture Builder changes'."
  echo "   - Changed on both sides: git show $REF:$ALIAS/<file> > /tmp/base && git merge-file <local-file> /tmp/base <export-file>"
  echo "   Then re-run check-import (PASSes once LOCAL contains every Builder change), apex validate, import, record-sync."
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
  dirty=$(git -C "$ROOT" status --porcelain -z -- "$SRCDIR" | tr '\0' '\n')
  evidence command 0 "git status --porcelain -- $SRCDIR" "$(grep -c . <<<"$dirty" || true) changed"
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
  pass LOCAL_CLEAN "working tree clean under $SRCDIR. Safe to export."
}

marker_fresh() {  # $1 = import|export — written by a PASS less than TTL_SECONDS ago
  local m="$STATE_DIR/check-ok.$1" t now
  [[ -f "$m" ]] || return 1
  t=$(mtime "$m" 2>/dev/null) || return 1
  now=$(date +%s)
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
  elif have_base && materialize_base && [[ -z "$(blocking "$(tree_diff "$BASE_APP_DIR" "$scratch/$ALIAS")")" ]]; then
    basis=builder-unchanged
  elif [[ -d "$APP_SRC" && -z "$(blocking "$(tree_diff "$APP_SRC" "$scratch/$ALIAS")")" ]]; then
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
  s=$(builder_stamp); snapshot_export "$scratch"; c=$SNAP_COMMIT; write_state "$c" "$s" "$basis"
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
  local which=""; [[ -n "$ALIAS" ]] && which=" (app $APP_ID '$ALIAS')"
  echo "apex-sync-guard: doctor$which"
  doc_ok "bash ${BASH_VERSION%%(*} on ${OSTYPE:-unknown}"
  case "${OSTYPE:-}" in
    msys*|cygwin*) doc_ok "cygpath present — SQLcl will be handed e.g. $(native_path "${TMPDIR:-/tmp}")" ;;
    *)             doc_note "not a Windows shell — no path conversion needed" ;;
  esac
  doc_ok "$(git --version)"
  doc_ok "SQLcl: $(command -v sql)"
  doc_ok "JSON parser (probed by execution): ${JSON_TOOL[*]}"
  doc_ok "byte comparator: $( [[ "$BYTES_EQ" == cmp ]] && echo "cmp" || echo "git hash-object --no-filters (cmp unavailable)" )"
  local e
  for e in "${CFG_NOTES[@]:-}"; do [[ -n "$e" ]] && doc_note "$e"; done
  if (( ${#CFG_ERRORS[@]} )); then
    for e in "${CFG_ERRORS[@]}"; do doc_fail "$e"; done
    echo ""; echo "$DOC_BAD check(s) failed — fix apex-sync.json first (setup.md §1)."
    return 1
  fi
  doc_ok "config: $CFG → dir $SRCDIR, connection $CONN"
  local sid; sid=$(source_app_id)
  if [[ -n "$sid" && "$sid" != "$APP_ID" ]]; then
    doc_fail "deployments/default.json says app $sid, apex-sync.json says $APP_ID"
  fi
  if [[ -d "$APP_SRC" ]]; then
    doc_ok "source dir $SRCDIR/$ALIAS ($(list_files "$APP_SRC" | grep -c . || true) files)"
  else
    doc_fail "source dir missing: $APP_SRC"
  fi
  if [[ -w "$STATE_DIR" ]]; then doc_ok "state dir writable: .git/apex-sync/$ALIAS"
  else doc_fail "state dir not writable: $STATE_DIR"; fi

  local probe n
  if probe=$(run_sql "select 'apex-sync-doctor '||(select count(*) from apex_applications where application_id=$APP_ID) from dual;" 2>&1) \
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

  echo ""
  if (( DOC_BAD )); then echo "$DOC_BAD check(s) failed."; return 1; fi
  echo "All checks passed."
}

cmd_status() {
  echo "apex-sync-guard: status (app $APP_ID '$ALIAS' via $CONN)"
  note "repo root:  $ROOT"
  note "source dir: $SRCDIR/$ALIAS"
  if have_base; then
    note "syncpoint:  $(git -C "$ROOT" rev-parse --short "$REF")  recorded $( [[ -f "$STATE" ]] && json_get "$STATE" recordedAt || echo '?')"
    if [[ -f "$STATE" && "$(json_get "$STATE" basis || true)" == forced ]]; then
      note "            FORCED by record-sync --force — Builder-only work at that moment was not checked"
    fi
    note "stored builderStamp:  $(stored_stamp)"
  else
    note "syncpoint:  NONE — bootstrap pending (run check-import once)"
  fi
  note "current builderStamp: $(builder_stamp)"
  local dirty; dirty=$(git -C "$ROOT" status --porcelain -- "$SRCDIR" | wc -l)
  note "LOCAL dirty files under source dir: $dirty"
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
  status)       cmd_status ;;
  doctor)       cmd_doctor ;;
esac
