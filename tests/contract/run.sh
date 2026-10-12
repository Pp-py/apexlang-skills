#!/usr/bin/env bash
# Contract tier: the JSON contracts in framework/schemas/ hold — for the schemas
# themselves, for the fixtures and negatives here, and for every result the tools
# actually emit — and the surface a reader relies on has not drifted (surface.py).
# The emitted results come from running the integration e2e with
# SYNC_RESULT_CAPTURE_DIR set, and the apex-ux and apex-security suites with RESULT_CAPTURE_DIR, so a
# script change that writes an invalid result fails here even when every exit code in
# those suites is still right.
#
# Exit: 0 PASS · 1 FAIL · 2 BLOCKED (python3 or jsonschema missing — never a pass).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)

PY=$(command -v python3 || command -v python || true)
[[ -n "$PY" ]] || { echo "contract: BLOCKED — python3 is required" >&2; exit 2; }
"$PY" -c 'import jsonschema' 2>/dev/null \
  || { echo "contract: BLOCKED — python jsonschema is required (apt install python3-jsonschema, or pip install jsonschema)" >&2; exit 2; }

CAP=$(mktemp -d "${TMPDIR:-/tmp}/apexlang-contract-XXXXXX")
trap 'rm -rf "$CAP"' EXIT
mkdir -p "$CAP/results"

echo "== integration e2e, capturing every sync-result it makes the script emit"
if ! SYNC_RESULT_CAPTURE_DIR="$CAP/results" bash "$REPO/tests/integration/sync-guard-e2e.sh" > "$CAP/e2e.log" 2>&1; then
  tail -30 "$CAP/e2e.log"
  echo "contract: FAIL — the e2e itself failed, so its results prove nothing"
  exit 1
fi
tail -1 "$CAP/e2e.log"

echo "== apex-ux and apex-security suites, capturing every result they make the scripts emit"
for t in ux-scan ux-check sec-scan plsql-scan; do
  if ! RESULT_CAPTURE_DIR="$CAP/results" bash "$REPO/tests/integration/$t.sh" > "$CAP/$t.log" 2>&1; then
    tail -30 "$CAP/$t.log"
    echo "contract: FAIL — $t itself failed, so its results prove nothing"
    exit 1
  fi
  tail -1 "$CAP/$t.log"
done

echo "== schemas, fixtures, negatives, emitted results"
rc=0
"$PY" "$HERE/schemas.py" --captured "$CAP/results" || rc=$?
echo "== surface: links, interface, duplicated patterns, criterion IDs"
"$PY" "$HERE/surface.py" || rc=$?
exit "$rc"
