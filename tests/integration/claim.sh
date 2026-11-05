#!/usr/bin/env bash
# GAP-14 B: a producer claims its destination before the work. It moves the current result to <name>.prev and
# holds <name>.lock (O_EXCL, pid and run id), so a producer that dies after it started leaves no file that reads
# as fresh, and a second producer for the same destination is refused. Exercised through result.claim() and
# through the python producers that call it (sec-scan, plsql-scan, secrets-scan, ux-scan):
#   a second run  → the first result is <name>.prev, the new one is current, no lock is left
#   a live lock   → exit 2 CLAIM_HELD, the destination and the lock untouched
#   a dead pid    → the lock is replaced, with a note on stderr
#   an unreadable lock, or a destination that cannot be moved → exit 2, the old result untouched
#   a producer that dies after the claim → no current file (the old one is the .prev)
#   every exit path of a producer removes its lock
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
PY=$(command -v python3 || command -v python || true)
[[ -n "$PY" ]] || { echo "claim: BLOCKED — python3 is required" >&2; exit 2; }
SCAN="$REPO/skills/apex-security/scripts/sec-scan.py"
PLS="$REPO/skills/apex-security/scripts/plsql-scan.py"
SECR="$REPO/skills/apex-security/scripts/secrets-scan.py"
UXS="$REPO/skills/apex-ux/scripts/ux-scan.py"
FIX="$REPO/tests/integration/fixtures/sec-scan"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/claim-XXXXXX")
SLEEPER=""
cleanup() { [[ -z "$SLEEPER" ]] || kill "$SLEEPER" 2>/dev/null || true; chmod -R u+w "$WORK" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT
P="$WORK/proj"; mkdir -p "$P"; git -C "$P" init -q
cp -r "$FIX/pass" "$P/"
printf '{ "appId": 100, "appAlias": "demo", "publicPages": [5] }\n' > "$P/apex-sync.json"
T="$P/.apex-evidence/T-1"
DEST="$T/security-demo-static.json"
mkdir -p "$P/.apex-evidence" && printf '*\n' > "$P/.apex-evidence/.gitignore"

pass=0; fail=0
ok()  { echo "ok   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1"; fail=$((fail + 1)); sed 's/^/       | /' "$WORK/err.txt" 2>/dev/null | tail -6; }
run() {  # $1 = label, $2 = expected exit, $3 = script, rest = its args (run inside the scratch repo)
  local label=$1 want=$2 script=$3 rc=0; shift 3
  (cd "$P" && "$PY" "$script" "$@" > "$WORK/out.json" 2> "$WORK/err.txt") || rc=$?
  if [[ $rc -eq $want ]]; then ok "$label (exit $rc)"; else bad "$label: exit $rc, expected $want"; fi
}
says() { grep -q -- "$1" "$WORK/err.txt"; }
hash_of() { "$PY" -c "import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$1"; }

# --- the first run: a result, no .prev, no lock
run "sec-scan --task: first run" 0 "$SCAN" --task T-1 pass
if [[ -f "$DEST" && ! -e "$DEST.prev" && ! -e "$DEST.lock" ]]; then ok "first run: a result, no .prev, no .lock"; else bad "first run: wrong files"; fi
FIRST=$(hash_of "$DEST")

# --- the second run: the first becomes .prev
sleep 1     # context.timestamp has a 1 s resolution: the two results must differ
run "sec-scan --task: second run" 0 "$SCAN" --task T-1 pass
if [[ -f "$DEST" && -f "$DEST.prev" && ! -e "$DEST.lock" && "$(hash_of "$DEST.prev")" == "$FIRST" && "$(hash_of "$DEST")" != "$FIRST" ]]; then
  ok "second run: the first result is .prev, the new one is current, the lock is gone"; else bad "second run: .prev is not the first result"; fi

# --- a live lock: a second producer for the same destination is refused, nothing is touched
sleep 120 & SLEEPER=$!
printf '%s R-1\n' "$SLEEPER" > "$DEST.lock"
BEFORE=$(hash_of "$DEST")
run "a live lock → BLOCKED" 2 "$SCAN" --task T-1 pass
if says "security-demo-static.json.lock is held by a running producer"; then ok "  ...the lock and its holder are named"; else bad "live lock: not named"; fi
if [[ "$(hash_of "$DEST")" == "$BEFORE" && -f "$DEST.lock" ]] && [[ "$(grep -c '"status"' "$DEST")" -ge 1 ]]; then ok "  ...the destination and the lock are untouched"; else bad "live lock: the destination or the lock changed"; fi
if "$PY" -c "import json,sys; d=json.load(open(sys.argv[1])); assert d['status'] == 'BLOCKED' and d['reasons'][0]['code'] == 'CLAIM_HELD'" "$WORK/out.json"; then ok "  ...stdout says BLOCKED CLAIM_HELD (the refusal is not written over the other producer's file)"; else bad "live lock: stdout"; fi
kill "$SLEEPER" 2>/dev/null || true; wait "$SLEEPER" 2>/dev/null || true; DEAD=$SLEEPER; SLEEPER=""

# --- a lock whose process is gone: replaced, with a note
printf '%s R-1\n' "$DEAD" > "$DEST.lock"
run "a lock of a dead pid → replaced" 0 "$SCAN" --task T-1 pass
if says "stale lock" && [[ ! -e "$DEST.lock" ]]; then ok "  ...noted on stderr, and no lock is left"; else bad "dead pid: not replaced or not noted"; fi

# --- a lock that cannot be judged: refused, not guessed
printf 'not a pid\n' > "$DEST.lock"
BEFORE=$(hash_of "$DEST")
run "an unreadable lock → BLOCKED" 2 "$SCAN" --task T-1 pass
if says "cannot be read" && [[ "$(hash_of "$DEST")" == "$BEFORE" && -f "$DEST.lock" ]]; then ok "  ...refused and left in place"; else bad "unreadable lock: not refused"; fi
rm -f "$DEST.lock"

# --- every exit path removes the lock: a stop after the claim
run "a path that does not exist → BLOCKED" 2 "$SCAN" --task T-1 no-such-dir
if [[ ! -e "$DEST.lock" && -f "$DEST" ]]; then ok "a stop after the claim leaves no lock"; else bad "a stop left the lock"; fi

# --- a producer that dies after it started: no current file
sleep 1
"$PY" - "$REPO/framework/lib" "$T" <<'PY' || true
import os, sys
sys.path.insert(0, sys.argv[1])
from result import claim
claim(sys.argv[2], "security-demo-static.json")
os._exit(9)                  # killed: no atexit, no write
PY
if [[ ! -e "$DEST" && -f "$DEST.prev" && -f "$DEST.lock" ]]; then ok "killed after the claim: no current file; the old result is .prev; the lock stays"; else bad "killed producer: wrong files"; fi
run "the next run replaces the dead producer's lock" 0 "$SCAN" --task T-1 pass
if [[ -f "$DEST" && ! -e "$DEST.lock" ]] && says "stale lock"; then ok "  ...a new result, no lock"; else bad "killed producer: not recovered"; fi

# --- a destination that cannot be moved: BLOCKED, the old result untouched
if [[ $(id -u) -ne 0 ]]; then
  BEFORE=$(hash_of "$DEST")
  chmod a-w "$T"
  if ! ( : > "$T/probe" ) 2>/dev/null; then
    run "a task dir that cannot be written → BLOCKED" 2 "$SCAN" --task T-1 pass
    chmod u+w "$T"
    if [[ "$(hash_of "$DEST")" == "$BEFORE" && ! -e "$DEST.lock" ]]; then ok "  ...the old result is untouched, and no lock"; else bad "unwritable: the old result changed"; fi
  else chmod u+w "$T"; rm -f "$T/probe"; ok "(read-only directories are not enforced here: case skipped)"; fi
else ok "(running as root: the read-only case is skipped)"; fi

# --- the other python producers claim too
printf 'create or replace package body pkg is begin null; end;\n' > "$P/x.sql" 2>/dev/null || true
for spec in "plsql|$PLS|security-demo-plsql.json|x.sql|0" "secrets|$SECR|security-demo-secrets.json|pass|0" "ux-static|$UXS|ui-demo-static.json|pass|1"; do
  IFS='|' read -r label script name arg want <<< "$spec"
  run "$label: first run" "$want" "$script" --task T-1 "$arg"
  sleep 1
  run "$label: second run" "$want" "$script" --task T-1 "$arg"
  if [[ -f "$T/$name" && -f "$T/$name.prev" && ! -e "$T/$name.lock" ]]; then ok "$label claims its destination: .prev, a new result, no lock"; else bad "$label does not claim"; fi
done

echo "claim: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
