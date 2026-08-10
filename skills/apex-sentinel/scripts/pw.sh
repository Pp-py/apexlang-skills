#!/usr/bin/env bash
# apex-sentinel — idempotent Playwright CLI entry point for runtime verification.
#
# Usage (from anywhere; every call is self-contained):
#   pw.sh open <url>        open the browser session on <url>, or reuse+navigate if already open
#   pw.sh goto <url>        navigate the held session
#   pw.sh login [url]       log the test user into the APEX runtime app; prints the
#                           ?session=<token> on stdout (idempotent — a live login is left alone)
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
#   APEX_TEST_USER / APEX_TEST_PASSWORD / APEX_TEST_FILE   see `login` below
#
# The password is never passed as an argument to anything: it reaches the browser
# through a mode-600 snippet file that is deleted on exit, and the CLI is run with
# --raw so it does not echo the snippet back (plain `run-code` prints the code it ran).
#
# Runs under bash: Linux, macOS, and Windows via Git Bash or WSL (not PowerShell/cmd).
set -euo pipefail

# Anything printed may quote a message we built from resolved config, so scrub the
# one value that must never reach a terminal, a log, or a transcript.
redact() { local s=$*; [[ -n "${SENTINEL_PASSWORD:-}" ]] && s=${s//"$SENTINEL_PASSWORD"/'***'}; printf '%s' "$s"; }
die()  { echo "apex-sentinel: ERROR: $(redact "$*")" >&2; exit 2; }
warn() { echo "apex-sentinel: $(redact "$*")" >&2; }

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

# --------------------------------------------------------- test-user credentials
# Only `login` reads these. A username is not a secret, so it sits with the rest of
# the project's config; the password never does, because apex-sync.json is committed.
#
#   user      apex-sync.json "testUser", or $APEX_TEST_USER
#   password  $APEX_TEST_PASSWORD, else APEX_TEST_PASSWORD= in the repo root's .env,
#             else "password" in $APEX_TEST_FILE (default ~/.apex-sentinel.json).
#             A project that keeps its env file elsewhere points $APEX_TEST_ENV at
#             it — this never goes looking, and never assumes a layout.
SENTINEL_PASSWORD=""      # declared early: redact() reads it on every warn/die

# python3 is probed by RUNNING it, not by presence: the Microsoft Store stub satisfies
# `command -v` and then exits without doing anything.
json_str() {  # $1 = file, $2 = key -> the string value on stdout, never on any argv
  if (( HAVE_JQ )); then
    jq -r --arg k "$2" '.[$k] // empty' "$1" 2>/dev/null
  elif python3 -c 'import json' 2>/dev/null; then
    python3 -c 'import json, sys
print(json.load(open(sys.argv[1])).get(sys.argv[2]) or "")' "$1" "$2" 2>/dev/null
  else
    sed -n 's/.*"'"$2"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1" | head -1
  fi | tr -d '\r'
}

env_str() {  # $1 = .env file, $2 = key -> the value, with one layer of quotes removed
  sed -n -E "s/^[[:space:]]*(export[[:space:]]+)?$2[[:space:]]*=//p" "$1" 2>/dev/null \
    | head -1 | tr -d '\r' | sed -E -e 's/^"(.*)"$/\1/' -e "s/^'(.*)'\$/\1/"
}

resolve_credentials() {  # sets SENTINEL_USER, SENTINEL_PASSWORD, SENTINEL_APP_URL
  local root cfg ext
  root=$(git rev-parse --show-toplevel 2>/dev/null) || root=""
  cfg="$root/apex-sync.json"
  ext=${APEX_TEST_FILE:-$HOME/.apex-sentinel.json}

  SENTINEL_USER=${APEX_TEST_USER:-}
  SENTINEL_APP_URL=${1:-}
  if [[ -n "$root" && -f "$cfg" ]]; then
    [[ -z "$SENTINEL_USER"    ]] && SENTINEL_USER=$(json_str "$cfg" testUser)
    [[ -z "$SENTINEL_APP_URL" ]] && SENTINEL_APP_URL=$(json_str "$cfg" runtimeUrl)
  fi

  local envf=${APEX_TEST_ENV:-${root:+$root/.env}}
  SENTINEL_PASSWORD=${APEX_TEST_PASSWORD:-}
  [[ -z "$SENTINEL_PASSWORD" && -n "$envf" && -f "$envf" ]] \
    && SENTINEL_PASSWORD=$(env_str "$envf" APEX_TEST_PASSWORD)
  if [[ -z "$SENTINEL_PASSWORD" && -f "$ext" ]]; then
    SENTINEL_PASSWORD=$(json_str "$ext" password)
    [[ -z "$SENTINEL_USER" ]] && SENTINEL_USER=$(json_str "$ext" user)
  fi

  [[ -n "$SENTINEL_APP_URL" ]] || die "no runtime URL — pass it (pw.sh login <url>) or add \"runtimeUrl\" to apex-sync.json"
  [[ -n "$SENTINEL_USER" ]] || die "no test user — add \"testUser\" to apex-sync.json, or set \$APEX_TEST_USER"
  [[ -n "$SENTINEL_PASSWORD" ]] || die "no test password. Any one of:
        \$APEX_TEST_PASSWORD
        APEX_TEST_PASSWORD= in the repo root's .env (gitignore it first)
        \"password\" in $ext
      If this project keeps its env file somewhere else, point \$APEX_TEST_ENV at it —
      ask where it is rather than guessing. Use a dedicated low-privilege test user."
}

js_str() {  # $1 = raw value -> a JS double-quoted literal, using builtins ONLY so the
            # value never becomes the argv of a child process.
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\r'/}
  s=${s//$'\n'/\\n}
  printf '"%s"' "$s"
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

  login)
    # One round-trip for the whole navigate -> fill -> submit sequence, and idempotent:
    # the snippet returns early when the app is already authenticated, so re-running
    # this mid-loop costs a navigation and never throws a live APEX session away.
    resolve_credentials "${1:-}"
    session_open || open_session "" >/dev/null      # a browser must exist; the snippet navigates

    # The password is embedded in a snippet FILE rather than passed as an argument:
    #   * argv is world-readable through /proc/<pid>/cmdline, environ is not,
    #   * and `run-code` without --raw echoes the code it ran back to stdout,
    #     which would print the password into the transcript.
    SNIP="$PW_WORKSPACE/.playwright/login-$$.js"
    trap 'rm -f "$SNIP"' EXIT INT TERM
    (
      umask 077                                     # created 600, before a byte is written
      {
        printf 'async (page) => {\n'
        printf '  const APP = %s, USER = %s, PASS = %s;\n' \
               "$(js_str "$SENTINEL_APP_URL")" "$(js_str "$SENTINEL_USER")" "$(js_str "$SENTINEL_PASSWORD")"
        cat <<'JS'
  // The APEX login page RE-NAVIGATES itself on first load (it appends the browser
  // timezone, `?tz=...`). Filling before that lands throws the values away and the
  // submit never happens — while a naive "is the password field gone?" check reads
  // the reload as success. So: settle on a stable URL before touching anything, and
  // again after submitting.
  const settle = async (quiet = 1200, timeout = 25000) => {
    const end = Date.now() + timeout;
    let last = page.url(), since = Date.now();
    while (Date.now() < end) {
      await page.waitForTimeout(200);
      const now = page.url();
      if (now !== last) { last = now; since = Date.now(); continue; }
      if (Date.now() - since >= quiet) return;
    }
  };
  const onLoginPage = async () =>
    /\/login(\?|#|$)/i.test(page.url()) ||
    (await page.locator('input[type="password"]').count()) > 0;
  const errorText = async () => {
    for (const sel of ['#APEX_ERROR_MESSAGE', '#t_Alert_Notification', '.t-Login-message', '[role="alert"]']) {
      const t = await page.locator(sel).first().innerText().catch(() => '');
      if (t && t.trim()) return t.replace(/\s+/g, ' ').trim();
    }
    return '';
  };

  // Check the page we are ALREADY holding before navigating anywhere. Going to the app
  // root without a token makes APEX open a fresh session and bounce to login — so a
  // `goto` first would destroy the very login this is supposed to preserve, and calling
  // login twice would silently cost you the session.
  const signedIn = async () => {
    if (!page.url().startsWith(APP.replace(/\/+$/, ''))) return false;   // some other app
    if (await onLoginPage()) return false;
    const u = await page.evaluate(
      () => (window.apex && apex.env && apex.env.APP_USER) || '').catch(() => '');
    return !!u && u.toLowerCase() !== 'nobody';        // APEX calls an anonymous session 'nobody'
  };
  if (await signedIn()) return page.url();

  await page.goto(APP, { waitUntil: 'load' });
  await settle();
  if (!(await onLoginPage())) return page.url();

  // APEX names its login items P<n>_USERNAME / P<n>_PASSWORD, and <n> is NOT always 101
  // (a real app answered on P9999). Matching the id SUFFIX survives any page number, and
  // avoids keying on labels, which are translated — a Spanish app has no "Username" label.
  const named = page.locator('input[id$="_USERNAME"], input[name$="_USERNAME"]').first();
  const usr = (await named.count()) ? named : page.locator('input[type="text"]:visible').first();
  const pwd = page.locator('input[type="password"]').first();
  await usr.fill(USER);
  await pwd.fill(PASS);

  await pwd.press('Enter');
  await settle();

  if (await onLoginPage())
    return 'LOGIN-FAILED ' + ((await errorText()) || 'still on the login page');
  return page.url();
}
JS
      } > "$SNIP"
    ) || die "cannot write the login snippet to $SNIP"

    OUT=$(pw run-code --raw --filename "$(native_path "$SNIP")" 2>&1) || {
      rm -f "$SNIP"; die "the login snippet did not run: $OUT"
    }
    rm -f "$SNIP"
    URL=$(printf '%s' "$OUT" | tr -d '\r"' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

    case "$URL" in
      LOGIN-FAILED*)
        die "APEX rejected the login for user '$SENTINEL_USER': ${URL#LOGIN-FAILED }
      The runtime app login is its own scheme — not the ORDS/instance-admin and not the
      schema password. Failures are throttled with an escalating wait: pause ~12 s before
      retrying, or hammering only raises the timer." ;;
      # Second opinion on the snippet's verdict, because the failure it guards against is
      # the worst one this skill can produce: reporting a login that never happened. The
      # login page carries a ?session= token of its own, so a token is not evidence.
      */login|*/login\?*|*/login#*)
        die "landed back on the login page as '$SENTINEL_USER' — NOT signed in: $URL
      Treat any assertion made from here as measuring a logged-out page." ;;
    esac

    printf '%s\n' "$URL" > "$LAST_URL"
    TOKEN=${URL##*session=}; TOKEN=${TOKEN%%&*}
    if [[ -n "$TOKEN" && "$TOKEN" != "$URL" ]]; then
      warn "logged in as '$SENTINEL_USER' — session token on stdout."
      printf '%s\n' "$TOKEN"
    else
      warn "logged in as '$SENTINEL_USER', but the landing URL carries no ?session= token."
      warn "Printing the URL instead; deep links built without a token bounce to login."
      printf '%s\n' "$URL"
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
