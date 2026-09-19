#!/usr/bin/env bash
# Resolves the installed APEXlang package into $PKG, and exits 2 with an
# actionable message when it cannot be found. Sourced by the tests that need
# the official package (validate-examples.sh, verify-citations.sh).
#
# Lookup order: plugin install (versioned cache dir) -> skills-directory
# install -> the Windows side, for WSL. Override with PKG=<path/to/apexlang>.
#
# Sourced, not executed: it must set PKG in the caller's shell.

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
  echo "Or point at a checkout: PKG=<path/to/oracle-skills>/apex/apexlang $0" >&2
  exit 2
}
