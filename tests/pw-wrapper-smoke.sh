#!/usr/bin/env bash
# Smoke test for apex-sentinel's pw.sh, offline: a stubbed Playwright CLI records
# the argv it was handed and serves a canned `list --json`, so the wrapper's two
# guarantees can be asserted without a browser —
#   * `open` on a LIVE session is routed to `goto` (a real open would kill the
#     browser and discard the APEX login), and
#   * the TLS config is written and passed as a path that actually exists.
set -euo pipefail

PW=$(cd "$(dirname "$0")/../skills/apex-sentinel" && pwd)/scripts/pw.sh
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pw-smoke-XXXXXX")
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/badjq" "$WORK/ws"

cat > "$WORK/bin/playwright-cli" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$PW_LOG"
case " $* " in *" --version "*) echo "1.0.0"; exit 0 ;; esac
for a in "$@"; do [[ "$a" == "list" ]] && { cat "$PW_STATE"; exit 0; }; done
exit 0
EOF
chmod +x "$WORK/bin/playwright-cli"
printf '#!/usr/bin/env bash\nexit 127\n' > "$WORK/badjq/jq"      # present but broken
chmod +x "$WORK/badjq/jq"

export PATH="$WORK/bin:$PATH" PW_STATE="$WORK/state.json" PW_WORKSPACE="$WORK/ws"
OPEN='{"browsers":[{"name":"apex","workspace":"/x","status":"open"}]}'
SHUT='{"browsers":[]}'

pass=0; fail=0
check() {  # $1 = description, $2 = ERE the recorded argv must match
  if grep -qE -- "$2" "$PW_LOG"; then echo "ok   $1"; pass=$((pass+1))
  else echo "FAIL $1 (argv did not match /$2/)"; sed 's/^/       | /' "$PW_LOG"; fail=$((fail+1)); fi
}
run() {  # $1 = session state, rest = pw.sh args
  printf '%s\n' "$1" > "$PW_STATE"; shift
  PW_LOG="$WORK/log"; export PW_LOG; : > "$PW_LOG"
  "$PW" "$@" >/dev/null 2>&1
}

run "$SHUT" open "https://apex.example/r/ws/APP/"
check "closed session -> open, with --config" '-s apex open --config .* https://'
cfg=$(grep -o -- '--config [^ ]*' "$PW_LOG" | head -1 | cut -d' ' -f2)
if [[ -s "$cfg" ]] && grep -q ignoreHTTPSErrors "$cfg"; then
  echo "ok   --config points at a written TLS config"; pass=$((pass+1))
else
  echo "FAIL --config path does not exist or lacks ignoreHTTPSErrors: $cfg"; fail=$((fail+1))
fi

run "$OPEN" open "https://apex.example/p30"
check "live session -> goto, never a destructive open" '^-s apex goto '

# The session probe must not depend on jq merely being present: a jq that errors
# would report the live session as closed and the recovery path would then open —
# killing the browser and the APEX login it holds.
export PATH="$WORK/badjq:$PATH"
run "$OPEN" open "https://apex.example/p31"
check "broken jq + live session -> still goto" '^-s apex goto '
run "$SHUT" open "https://apex.example/p31"
check "broken jq + closed session -> open" '^-s apex open '

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
