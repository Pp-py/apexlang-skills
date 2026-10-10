#!/usr/bin/env bash
# Checks apexlang-architecture's example pages with Oracle's tooling, by injecting
# them into an Oracle base app. Two lanes, never confused:
#
#   --lint      (default) Oracle's 26.1 LOCAL lint (`apexctl apexlang validate`).
#               ADVISORY: Oracle itself calls it "syntax hygiene". PASS = the lint
#               ran to completion and reported exactly the diagnostics listed in
#               expected-diagnostics.txt — nothing new, nothing stale.
#   --compiler  Compiler truth: SQLcl `apex validate`, the contract of Oracle's
#               apexlang-compile script (exit 0 only with "Validation successful").
#               Needs SQLCL_BIN; compiler errors are never allowlisted.
#
# Exit: 0 PASS · 1 FAIL · 2 BLOCKED (a prerequisite is missing, or the tool did not
# run to a verdict). It never prints a pass for a run that did not happen.
set -euo pipefail

MODE=lint
case "${1:-}" in
  ""|--lint) MODE=lint ;;
  --compiler) MODE=compiler ;;
  *) echo "usage: $(basename "$0") [--lint|--compiler]" >&2; exit 2 ;;
esac

blocked() { echo "validate-examples ($MODE): BLOCKED — $*" >&2; exit 2; }

# shellcheck source=tests/lib/resolve-apexlang-pkg.sh
. "$(dirname "$0")/../lib/resolve-apexlang-pkg.sh"
REPO=${REPO:-$(cd "$(dirname "$0")/../.." && pwd)}
EX="$REPO/skills/apexlang-architecture/examples"
SCAFFOLD="$PKG_GEN/templates/base-app-structure/scaffold-example"
[[ -f "$SCAFFOLD/application.apx" && -d "$SCAFFOLD/pages" ]] || blocked "Oracle's 26.1 scaffold is missing: $SCAFFOLD"

# Our five pages, under the names the base app expects (page files are p<5-digit>-<name>.apx).
PAGES=(
  "sectors-catalog/03-page-sectors.apx:p00030-sectors-catalog.apx"
  "absences-workflow/03-page-absences.apx:p00060-absence-requests.apx"
  "absences-workflow/04-page-absence-resolve.apx:p00062-absence-resolve.apx"
  "employees-form/03-page-employee-form.apx:p00041-employee-form.apx"
  "employees-form/04-page-employee-drawer.apx:p00042-employee-drawer.apx"
)
OURS_RE=$(printf '%s\n' "${PAGES[@]}" | sed 's/.*://' | paste -sd'|' -)

STAGE=""
# shellcheck disable=SC2317   # invoked by the EXIT trap
cleanup() { if [[ -n "$STAGE" ]]; then rm -rf "$STAGE"; fi; }   # must return 0: under set -e a
                                                                # failing trap would replace the exit code
trap cleanup EXIT

stage_app() {  # $1 = parent dir to stage in; prints the app dir. Every copy is checked.
  local app="$1/app" p
  mkdir -p "$app"
  cp -r "$SCAFFOLD/." "$app/" || blocked "could not copy the scaffold"
  for p in "${PAGES[@]}"; do
    cp "$EX/${p%%:*}" "$app/pages/${p##*:}" || blocked "could not stage ${p%%:*}"
  done
  printf '%s' "$app"
}

