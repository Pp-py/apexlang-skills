#!/usr/bin/env bash
# Validates apexlang-architecture's example .apx against the installed APEXlang
# package (2026.08.01) by injecting them into the official scaffold app.
# Prints only the diagnostics that belong to OUR files.
set -uo pipefail

# Resolve the APEXlang package: the plugin install first (versioned cache dir),
# then a skills-directory install. Override with PKG=<path/to/apexlang>.
if [[ -z "${PKG:-}" ]]; then
  PKG=$(find "$HOME/.claude/plugins/cache/oracle-skills/apex" -maxdepth 2 -type d -name apexlang 2>/dev/null | sort | tail -1)
  [[ -z "$PKG" && -d "$HOME/.agents/skills/apex/apexlang" ]] && PKG="$HOME/.agents/skills/apex/apexlang"
  [[ -z "$PKG" && -d "$HOME/.claude/skills/apex/apexlang" ]] && PKG="$HOME/.claude/skills/apex/apexlang"
  # WSL: the plugin may be installed on the Windows side only.
  if [[ -z "$PKG" ]]; then
    PKG=$(find /mnt/c/Users/*/.claude/plugins/cache/oracle-skills/apex \
               /mnt/c/Users/*/.claude/plugins/marketplaces/oracle-skills/apex \
               -maxdepth 2 -type d -name apexlang 2>/dev/null | sort | tail -1)
  fi
fi
[[ -n "$PKG" && -d "$PKG" ]] || {
  echo "APEXlang package not found. Install it with: claude plugin install apex@oracle-skills" >&2
  exit 2
}
REPO=${REPO:-$(cd "$(dirname "$0")/.." && pwd)}
V=$(mktemp -d "${TMPDIR:-/tmp}/apexval-XXXXXX")
trap 'rm -rf "$V"' EXIT

cp -r "$PKG/templates/base-app-structure/scaffold-example/." "$V/"
cp "$REPO/skills/apexlang-architecture/examples/sectors-catalog/03-page-sectors.apx"   "$V/pages/p00030-sectors-catalog.apx"
cp "$REPO/skills/apexlang-architecture/examples/absences-workflow/03-page-absences.apx" "$V/pages/p00060-absence-requests.apx"
if [[ -f "$REPO/skills/apexlang-architecture/examples/absences-workflow/04-page-absence-resolve.apx" ]]; then
  cp "$REPO/skills/apexlang-architecture/examples/absences-workflow/04-page-absence-resolve.apx" "$V/pages/p00062-absence-resolve.apx"
fi
cp "$REPO/skills/apexlang-architecture/examples/employees-form/03-page-employee-form.apx"   "$V/pages/p00041-employee-form.apx"
cp "$REPO/skills/apexlang-architecture/examples/employees-form/04-page-employee-drawer.apx" "$V/pages/p00042-employee-drawer.apx"

out=$(node "$PKG/tools/apexctl.mjs" apexlang validate --app-path "$V" 2>&1)
ours=$(grep -E "p00030-sectors-catalog|p00060-absence-requests|p00062-absence-resolve|p00041-employee-form|p00042-employee-drawer" <<<"$out")
if [[ -z "$ours" ]]; then
  echo "CLEAN — no diagnostics against our example pages"
  grep -cE "^ - " <<<"$out" | xargs -I{} echo "({} diagnostics remain, all from Oracle's own scaffold pages)"
  exit 0
fi
while IFS= read -r line; do printf '%s\n' "${line##*/pages/}"; done <<<"$ours"
exit 1
