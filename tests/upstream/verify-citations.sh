#!/usr/bin/env bash
# Checks every passage this repo quotes from Oracle's APEXlang skills against the
# installed package, and refuses the fragile citation style.
#
# Two checks:
#   1. each anchor phrase in tests/upstream/citations.md still appears EXACTLY once
#      in its upstream file — missing means the rule was reworded or removed, two
#      hits mean the anchor is ambiguous and must be made longer;
#   2. no `<file>.md:<line>` or `(line N)` citation crept back into skills/ — a
#      line number silently points at a different sentence once Oracle edits the
#      file above it, which is the failure this manifest exists to prevent.
#
# Needs Oracle's skills installed (claude plugin install apex@oracle-skills) or
# APEXLANG_ROOT=<oracle-skills>/apex/apexlang. Exit: 0 PASS · 1 FAIL · 2 BLOCKED.
set -uo pipefail

# shellcheck source=tests/lib/resolve-apexlang-pkg.sh
. "$(dirname "$0")/../lib/resolve-apexlang-pkg.sh"
REPO=${REPO:-$(cd "$(dirname "$0")/../.." && pwd)}
MANIFEST="$REPO/tests/upstream/citations.md"
[[ -f "$MANIFEST" ]] || { echo "manifest not found: $MANIFEST" >&2; exit 2; }

trim() { local s=$1; s=${s#"${s%%[![:space:]]*}"}; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

echo "Oracle APEXlang skills: $APEXLANG_ROOT"
if (( APEXLANG_REV_MATCHES_LOCK )); then
  echo "revision: ${APEXLANG_REV:0:12} (the locked commit)"
else
  echo "revision: ${APEXLANG_REV:-unknown} — NOT the locked ${LOCK_COMMIT:0:12}; a pass here does not verify the lock"
fi
echo

ok=0 bad=0 rows=0
while IFS='|' read -r path anchor _where; do
  path=$(trim "$path")
  anchor=$(trim "$anchor")
  [[ -z "$path" || "$path" == \#* ]] && continue
  rows=$((rows + 1))
  file="$APEXLANG_ROOT/$path"
  short=${path##*/}

  if [[ ! -f "$file" ]]; then
    printf 'GONE    %-38s %s\n' "$short" "(file no longer in the package: $path)"
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
done < <(awk '/^```citations\r?$/ { inblock = 1; next } /^```/ { inblock = 0 } inblock' "$MANIFEST" | tr -d '\r')

# Zero rows is a broken manifest (a renamed fence, a CRLF checkout), never a pass.
(( rows > 0 )) || { echo "no citation rows found in $MANIFEST — the manifest itself is broken" >&2; exit 2; }

echo
echo "$ok/$rows anchors still current"

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
