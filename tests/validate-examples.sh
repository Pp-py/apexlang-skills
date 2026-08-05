#!/usr/bin/env bash
# Validates apexlang-architecture's example .apx against the installed APEXlang
# package (2026.08.01) by injecting them into the official scaffold app.
# Prints only the diagnostics that belong to OUR files.
set -uo pipefail

PKG=${PKG:-$HOME/.agents/skills/apex/apexlang}
REPO=${REPO:-/home/palmera/skills/apexlang-skills}
V=$(mktemp -d "${TMPDIR:-/tmp}/apexval-XXXXXX")
trap 'rm -rf "$V"' EXIT

cp -r "$PKG/templates/base-app-structure/scaffold-example/." "$V/"
cp "$REPO/skills/apexlang-architecture/examples/sectors-catalog/03-page-sectors.apx"   "$V/pages/p00030-sectors-catalog.apx"
cp "$REPO/skills/apexlang-architecture/examples/absences-workflow/03-page-absences.apx" "$V/pages/p00060-absence-requests.apx"
if [[ -f "$REPO/skills/apexlang-architecture/examples/absences-workflow/04-page-absence-resolve.apx" ]]; then
  cp "$REPO/skills/apexlang-architecture/examples/absences-workflow/04-page-absence-resolve.apx" "$V/pages/p00062-absence-resolve.apx"
fi

out=$(node "$PKG/tools/apexctl.mjs" apexlang validate --app-path "$V" 2>&1)
ours=$(grep -E "p00030-sectors-catalog|p00060-absence-requests|p00062-absence-resolve" <<<"$out")
if [[ -z "$ours" ]]; then
  echo "CLEAN — no diagnostics against our example pages"
  grep -cE "^ - " <<<"$out" | xargs -I{} echo "({} diagnostics remain, all from Oracle's own scaffold pages)"
  exit 0
fi
echo "$ours" | sed 's|/tmp/apexval-[^/]*/pages/||'
exit 1
