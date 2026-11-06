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
# a live holder as the producers see it: a python process, whose pid is the one os.getpid() reports (on Git Bash $! is not)
"$PY" -c "import os, time; print(os.getpid(), flush=True); time.sleep(120)" > "$WORK/holder.pid" & SLEEPER=$!
for _ in $(seq 1 50); do [[ -s "$WORK/holder.pid" ]] && break; sleep 0.1; done
HELD_PID=$(tr -d '\r\n' < "$WORK/holder.pid")
printf '%s R-1\n' "$HELD_PID" > "$DEST.lock"
BEFORE=$(hash_of "$DEST")
run "a live lock → BLOCKED" 2 "$SCAN" --task T-1 pass
if says "security-demo-static.json.lock is held by a running producer"; then ok "  ...the lock and its holder are named"; else bad "live lock: not named"; fi
if [[ "$(hash_of "$DEST")" == "$BEFORE" && -f "$DEST.lock" ]] && [[ "$(grep -c '"status"' "$DEST")" -ge 1 ]]; then ok "  ...the destination and the lock are untouched"; else bad "live lock: the destination or the lock changed"; fi
if "$PY" -c "import json,sys; d=json.load(open(sys.argv[1])); assert d['status'] == 'BLOCKED' and d['reasons'][0]['code'] == 'CLAIM_HELD'" "$WORK/out.json"; then ok "  ...stdout says BLOCKED CLAIM_HELD (the refusal is not written over the other producer's file)"; else bad "live lock: stdout"; fi
kill "$SLEEPER" 2>/dev/null || true; wait "$SLEEPER" 2>/dev/null || true; DEAD=$HELD_PID; SLEEPER=""
sleep 1

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

# --- M38-01 (review 11): two contenders on one abandoned lock, in a controlled interleaving. B judges the lock stale
# and is stopped (a barrier inside _alive) before it acts; A recovers the lock and holds it; B resumes. B must be
# refused and A's lock left alone; only one of them is ever inside the protected section.
rm -f "$DEST.lock" "$DEST.lock.recover"
RACE="$WORK/race"; mkdir -p "$RACE"
printf '%s R-0 x\n' "$DEAD" > "$DEST.lock"
cat > "$WORK/race.py" <<'PY'
import os, sys, time
sys.path.insert(0, sys.argv[1])
import result
role, task, race = sys.argv[2], sys.argv[3], sys.argv[4]
def wait(f):
    for _ in range(300):
        if os.path.exists(f):
            return
        time.sleep(0.1)
    sys.exit("barrier timeout")
if role == "B":
    real = result._alive
    def alive(pid):
        r = real(pid)
        open(os.path.join(race, "b-judged"), "w").close()
        wait(os.path.join(race, "a-holds"))
        return r
    result._alive = alive
try:
    result.claim(task, "security-demo-static.json")
except result.Stop as e:
    print(role, "REFUSED", e.code, flush=True)
    sys.exit(0)
print(role, "ACQUIRED", flush=True)
if role == "A":
    open(os.path.join(race, "a-holds"), "w").close()
    wait(os.path.join(race, "b-done"))
PY
"$PY" "$WORK/race.py" "$REPO/framework/lib" B "$T" "$RACE" > "$WORK/b.out" 2>&1 & BPID=$!
for _ in $(seq 1 100); do [[ -e "$RACE/b-judged" ]] && break; sleep 0.1; done
"$PY" "$WORK/race.py" "$REPO/framework/lib" A "$T" "$RACE" > "$WORK/a.out" 2>&1 & APID=$!
for _ in $(seq 1 100); do [[ -e "$RACE/a-holds" ]] && break; sleep 0.1; done
for _ in $(seq 1 100); do [[ -s "$WORK/b.out" ]] && break; sleep 0.1; done
A_LOCK=$(cat "$DEST.lock" 2>/dev/null || true)
touch "$RACE/b-done"; wait "$APID" || true; wait "$BPID" || true
if grep -q "^A ACQUIRED" "$WORK/a.out" && grep -q "^B REFUSED CLAIM_HELD" "$WORK/b.out"; then ok "interleaved recovery: A acquires, B (which judged the same stale lock) is refused"; else bad "interleaved recovery: A=$(tr '\n' ' ' < "$WORK/a.out") B=$(tr '\n' ' ' < "$WORK/b.out")"; fi
if [[ -n "$A_LOCK" && "$A_LOCK" != *"$DEAD R-0"* ]]; then ok "  ...B did not delete A's lock (it still carried A's token when B was refused)"; else bad "interleaved recovery: A's lock was removed or is the stale one"; fi
rm -f "$DEST.lock" "$DEST.lock.recover"

# a recovery already in progress: the second contender is refused, nothing removed
printf '%s R-0 x\n' "$DEAD" > "$DEST.lock"; : > "$DEST.lock.recover"
run "a recovery in progress → BLOCKED" 2 "$SCAN" --task T-1 pass
if says "being recovered" && [[ -f "$DEST.lock" && -f "$DEST.lock.recover" ]]; then ok "  ...refused; the stale lock and the recovery guard are untouched"; else bad "recovery in progress: not refused"; fi
rm -f "$DEST.lock" "$DEST.lock.recover"

# a lock is released only by its owner: after another producer replaced it, the old owner's release leaves it
REL=0
"$PY" - "$REPO/framework/lib" "$T" <<'PY' || REL=1
import os, sys
sys.path.insert(0, sys.argv[1])
import result
task = sys.argv[2]
result.claim(task, "security-demo-static.json")
lock = os.path.join(task, "security-demo-static.json.lock")
open(lock, "w").write("999999 R-9 other-token\n")        # someone else took the lock over
result.release(lock)
assert open(lock).read() == "999999 R-9 other-token\n", "the other owner's lock was deleted"
os.remove(lock)
PY
if [[ $REL -eq 0 ]]; then ok "release by an old owner leaves the new owner's lock"; else bad "release removed another producer's lock"; fi
rm -f "$DEST.lock" "$DEST.lock.recover"

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
