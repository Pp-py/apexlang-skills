#!/usr/bin/env bash
# apex-sync-guard — Builder↔Git divergence guard for APEXlang apps.
#
# Usage (from anywhere inside the project repo):
#   apex-sync-check.sh check-import   # gate before `apex import`
#   apex-sync-check.sh check-export   # gate before `apex export`
#   apex-sync-check.sh record-sync    # after a successful import/export
#   apex-sync-check.sh status         # inspect syncpoint + both replicas
#   apex-sync-check.sh doctor         # validate this machine's wiring end to end
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

die()  { echo "apex-sync-guard: ERROR: $*" >&2; exit 2; }
fail() { echo ""; echo "FAIL: $*" >&2; exit 1; }
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

# ---------------------------------------------------------------- setup
[[ -n "${BASH_VERSION:-}" ]] || die "run this under bash (on Windows: Git Bash or WSL — PowerShell and cmd cannot execute it)"
case "${OSTYPE:-}" in
  msys*|cygwin*) command -v cygpath >/dev/null 2>&1 || die "cygpath not found — run this from Git Bash (Git for Windows), not from a bare MSYS shell" ;;
esac
command -v sql >/dev/null || die "SQLcl (sql) is required on PATH"

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
resolve_json_tool || die "no working JSON parser — need jq, or a python that actually runs.
      A 'python3' that exists but does nothing when executed is typically the
      Microsoft Store stub: install real Python (or jq) and put it ahead of it on PATH."

json_get() {  # $1 = json file ('-' = stdin), $2 = dotted key path
  if [[ "${JSON_TOOL[0]}" == "jq" ]]; then
    jq -r ".$2 // empty" "$1"
  else
    "${JSON_TOOL[@]}" -c '
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
  if [[ "${JSON_TOOL[0]}" == "jq" ]]; then
    jq -r ".$2[]?" "$1"
  else
    "${JSON_TOOL[@]}" -c '
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

# BASE round-trips through git objects (add → write-tree → archive). Content
# filters would rewrite the bytes on the way in or out, so every git call that
# stores or restores a replica runs with them off and with attribute lookup
# pinned to an empty file — the syncpoint must return exactly what was exported.
: > "$STATE_DIR/empty-attributes"
GIT_HERMETIC=(-c core.autocrlf=false -c core.eol=lf -c core.safecrlf=false
              -c "core.attributesfile=$STATE_DIR/empty-attributes")
export GIT_ATTR_NOSYSTEM=1

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
  local scratch native; scratch=$(mktemp -d "${TMPDIR:-/tmp}/apex-sync-remote-XXXXXX"); TMPS+=("$scratch")
  native=$(native_path "$scratch")
  [[ "$native" == *" "* ]] && native="\"$native\""     # SQLcl splits its arguments on spaces
  run_sql "apex export -applicationid $APP_ID -expType APEXLANG -dir $native" >/dev/null
  [[ -f "$scratch/$ALIAS/application.apx" ]] || die "apex export produced no $ALIAS/application.apx in $scratch (SQLcl was given -dir $native) — check connection/app id; if that path holds spaces, point TMPDIR at one that does not"
  echo "$scratch"
}

# ------------------------------------------------------------ git layer
have_base() { git -C "$ROOT" rev-parse -q --verify "$REF" >/dev/null; }

materialize_base() {  # extracts the BASE tree to a tmpdir; prints path of the app dir
  local t; t=$(mktemp -d "${TMPDIR:-/tmp}/apex-sync-base-XXXXXX"); TMPS+=("$t")
  git -C "$ROOT" "${GIT_HERMETIC[@]}" archive "$REF" | tar -x -C "$t"
  echo "$t/$ALIAS"
}

