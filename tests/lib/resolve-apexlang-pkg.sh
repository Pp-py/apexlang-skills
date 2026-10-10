#!/usr/bin/env bash
# Resolves Oracle's installed APEXlang skills (apex@oracle-skills) for the upstream
# tier. Sourced, not executed: it sets variables in the caller's shell.
#
#   APEXLANG_ROOT              the version router: <plugin>/apexlang (SKILL.md, 26.1/, 26.2/)
#   PKG_GEN                    the 26.1 generation bundle (apexctl, policies, scaffold)
#   APEXLANG_REV               the installed commit, when it is known
#   APEXLANG_REV_MATCHES_LOCK  1 when that commit is the one framework/oracle-skills.lock.json pins
#
# Lookup, most specific first: APEXLANG_ROOT=<…/apex/apexlang> → the plugin cache
# directory named after the locked commit → what installed_plugins.json records
# (newest first; warns, MATCHES_LOCK=0). Never "the newest directory by mtime" or
# `sort | tail`: cache directories are named by commit, and sorting hashes picks one
# at random. Anything missing exits 2 (BLOCKED) — an upstream test that cannot find
# the package must never report a result.

_res_repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
_res_lock="$_res_repo/framework/oracle-skills.lock.json"
_res_die() { echo "upstream: BLOCKED — $*" >&2; exit 2; }

[[ -f "$_res_lock" ]] || _res_die "lock file missing: $_res_lock"
LOCK_COMMIT=$(sed -n 's/.*"commit"[[:space:]]*:[[:space:]]*"\([0-9a-f]\{40\}\)".*/\1/p' "$_res_lock" | head -1)
[[ -n "$LOCK_COMMIT" ]] || _res_die "no 40-hex \"commit\" in $_res_lock"
[[ -z "${PKG:-}" ]] || _res_die "PKG is no longer read (Oracle's layout is versioned since 2026-10-06): set APEXLANG_ROOT=<oracle-skills>/apex/apexlang instead"

APEXLANG_REV=""
if [[ -n "${APEXLANG_ROOT:-}" ]]; then
  APEXLANG_REV=$(git -C "$APEXLANG_ROOT" rev-parse HEAD 2>/dev/null || true)
else
  for _res_base in "$HOME/.claude/plugins/cache/oracle-skills/apex" /mnt/c/Users/*/.claude/plugins/cache/oracle-skills/apex; do
    if [[ -d "$_res_base/${LOCK_COMMIT:0:12}/apexlang" ]]; then
      APEXLANG_ROOT="$_res_base/${LOCK_COMMIT:0:12}/apexlang"; APEXLANG_REV=$LOCK_COMMIT; break
    fi
  done
fi
if [[ -z "${APEXLANG_ROOT:-}" ]]; then
  # Not the locked commit: take what Claude Code says is installed, and say so.
  for _res_ip in "$HOME/.claude/plugins/installed_plugins.json" /mnt/c/Users/*/.claude/plugins/installed_plugins.json; do
    [[ -f "$_res_ip" ]] || continue
    _res_line=$(python3 -c '
import json, sys
recs = json.load(open(sys.argv[1])).get("plugins", {}).get("apex@oracle-skills", [])
recs = sorted(recs, key=lambda r: r.get("lastUpdated", ""), reverse=True)
if recs: print(recs[0].get("gitCommitSha", "") + "\t" + recs[0].get("installPath", ""))' "$_res_ip" 2>/dev/null) || continue
    _res_path=${_res_line#*$'\t'}
    [[ "$_res_path" == [A-Za-z]:* ]] && command -v wslpath >/dev/null 2>&1 && _res_path=$(wslpath -u "$_res_path")
    if [[ -n "$_res_path" && -d "$_res_path/apexlang" ]]; then
      APEXLANG_ROOT="$_res_path/apexlang"; APEXLANG_REV=${_res_line%%$'\t'*}
      echo "upstream: WARNING — using the installed apex@oracle-skills ($APEXLANG_REV), not the locked $LOCK_COMMIT" >&2
      break
    fi
  done
fi
[[ -n "${APEXLANG_ROOT:-}" ]] || _res_die "Oracle's APEXlang skills are not installed. Install them with:
      claude plugin marketplace add oracle/skills && claude plugin install apex@oracle-skills
    or point APEXLANG_ROOT at a checkout: APEXLANG_ROOT=<oracle-skills>/apex/apexlang"
[[ -f "$APEXLANG_ROOT/SKILL.md" && -f "$APEXLANG_ROOT/26.1/apexlang-generation/tools/apexctl.mjs" ]] \
  || _res_die "$APEXLANG_ROOT is not Oracle's versioned layout (26.1/apexlang-generation/…) — a pre-2026-10-06 install? Update apex@oracle-skills."
PKG_GEN="$APEXLANG_ROOT/26.1/apexlang-generation"
APEXLANG_REV_MATCHES_LOCK=0
[[ "$APEXLANG_REV" == "$LOCK_COMMIT" ]] && APEXLANG_REV_MATCHES_LOCK=1
export APEXLANG_ROOT PKG_GEN APEXLANG_REV APEXLANG_REV_MATCHES_LOCK LOCK_COMMIT
