#!/usr/bin/env bash
# apex-sync-guard — Builder↔Git divergence guard for APEXlang apps.
#
# Usage (from anywhere inside the project repo):
#   apex-sync-check.sh check-import   # gate before `apex import`
#   apex-sync-check.sh check-export   # gate before `apex export`
#   apex-sync-check.sh record-sync    # after a successful import/export
#   apex-sync-check.sh status         # inspect syncpoint + both replicas
#
# Reads apex-sync.json at the repo root. Sync state lives in
# .git/apex-sync/<appAlias>/ (machine-local, never committed) plus the
# git ref refs/apex-sync/<appAlias> holding the BASE tree.
#
# The core check is always a full `apex export` + diff against BASE:
# timestamp views (APEX_APPLICATION_PAGES / APEX_APPLICATIONS) miss some
# shared-component edits, so they are used for the who/when report only.
set -euo pipefail

die()  { echo "apex-sync-guard: ERROR: $*" >&2; exit 2; }
fail() { echo ""; echo "FAIL: $*" >&2; exit 1; }
note() { echo "  $*"; }
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }   # GNU stat / BSD (macOS) stat
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }                    # BSD date has no -Iseconds

# ---------------------------------------------------------------- setup
command -v sql >/dev/null || die "SQLcl (sql) is required on PATH"
command -v jq >/dev/null || command -v python3 >/dev/null || die "jq or python3 required"

json_get() {  # $1 = json file ('-' = stdin), $2 = dotted key path
  if command -v jq >/dev/null; then
    jq -r ".$2 // empty" "$1"
  else
    python3 -c '
import json, sys
src = sys.stdin if sys.argv[1] == "-" else open(sys.argv[1])
data = json.load(src)
for k in sys.argv[2].split("."):
    data = data.get(k) if isinstance(data, dict) else None
    if data is None: break
print("" if data is None else data)' "$1" "$2"
  fi
}

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repository"
CFG="$ROOT/apex-sync.json"
[[ -f "$CFG" ]] || die "apex-sync.json not found at repo root ($ROOT) — see setup.md"

json_array() {  # $1 = json file, $2 = key of a string array → one element per line
  if command -v jq >/dev/null; then
    jq -r ".$2[]?" "$1"
  else
    python3 -c '
import json, sys
for x in json.load(open(sys.argv[1])).get(sys.argv[2], []) or []:
    print(x)' "$1" "$2"
  fi
}

APP_ID=$(json_get "$CFG" appId)
ALIAS=$(json_get  "$CFG" appAlias)
SRCDIR=$(json_get "$CFG" apexlangDir)
CONN=$(json_get   "$CFG" sqlclConnection)
for v in APP_ID ALIAS SRCDIR CONN; do
  [[ -n "${!v}" && "${!v}" != "null" ]] || die "apex-sync.json: missing field for $v"
done
# Paths (relative to the app dir) that exist only on one side by design,
# e.g. repo-only artifacts like "apex-exports/". Excluded from comparisons.
# (while-read, not mapfile: macOS ships bash 3.2)
IGNORE_PATHS=()
while IFS= read -r _p; do
  [[ -n "$_p" ]] && IGNORE_PATHS+=("$_p")
done < <(json_array "$CFG" ignorePaths)

APP_SRC="$ROOT/$SRCDIR/$ALIAS"
STATE_DIR="$ROOT/.git/apex-sync/$ALIAS"
STATE="$STATE_DIR/state.json"
REF="refs/apex-sync/$ALIAS"
mkdir -p "$STATE_DIR"

TMP_KEEP=""                       # scratch dirs preserved on FAIL for resolution
TMPS=()
trap 'for t in "${TMPS[@]:-}"; do [[ -n "$t" && "$t" != "$TMP_KEEP" ]] && rm -rf "$t"; done' EXIT

