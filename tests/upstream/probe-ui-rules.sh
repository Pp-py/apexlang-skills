#!/usr/bin/env bash
# Measures what Oracle's tools accept on the UI rules apexlang-architecture states — report
# links, markup in report SQL, Cards classes and declarative targets — by injecting the probe
# pages in probes/ui-rules/ into Oracle's 26.1 scaffold. Two lanes, as in validate-examples.sh:
#
#   --lint      (default) Oracle's 26.1 local lint (`apexctl apexlang validate`).
#   --compiler  SQLcl `apex validate`. Needs SQLCL_BIN.
#
# PASS = the lane reported exactly the diagnostics probes/ui-rules/expected.txt lists for it:
# nothing new, nothing stale. Probe 706 is a negative control the compiler must reject, so a
# compiler that checks nothing cannot pass.
# Exit: 0 PASS · 1 FAIL · 2 BLOCKED (a prerequisite is missing, or a tool gave no verdict).
set -euo pipefail

MODE=lint
case "${1:-}" in
  ""|--lint) MODE=lint ;;
  --compiler) MODE=compiler ;;
  *) echo "usage: $(basename "$0") [--lint|--compiler]" >&2; exit 2 ;;
esac

blocked() { echo "probe-ui-rules ($MODE): BLOCKED — $*" >&2; exit 2; }

# shellcheck source=tests/lib/resolve-apexlang-pkg.sh
. "$(dirname "$0")/../lib/resolve-apexlang-pkg.sh"
PROBES="$(cd "$(dirname "$0")" && pwd)/probes/ui-rules"
EXPECTED="$PROBES/expected.txt"
SCAFFOLD="$PKG_GEN/templates/base-app-structure/scaffold-example"
[[ -f "$SCAFFOLD/application.apx" && -d "$SCAFFOLD/pages" ]] || blocked "Oracle's 26.1 scaffold is missing: $SCAFFOLD"
[[ -f "$EXPECTED" ]] || blocked "missing $EXPECTED"

STAGE=""
# shellcheck disable=SC2317   # invoked by the EXIT trap
cleanup() { if [[ -n "$STAGE" ]]; then rm -rf "$STAGE"; fi; }
trap cleanup EXIT

stage_app() {  # $1 = parent dir; prints the app dir
  local app="$1/app" p n=0
  mkdir -p "$app"
  cp -r "$SCAFFOLD/." "$app/" || blocked "could not copy the scaffold"
  for p in "$PROBES"/p*.apx; do
    cp "$p" "$app/pages/" || blocked "could not stage $p"
    n=$((n + 1))
  done
  (( n > 0 )) || blocked "no probe pages in $PROBES"
  printf '%s' "$app"
}

