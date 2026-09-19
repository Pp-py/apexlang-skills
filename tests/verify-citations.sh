#!/usr/bin/env bash
# Checks every sentence this repo quotes from the official `apex` skill against
# the installed APEXlang package, and refuses the fragile citation style.
#
# Two checks:
#   1. each anchor phrase in tests/citations.md still appears EXACTLY once in
#      its upstream file — missing means the rule was reworded or removed,
#      two hits mean the anchor is ambiguous and must be made longer;
#   2. no `<file>.md:<line>` or `(line N)` citation crept back into skills/ —
#      a line number silently points at a different sentence once Oracle edits
#      the file above it, which is the failure this manifest exists to prevent.
#
# Needs the official package: install it (claude plugin install apex@oracle-skills)
# or point at a checkout with PKG=<path/to/oracle-skills>/apex/apexlang.
set -uo pipefail

# shellcheck source=tests/lib/resolve-apexlang-pkg.sh
. "$(dirname "$0")/lib/resolve-apexlang-pkg.sh"
REPO=${REPO:-$(cd "$(dirname "$0")/.." && pwd)}
MANIFEST="$REPO/tests/citations.md"
[[ -f "$MANIFEST" ]] || { echo "manifest not found: $MANIFEST" >&2; exit 2; }

trim() { local s=$1; s=${s#"${s%%[![:space:]]*}"}; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

echo "APEXlang package: $PKG"
echo

ok=0 bad=0
while IFS='|' read -r path anchor _where; do
  path=$(trim "$path")
  anchor=$(trim "$anchor")
  [[ -z "$path" || "$path" == \#* ]] && continue
  file="$PKG/$path"
  short=${path##*/}

  if [[ ! -f "$file" ]]; then
    printf 'GONE    %-38s %s\n' "$short" "(file no longer in the package)"
    bad=$((bad + 1))
    continue
  fi

  # grep -c exits 1 on no match; keep going and read the count instead.
  hits=$(grep -cF -- "$anchor" "$file")
  case "$hits" in
    1) printf 'ok      %-38s %s\n' "$short" "$anchor"; ok=$((ok + 1)) ;;
    0) printf 'MISSING %-38s %s\n' "$short" "$anchor"; bad=$((bad + 1)) ;;
    *) printf 'AMBIG   %-38s %s (%s hits — lengthen the anchor)\n' "$short" "$anchor" "$hits"
       bad=$((bad + 1)) ;;
  esac
done < <(awk '/^```citations$/ { inblock = 1; next } /^```/ { inblock = 0 } inblock' "$MANIFEST")

echo
echo "$ok/$((ok + bad)) anchors still current"

# --- regression guard: the fragile style must not come back -------------------
stale=$(grep -rnE '[A-Za-z0-9._-]+\.md:[0-9]+|\(line [0-9]+\)' --include='*.md' "$REPO/skills" 2>/dev/null)
if [[ -n "$stale" ]]; then
  echo
  echo "line-number citations found in skills/ — anchor them by section + phrase instead:"
  printf '%s\n' "$stale" | sed "s|^$REPO/||"
  bad=$((bad + 1))
else
  echo "no line-number citations in skills/ — ok"
fi

[[ $bad -eq 0 ]] || exit 1