# ------------------------------------------------------------ sql layer
run_sql() {  # stdin-less silent SQLcl; $1 = statements; prints raw output
  sql -S -name "$CONN" <<EOF
set heading off feedback off pagesize 0 verify off trimspool on define off
whenever sqlerror exit 1
$1
exit
EOF
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

export_builder() {  # exports REMOTE (the Builder) to a scratch dir; prints its path
  local scratch; scratch=$(mktemp -d "${TMPDIR:-/tmp}/apex-sync-remote-XXXXXX"); TMPS+=("$scratch")
  run_sql "apex export -applicationid $APP_ID -expType APEXLANG -dir $scratch" >/dev/null
  [[ -f "$scratch/$ALIAS/application.apx" ]] || die "apex export produced no $ALIAS/application.apx in $scratch — check connection/app id"
  echo "$scratch"
}

# ------------------------------------------------------------ git layer
have_base() { git -C "$ROOT" rev-parse -q --verify "$REF" >/dev/null; }

materialize_base() {  # extracts the BASE tree to a tmpdir; prints path of the app dir
  local t; t=$(mktemp -d "${TMPDIR:-/tmp}/apex-sync-base-XXXXXX"); TMPS+=("$t")
  git -C "$ROOT" archive "$REF" | tar -x -C "$t"
  echo "$t/$ALIAS"
}

# BASE is always snapshotted from an `apex export` scratch dir, never from the
# raw working tree: hand-edited .apx differ textually (whitespace, fenced vs
# inline blocks, JSON spacing) from the exporter's canonical serialization, so
# only canonical-vs-canonical comparisons are noise-free.
snapshot_export() {  # $1 = scratch dir containing <alias>/…; commits it to $REF
  local tmpidx tree commit
  tmpidx=$(mktemp -u "${TMPDIR:-/tmp}/apex-sync-idx-XXXXXX")
  GIT_INDEX_FILE=$tmpidx git --git-dir="$ROOT/.git" --work-tree="$1" add -f -A -- . 2>/dev/null
  tree=$(GIT_INDEX_FILE=$tmpidx git --git-dir="$ROOT/.git" write-tree)
  commit=$(git -C "$ROOT" commit-tree "$tree" -m "apex-sync syncpoint $ALIAS $(now_iso)")
  git -C "$ROOT" update-ref "$REF" "$commit"
  rm -f "$tmpidx"
  echo "$commit"
}

tree_diff() {  # $1=dirA $2=dirB → name-status with app-relative paths, ignorePaths filtered
  local line rel
  { git -C "$ROOT" diff --no-index --name-status -- "$1" "$2" 2>/dev/null || true; } | \
    sed "s|$1/||g;s|$2/||g" | \
  while IFS= read -r line; do
    rel="${line#*$'\t'}"
    local skip=0 p
    for p in "${IGNORE_PATHS[@]:-}"; do
      [[ -n "$p" && "$rel" == "$p"* ]] && { skip=1; break; }
    done
    (( skip )) || printf '%s\n' "$line"
  done
}

dirs_equal() { [[ -z "$(tree_diff "$1" "$2")" ]]; }

write_marker() {  # $1 = import|export
  printf '{"check":"%s","at":"%s"}\n' "$1" "$(now_iso)" > "$STATE_DIR/check-ok.$1"
}

stored_stamp() { if [[ -f "$STATE" ]]; then json_get "$STATE" builderStamp; fi; }

write_state() {  # $1 = syncpoint commit, $2 = builder stamp
  printf '{"appId":%s,"appAlias":"%s","syncpoint":"%s","builderStamp":"%s","recordedAt":"%s"}\n' \
    "$APP_ID" "$ALIAS" "$1" "$2" "$(now_iso)" > "$STATE"
}

# ------------------------------------------------------------- commands
cmd_check_import() {
  echo "apex-sync-guard: check-import (app $APP_ID '$ALIAS' via $CONN)"
  local scratch; scratch=$(export_builder)
  echo "  Builder exported to scratch: $scratch"

  if ! have_base; then
    echo "  No syncpoint yet — bootstrap mode: comparing BUILDER vs LOCAL working tree."
    echo "  (note: formatting-only differences are expected if .apx were hand-edited;"
    echo "   the Builder export is the canonical serialization)"
    if dirs_equal "$APP_SRC" "$scratch/$ALIAS"; then
      local c s; s=$(builder_stamp); c=$(snapshot_export "$scratch"); write_state "$c" "$s"; write_marker import
      echo "PASS: replicas already agree — first syncpoint recorded ($c). Safe to import."
      return 0
    fi
    TMP_KEEP="$scratch"
    echo "  (D = only in LOCAL, A = only in BUILDER, M = differs)"
    tree_diff "$APP_SRC" "$scratch/$ALIAS" | sed 's/^/    /'
    fail "bootstrap: BUILDER ≠ LOCAL and there is no BASE to arbitrate. Reconcile once by hand (Builder export kept at $scratch), commit, then record-sync. See setup.md §2."
  fi

  local base; base=$(materialize_base)
  if dirs_equal "$base" "$scratch/$ALIAS"; then
    write_marker import
    echo "PASS: Builder untouched since last syncpoint. Safe to import."
    return 0
  fi

  # The Builder moved — but if every Builder-side change is already contained
  # in LOCAL (captured/merged earlier), importing loses nothing: it rewrites
  # those files identically. Without this, the gate would be circular: capture
  # the Builder changes, still FAIL, never import.
  local all_captured=1 _st f L R
  while IFS=$'\t' read -r _st f; do
    [[ -z "$f" ]] && continue
    L="$APP_SRC/$f"; R="$scratch/$ALIAS/$f"
    if [[ -f "$R" ]]; then
      { [[ -f "$L" ]] && cmp -s "$L" "$R"; } || { all_captured=0; break; }
    else
      [[ -f "$L" ]] && { all_captured=0; break; }   # Builder deleted it, LOCAL still has it
    fi
  done < <(tree_diff "$base" "$scratch/$ALIAS")
  if (( all_captured )); then
    write_marker import
    echo "PASS: Builder changed since last syncpoint, but LOCAL already contains every Builder-side change. Safe to import (those files are rewritten identically). Remember record-sync afterwards."
    return 0
  fi

  TMP_KEEP="$scratch"
  echo ""
  echo "  Builder changed since the last syncpoint:"
  echo "  (D = only in BASE, A = only in BUILDER, M = differs)"
  tree_diff "$base" "$scratch/$ALIAS" | sed 's/^/    /'
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
  fail "importing now would overwrite the Builder changes above."
}

cmd_check_export() {
  echo "apex-sync-guard: check-export (app $APP_ID '$ALIAS')"
  local dirty; dirty=$(git -C "$ROOT" status --porcelain -- "$SRCDIR")
  if [[ -n "$dirty" ]]; then
    while IFS= read -r line; do printf '    %s\n' "$line"; done <<<"$dirty"
    fail "the APEXlang source dir has uncommitted/untracked changes — the export would clobber them. Commit or stash first, then re-run."
  fi
  write_marker export
  have_base || note "(no syncpoint yet — record-sync after this export will create it)"
  echo "PASS: working tree clean under $SRCDIR. Safe to export."
}

cmd_record_sync() {
  echo "apex-sync-guard: record-sync — exporting the Builder to snapshot its canonical state…"
  local scratch c s
  scratch=$(export_builder)
  s=$(builder_stamp); c=$(snapshot_export "$scratch"); write_state "$c" "$s"
  echo "apex-sync-guard: syncpoint recorded for '$ALIAS'"
  note "commit:       $c"
  note "builderStamp: $s"
}

cmd_status() {
  echo "apex-sync-guard: status (app $APP_ID '$ALIAS' via $CONN)"
  note "repo root:  $ROOT"
  note "source dir: $SRCDIR/$ALIAS"
  if have_base; then
    note "syncpoint:  $(git -C "$ROOT" rev-parse --short "$REF")  recorded $( [[ -f "$STATE" ]] && json_get "$STATE" recordedAt || echo '?')"
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
}

case "${1:-}" in
  check-import) cmd_check_import ;;
  check-export) cmd_check_export ;;
  record-sync)  cmd_record_sync ;;
  status)       cmd_status ;;
  *) die "usage: $(basename "$0") check-import|check-export|record-sync|status" ;;
esac