# compare <found rows> — every row must be expected for this lane, every expected row must appear
compare() {
  local found="$1" line exp lane ef em hit bad=0
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    hit=0
    while IFS= read -r exp; do
      [[ -z "$exp" || "$exp" == \#* ]] && continue
      read -r lane ef em <<<"$exp"
      [[ "$lane" == "$MODE" && "$line" == "$ef "* && "$line" == *"$em"* ]] && { hit=1; break; }
    done < "$EXPECTED"
    if (( hit )); then echo "expected   $line"; else echo "UNEXPECTED $line"; bad=$((bad + 1)); fi
  done <<<"$found"
  while IFS= read -r exp; do
    [[ -z "$exp" || "$exp" == \#* ]] && continue
    read -r lane ef em <<<"$exp"
    [[ "$lane" == "$MODE" ]] || continue
    grep -F -- "$ef " <<<"$found" | grep -qF -- "$em" \
      || { echo "STALE      $ef $em (no longer reported — update the docs that cite it)"; bad=$((bad + 1)); }
  done < "$EXPECTED"
  if (( bad )); then echo "$MODE: FAIL ($bad unexpected or stale)"; exit 1; fi
  echo "$MODE: PASS — exactly the expected diagnostics"
  exit 0
}

# --------------------------------------------------------------------- lint
if [[ "$MODE" == lint ]]; then
  echo "package: $PKG_GEN (revision ${APEXLANG_REV:0:12}${APEXLANG_REV_MATCHES_LOCK:+, lock match=$APEXLANG_REV_MATCHES_LOCK})"
  node -e 0 >/dev/null 2>&1 || blocked "node is required (Oracle's apexctl is a node program)"
  python3 -c 'import json' >/dev/null 2>&1 || blocked "python3 is required"
  STAGE=$(mktemp -d "${TMPDIR:-/tmp}/apexprobe-XXXXXX")
  APP=$(stage_app "$STAGE")
  out_root="$STAGE/out"
  rc=0
  out=$(APEXLANG_OUTPUT_ROOT="$out_root" node "$PKG_GEN/tools/apexctl.mjs" apexlang validate --app-path "$APP" 2>&1) || rc=$?
  markers=$(grep -cE '^APEXLANG_LOCAL_CHECK_(OK|FAILED)$' <<<"$out" || true)
  [[ "$markers" == 1 ]] || blocked "the lint did not run to a verdict (exit $rc):$(printf '\n%s' "$out" | tail -15)"
  found=$(python3 - "$out_root/logs" <<'PY'
import json, os, sys
logs, rows = sys.argv[1], set()
for name in ("apexlang-dsl-report.json", "apexlang-validations-report.json"):
    for i in json.load(open(os.path.join(logs, name))).get("issues", []):
        f, rule = os.path.basename(str(i.get("file", ""))), str(i.get("rule", "?"))
        if f.startswith("p007") and not rule.startswith("BREADCRUMB_COVERAGE_"):
            rows.add(f"{f} {rule} {i.get('message', '')}")
print("\n".join(sorted(rows)))
PY
) || blocked "could not read the lint reports"
  compare "$found"
fi

# ----------------------------------------------------------------- compiler
[[ -n "${SQLCL_BIN:-}" && -x "${SQLCL_BIN:-}" ]] || blocked "set SQLCL_BIN to the SQLcl executable (from WSL a Windows SQLcl works: SQLCL_BIN=/mnt/c/opt/sqlcl/bin/sql.exe)"
export JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS:+$JAVA_TOOL_OPTIONS }-Duser.language=en -Duser.country=US"
to_native() { printf '%s' "$1"; }
if [[ "$SQLCL_BIN" == *.exe ]] && command -v wslpath >/dev/null 2>&1; then
  wtemp=$(cmd.exe /c 'echo %TEMP%' 2>/dev/null | tr -d '\r') || true
  [[ -n "$wtemp" ]] || blocked "cannot find a Windows temp dir for a Windows SQLcl"
  STAGE=$(mktemp -d "$(wslpath -u "$wtemp")/apexprobe-XXXXXX")
  to_native() { wslpath -m "$1"; }
  export WSLENV="${WSLENV:+$WSLENV:}JAVA_TOOL_OPTIONS"
elif command -v cygpath >/dev/null 2>&1; then
  STAGE=$(mktemp -d "${TMPDIR:-/tmp}/apexprobe-XXXXXX")
  to_native() { cygpath -m "$1"; }
else
  STAGE=$(mktemp -d "${TMPDIR:-/tmp}/apexprobe-XXXXXX")
fi
APP=$(stage_app "$STAGE")
version=$("$SQLCL_BIN" -V 2>/dev/null | tr -d '\r' | grep -m1 -E 'SQLcl' || true)
echo "compiler: SQLcl apex validate — ${version:-SQLcl version unknown}"
rc=0
out=$(printf 'apex validate -input "%s"\nexit\n' "$(to_native "$APP")" | "$SQLCL_BIN" /nolog 2>&1 | tr -d '\r') || rc=$?
grep -q 'is not supported by this SQLcl version' <<<"$out" \
  && blocked "this SQLcl cannot compile the scaffold's APEXlang version"
if grep -qF 'Validation successful' <<<"$out"; then
  found=""   # the negative control was accepted: compare reports it as stale
elif grep -q 'Compile Errors' <<<"$out"; then
  # "File: pages/<f>" … "Error: <msg>" blocks → "<f> <msg>"
  found=$(sed -n '/Compile Errors/,$p' <<<"$out" | awk '
    /^File: /  { f = $2; sub(/.*\//, "", f) }
    /^Error: / { sub(/^Error: /, ""); print f " " $0 }' | sort -u)
  [[ -n "$found" ]] || blocked "SQLcl reported compile errors in a form this script cannot read:$(printf '\n%s' "$out" | tail -10)"
else
  blocked "SQLcl gave no verdict (exit $rc):$(printf '\n%s' "$out" | tail -10)"
fi
compare "$found"