# BASE is always snapshotted from an `apex export` scratch dir, never from the
# raw working tree: hand-edited .apx differ textually (whitespace, fenced vs
# inline blocks, JSON spacing) from the exporter's canonical serialization, so
# only canonical-vs-canonical comparisons are noise-free.
snapshot_export() {  # $1 = scratch dir containing <alias>/…; commits it to $REF
  local tmpidx tree commit
  tmpidx=$(mktemp -u "${TMPDIR:-/tmp}/apex-sync-idx-XXXXXX")
  GIT_INDEX_FILE=$tmpidx git "${GIT_HERMETIC[@]}" --git-dir="$ROOT/.git" --work-tree="$1" add -f -A -- . 2>/dev/null
  tree=$(GIT_INDEX_FILE=$tmpidx git --git-dir="$ROOT/.git" write-tree)
  commit=$(git -C "$ROOT" commit-tree "$tree" -m "apex-sync syncpoint $ALIAS $(now_iso)")
  git -C "$ROOT" update-ref "$REF" "$commit"
  rm -f "$tmpidx"
  echo "$commit"
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

ignored() {  # $1 = app-relative path
  local p
  for p in "${IGNORE_PATHS[@]:-}"; do
    [[ -n "$p" && "$1" == "$p"* ]] && return 0
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

dirs_equal() { [[ -z "$(blocking "$(tree_diff "$1" "$2")")" ]]; }

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
  echo ""
  if (( n == 0 )); then
    note "Nothing to deploy: LOCAL matches the syncpoint (if you expected changes, they were not generated/saved)."
    return 0
  fi
  recorded=$( [[ -f "$STATE" ]] && json_get "$STATE" recordedAt || echo "")
  commits=$( [[ -n "$recorded" ]] && git -C "$ROOT" log --oneline --since="$recorded" -- "$SRCDIR" | grep -c . || echo "?")
  note "This import DEPLOYS the accumulated LOCAL backlog — \`apex import\` replaces the WHOLE app:"
  note "(A = new in LOCAL, M = differs, D = removed from LOCAL)"
  indent <<<"$dif"
  note "$n file(s), $commits commit(s) touching $SRCDIR since the syncpoint${recorded:+ ($recorded)}"
  note "(may include formatting-only entries: LOCAL is hand-edited, BASE is the exporter's canonical form)"
}

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
    local boot; boot=$(tree_diff "$APP_SRC" "$scratch/$ALIAS")
    if [[ -z "$(blocking "$boot")" ]]; then
      local c s; s=$(builder_stamp); c=$(snapshot_export "$scratch"); write_state "$c" "$s"; write_marker import
      echo "PASS: replicas already agree — first syncpoint recorded ($c). Safe to import."
      eol_note "$boot"
      return 0
    fi
    TMP_KEEP="$scratch"
    echo "  (D = only in LOCAL, A = only in BUILDER, M = differs, E = line endings only)"
    indent <<<"$boot"
    eol_note "$boot"
    fail "bootstrap: BUILDER ≠ LOCAL and there is no BASE to arbitrate. Reconcile once by hand (Builder export kept at $scratch), commit, then record-sync. See setup.md §2."
  fi

  local base dif; base=$(materialize_base); dif=$(tree_diff "$base" "$scratch/$ALIAS")
  if [[ -z "$(blocking "$dif")" ]]; then
    write_marker import
    echo "PASS: Builder untouched since last syncpoint. Safe to import."
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
    write_marker import
    echo "PASS: Builder changed since last syncpoint, but LOCAL already contains every Builder-side change. Safe to import (those files are rewritten identically). Remember record-sync afterwards."
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

DOC_BAD=0
doc_ok()   { printf '  OK    %s\n' "$*"; }
doc_note() { printf '  --    %s\n' "$*"; }
doc_fail() { printf '  FAIL  %s\n' "$*"; DOC_BAD=$((DOC_BAD+1)); }

# One command to validate a machine before trusting the guard on it. Everything is
# probed by doing it, never by "the binary is on PATH" — that is what let a stub
# python3 and an unconvertible scratch path through in the first place.
cmd_doctor() {
  echo "apex-sync-guard: doctor (app $APP_ID '$ALIAS')"
  doc_ok "bash ${BASH_VERSION%%(*} on ${OSTYPE:-unknown}"
  case "${OSTYPE:-}" in
    msys*|cygwin*) doc_ok "cygpath present — SQLcl will be handed e.g. $(native_path "${TMPDIR:-/tmp}")" ;;
    *)             doc_note "not a Windows shell — no path conversion needed" ;;
  esac
  doc_ok "$(git --version)"
  doc_ok "SQLcl: $(command -v sql)"
  doc_ok "JSON parser (probed by execution): ${JSON_TOOL[*]}"
  doc_ok "byte comparator: $( [[ "$BYTES_EQ" == cmp ]] && echo "cmp" || echo "git hash-object --no-filters (cmp unavailable)" )"
  doc_ok "config: $CFG → dir $SRCDIR, connection $CONN"
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
  have_base && payload_report "$(materialize_base)"
}

case "${1:-}" in
  check-import) cmd_check_import ;;
  check-export) cmd_check_export ;;
  record-sync)  cmd_record_sync ;;
  status)       cmd_status ;;
  doctor)       cmd_doctor ;;
  *) die "usage: $(basename "$0") check-import|check-export|record-sync|status|doctor" ;;
esac