# --------------------------------------------------------------------- lint
if [[ "$MODE" == lint ]]; then
  echo "ADVISORY — Oracle 26.1 local lint (\"syntax hygiene\"), not compiler truth"
  echo "package: $PKG_GEN (revision ${APEXLANG_REV:0:12}${APEXLANG_REV_MATCHES_LOCK:+, lock match=$APEXLANG_REV_MATCHES_LOCK})"
  node -e 0 >/dev/null 2>&1 || blocked "node is required (Oracle's apexctl is a node program)"
  python3 -c 'import json' >/dev/null 2>&1 || blocked "python3 is required (the lint itself runs python3)"
  STAGE=$(mktemp -d "${TMPDIR:-/tmp}/apexlint-XXXXXX")
  APP=$(stage_app "$STAGE")
  out_root="$STAGE/out"
  rc=0
  out=$(APEXLANG_OUTPUT_ROOT="$out_root" node "$PKG_GEN/tools/apexctl.mjs" apexlang validate --app-path "$APP" 2>&1) || rc=$?
  # Ran to a verdict = exactly one final marker AND the reports it writes.
  markers=$(grep -cE '^APEXLANG_LOCAL_CHECK_(OK|FAILED)$' <<<"$out" || true)
  [[ "$markers" == 1 ]] || blocked "the lint did not run to a verdict (exit $rc):$(printf '\n%s' "$out" | tail -15)"
  for r in apexlang-dsl-report.json apexlang-validations-report.json apexlang-vocab-report.json; do
    [[ -f "$out_root/logs/$r" ]] || blocked "the lint wrote no $r — it did not run to completion"
  done
  found=$(python3 - "$out_root/logs" "$OURS_RE" <<'PY'
import json, os, re, sys
logs, ours = sys.argv[1], re.compile(r"(^|/)(" + sys.argv[2] + r")$")
rows = []
for name in ("apexlang-dsl-report.json", "apexlang-validations-report.json"):
    for i in json.load(open(os.path.join(logs, name))).get("issues", []):
        f = os.path.basename(str(i.get("file", "")))
        if ours.search(f):
            rows.append(f"{f} {i.get('rule', '?')} {i.get('message', '')}")
for u in json.load(open(os.path.join(logs, "apexlang-vocab-report.json"))).get("unresolved", []) or []:
    f = os.path.basename(str(u.get("file", "")))
    if ours.search(f):
        rows.append(f"{f} VOCAB:{u.get('legacy_key', '?')} unresolved legacy key")
print("\n".join(sorted(set(rows))))
PY
) || blocked "could not read the lint reports"
  bad=0
  # every diagnostic on our pages must be expected …
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    hit=0
    while IFS= read -r exp; do
      [[ -z "$exp" || "$exp" == \#* ]] && continue
      read -r ef er em <<<"$exp"
      [[ "$line" == "$ef $er"* && ( -z "$em" || "$line" == *"$em"* ) ]] && { hit=1; break; }
    done < "$(dirname "$0")/expected-diagnostics.txt"
    if (( hit )); then echo "expected   $line"; else echo "UNEXPECTED $line"; bad=$((bad + 1)); fi
  done <<<"$found"
  # … and every expected one must still appear (a stale entry hides a fix).
  while IFS= read -r exp; do
    [[ -z "$exp" || "$exp" == \#* ]] && continue
    read -r ef er em <<<"$exp"
    grep -qF -- "$ef $er" <<<"$found" || { echo "STALE      $exp (no longer reported — update the docs that cite it)"; bad=$((bad + 1)); }
  done < "$(dirname "$0")/expected-diagnostics.txt"
  if (( bad )); then echo "lint: FAIL ($bad unexpected or stale)"; exit 1; fi
  echo "lint: PASS — only the documented diagnostics"
  exit 0
fi

# ----------------------------------------------------------------- compiler
[[ -n "${SQLCL_BIN:-}" && -x "${SQLCL_BIN:-}" ]] || blocked "set SQLCL_BIN to the SQLcl executable (from WSL a Windows SQLcl works: SQLCL_BIN=/mnt/c/opt/sqlcl/bin/sql.exe)"
# SQLcl prints its verdict in the JVM's language ("Validación correcta." on a Spanish
# Windows), while Oracle's contract greps the English marker. Pin the JVM to English.
export JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS:+$JAVA_TOOL_OPTIONS }-Duser.language=en -Duser.country=US"
to_native() { printf '%s' "$1"; }
if [[ "$SQLCL_BIN" == *.exe ]] && command -v wslpath >/dev/null 2>&1; then
  # A Windows SQLcl from WSL: it can only read Windows paths, and it only sees
  # environment variables that WSLENV forwards.
  wtemp=$(cmd.exe /c 'echo %TEMP%' 2>/dev/null | tr -d '\r') || true
  [[ -n "$wtemp" ]] || blocked "cannot find a Windows temp dir for a Windows SQLcl"
  STAGE=$(mktemp -d "$(wslpath -u "$wtemp")/apexcompile-XXXXXX")
  to_native() { wslpath -m "$1"; }
  export WSLENV="${WSLENV:+$WSLENV:}JAVA_TOOL_OPTIONS"
elif command -v cygpath >/dev/null 2>&1; then
  STAGE=$(mktemp -d "${TMPDIR:-/tmp}/apexcompile-XXXXXX")
  to_native() { cygpath -m "$1"; }
else
  STAGE=$(mktemp -d "${TMPDIR:-/tmp}/apexcompile-XXXXXX")
fi
APP=$(stage_app "$STAGE")
version=$("$SQLCL_BIN" -V 2>/dev/null | tr -d '\r' | grep -m1 -E 'SQLcl' || true)
echo "compiler: SQLcl apex validate — ${version:-SQLcl version unknown}; base app: Oracle 26.1 scaffold ($(grep -o '"mmdVersion"[^,}]*' "$SCAFFOLD/.apex/apexlang.json" | tr -d ' "'))"
rc=0
out=$(printf 'apex validate -input "%s"\nexit\n' "$(to_native "$APP")" | "$SQLCL_BIN" /nolog 2>&1 | tr -d '\r') || rc=$?
if grep -q 'is not supported by this SQLcl version' <<<"$out"; then
  blocked "this SQLcl cannot compile the app's APEXlang version (an unqualified toolchain pair):$(printf '\n%s' "$out" | grep -m1 'not supported')"
fi
if [[ $rc -eq 0 ]] && grep -qF 'Validation successful' <<<"$out"; then
  echo "compiler: PASS — Validation successful"
  exit 0
fi
if grep -q 'Compile Errors' <<<"$out"; then
  echo "$out" | sed -n '/Compile Errors/,$p'
  echo "compiler: FAIL — SQLcl reported compile errors (exit $rc)"
  exit 1
fi
blocked "SQLcl gave no verdict (exit $rc; no 'Validation successful', no compile errors):$(printf '\n%s' "$out" | tail -10)"
