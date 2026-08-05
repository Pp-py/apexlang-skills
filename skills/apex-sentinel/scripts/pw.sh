#!/usr/bin/env bash
# apex-sentinel — idempotent Playwright CLI entry point for runtime verification.
#
# Usage (from anywhere; every call is self-contained):
#   pw.sh open <url>        open the browser session on <url>, or reuse+navigate if already open
#   pw.sh goto <url>        navigate the held session
#   pw.sh eval '() => ...'  any other playwright-cli subcommand, passed through verbatim
#   pw.sh find <text>       (snapshot / find / run-code / dialog-accept / screenshot / ...)
#   pw.sh close-all         tear the session down at the end of the loop
#
# Why this wrapper exists (each line is a failure it removes):
#   * The CLI is often NOT a global binary — it is reachable via npx. `which
#     playwright-cli` is therefore the wrong availability test; this resolves a
#     launcher and probes it on EXIT CODE, never on message text.
#   * The daemon session is keyed by a hash of the nearest ancestor directory
#     containing .playwright/ (playwright-core findWorkspaceDir). The agent shell
#     resets its cwd between calls, so a command issued from elsewhere cannot see
#     the session and fails with "browser is not open". Every call cd's to one
#     stable workspace.
#   * Self-signed TLS (common on APEX DEV/STAGING) needs ignoreHTTPSErrors, which
#     lives in a config file written here once — never in the consuming repo.
#   * A repeated bare `open` KILLS the running browser and starts a new one,
#     silently discarding the APEX login and session token. `open` on an already
#     open session is routed to `goto` instead.
#
# Environment (all optional):
#   PW_WORKSPACE      dir anchoring the daemon session, config and snapshots.
#                     Default: a scratchpad dir; never the project repo.
#   PW_SESSION        browser session name (default: apex)
#   PW_INSECURE_TLS   1 (default) accept self-signed certs; 0 to enforce validation
#
# Runs under bash: Linux, macOS, and Windows via Git Bash or WSL (not PowerShell/cmd).
set -euo pipefail

die()  { echo "apex-sentinel: ERROR: $*" >&2; exit 2; }
warn() { echo "apex-sentinel: $*" >&2; }

# --config is read by node, a native binary on Windows: a POSIX path from this
# shell would be resolved against the current drive and the config silently missed
# (and with it ignoreHTTPSErrors, so the loop stalls on a self-signed cert).
native_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

[[ $# -gt 0 ]] || die "no subcommand — try: $(basename "$0") open <url>"

# ------------------------------------------------------------------ workspace
# One stable directory for the whole verification loop. Defaults outside any
# repository so a run never leaves .playwright*/ droppings in the user's project.
: "${PW_WORKSPACE:=${CLAUDE_SCRATCHPAD:-${TMPDIR:-/tmp}}/apex-sentinel-pw}"
: "${PW_SESSION:=apex}"
: "${PW_INSECURE_TLS:=1}"

mkdir -p "$PW_WORKSPACE/.playwright" || die "cannot create workspace $PW_WORKSPACE"
PW_WORKSPACE=$(cd "$PW_WORKSPACE" && pwd)          # absolute; --config needs it
CONFIG="$PW_WORKSPACE/.playwright/cli.config.json"
CONFIG_ARG=$(native_path "$CONFIG")                # what the CLI is handed
LAST_URL="$PW_WORKSPACE/.playwright/last-url"

# Written once. Absent config => the CLI rejects self-signed certs with
# net::ERR_CERT_AUTHORITY_INVALID and the loop stalls on the login page.
if [[ ! -f "$CONFIG" ]]; then
  if [[ "$PW_INSECURE_TLS" == "1" ]]; then
    printf '{ "browser": { "contextOptions": { "ignoreHTTPSErrors": true } } }\n' > "$CONFIG"
  else
    printf '{ "browser": { "contextOptions": {} } }\n' > "$CONFIG"
  fi
fi

# ------------------------------------------------------------------- launcher
# Order matters: a global binary if present, otherwise npx. Probed on exit code
# because npx prints an "update available" banner that reads like a failure.
LAUNCHER=()
if command -v playwright-cli >/dev/null 2>&1 && playwright-cli --version >/dev/null 2>&1; then
  LAUNCHER=(playwright-cli)
elif command -v npx >/dev/null 2>&1 && npx -y @playwright/cli --version >/dev/null 2>&1; then
  LAUNCHER=(npx -y @playwright/cli)
else
  die "Playwright CLI unavailable (no playwright-cli binary, and npx cannot run @playwright/cli).
      Install it (npm i -g @playwright/cli) or fall back to a browser MCP — see setup.md §0."
fi

pw() { (cd "$PW_WORKSPACE" && "${LAUNCHER[@]}" -s "$PW_SESSION" "$@"); }

# jq probed by running it, not by presence: a jq that errors would make
# session_open report "closed", and a bare `open` on a live session kills the
# browser and throws the APEX login away — the one thing this wrapper prevents.
if command -v jq >/dev/null 2>&1 && printf '{}' | jq -e . >/dev/null 2>&1; then HAVE_JQ=1; else HAVE_JQ=0; fi

# is the named session currently open?
session_open() {
  local json
  json=$( (cd "$PW_WORKSPACE" && "${LAUNCHER[@]}" list --json) 2>/dev/null ) || return 1
  if (( HAVE_JQ )); then
    [[ $(jq -r --arg n "$PW_SESSION" \
          '[.browsers[]? | select(.name == $n and .status == "open")] | length' <<<"$json") -gt 0 ]]
  else
    # same test without jq: strip whitespace, match the record's stable key order
    tr -d ' \n' <<<"$json" \
      | grep -qE "\"name\":\"$PW_SESSION\",\"workspace\":\"[^\"]*\",\"status\":\"open\""
  fi
}

open_session() {  # $1 = url (optional)
  if [[ -n "${1:-}" ]]; then
    pw open --config "$CONFIG_ARG" "$1"
    printf '%s\n' "$1" > "$LAST_URL"
  else
    pw open --config "$CONFIG_ARG"
  fi
}

CMD=$1; shift

case "$CMD" in
  open)
    # Idempotent: re-opening an open session would kill the browser and drop the
    # APEX login, so navigate the held session instead.
    if session_open; then
      if [[ -n "${1:-}" ]]; then
        printf '%s\n' "$1" > "$LAST_URL"
        pw goto "$@"
      else
        warn "session '$PW_SESSION' already open — nothing to do."
      fi
    else
      open_session "${1:-}"
    fi
    ;;

  list|close-all|kill-all|install|install-browser)
    # Session-independent; never trigger recovery.
    (cd "$PW_WORKSPACE" && "${LAUNCHER[@]}" "$CMD" "$@")
    ;;

  *)
    # Everything else needs a live session. Recover if the daemon died, but say so
    # loudly: the restored page has no APEX session token, so an assertion made
    # right after recovery would be measuring a logged-out page.
    if ! session_open; then
      local_url=""
      [[ -f "$LAST_URL" ]] && local_url=$(cat "$LAST_URL")
      open_session "$local_url" >/dev/null
      warn "session '$PW_SESSION' was not open; reopened${local_url:+ at $local_url}."
      warn "Page state (APEX session token, unsaved edits) was LOST — re-login and re-navigate"
      warn "with the fresh ?session=<token> before trusting any assertion below."
    fi
    if [[ "$CMD" == "goto" && -n "${1:-}" ]]; then
      printf '%s\n' "$1" > "$LAST_URL"
    fi
    pw "$CMD" "$@"
    ;;
esac
