#!/usr/bin/env bash
# apex-sentinel — idempotent Playwright CLI entry point for runtime verification.
#
# Usage (from anywhere; every call is self-contained):
#   pw.sh [--app <alias>] <subcommand> …
#                           --app picks the app when apex-sync.json declares several
#                           (apps[]): its test user, URL, password and its own browser.
#                           Required then, except for list / close-all / kill-all, which
#                           cover every app, and install*.
#   pw.sh apps              the apps apex-sync.json declares: alias, testUser, runtimeUrl
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
#                     Default: ${TMPDIR:-/tmp}/apex-sentinel-<uid>/<repo>-<app>-<crc>,
#                     one per project and app, never inside it. Run pw.sh from inside
#                     the project repo, or every project shares one browser and login.
#   PW_SESSION        browser session name (default: apex)
#   PW_INSECURE_TLS   1 (default) accept self-signed certs; 0 to enforce validation
#   APEX_TEST_USER / APEX_TEST_PASSWORD (or …_<ALIAS>) / APEX_TEST_FILE   see `login` below
#
# The password is never passed as an argument to anything: it reaches the browser
# through a mode-600 snippet file that is deleted on exit, and the CLI is run with
# --raw so it does not echo the snippet back (plain `run-code` prints the code it ran).
#
# Exit codes: 0 OK · 2 refused / a precondition failed / the login could not be
# verified · 3 the browser had died and was reopened, so whatever the call printed
# describes a LOGGED-OUT page (re-login, re-navigate, repeat the step) · any other
# code is the Playwright CLI's own.
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

OPT_APP=""
while (( $# )); do      # pw.sh's own options come BEFORE the subcommand; after it, all is the CLI's
  case "$1" in
    --app)   [[ -n "${2:-}" ]] || die "--app needs an app alias"; OPT_APP=$2; shift 2 ;;
    --app=*) OPT_APP=${1#--app=}; [[ -n "$OPT_APP" ]] || die "--app needs an app alias"; shift ;;
    *) break ;;
  esac
done
[[ $# -gt 0 ]] || die "no subcommand — try: $(basename "$0") open <url>"
CMD=$1; shift

PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || PROJECT_ROOT=""
upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }      # bash 3.2 has no ${x^^}

# ----------------------------------------------------------------------- apps
# apex-sync.json as far as this skill needs it: which apps exist, and each one's
# testUser and runtimeUrl. Read the way apex-sync-guard reads it — the same flattening,
# the same defaults (a top-level key is every app's default), the same strictness
# inside apps[] — but on its own: apex-sentinel must work without that skill
# installed, on a file that may hold nothing but testUser/runtimeUrl.
# tests/integration/config-parity.sh holds both readers to the same fixtures.
RE_APP_ALIAS='^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$'
APP_KEYS='appId|appAlias|apexlangDir|sqlclConnection|ignorePaths|testUser|runtimeUrl'
JSON_TOOL=()            # probed by RUNNING it: the Microsoft Store python3 stub only looks present
if command -v jq >/dev/null 2>&1 && printf '{}' | jq -e . >/dev/null 2>&1; then
  JSON_TOOL=(jq)
else
  for _c in "python3" "python" "py -3"; do
    read -ra _cand <<<"$_c"
    command -v "${_cand[0]}" >/dev/null 2>&1 || continue
    if "${_cand[@]}" -c 'import json' >/dev/null 2>&1; then JSON_TOOL=("${_cand[@]}"); break; fi
  done
fi
strip_cr() { tr -d '\r'; }
# Same function as apex-sync-guard's lib/sync-config.sh: one row per JSON node,
# "path<TAB>type<TAB>value" ($.apps.0.testUser …), identical under jq and python.
json_flatten() {  # $1 = json file; non-zero exit if it is not valid JSON
  if [[ "${JSON_TOOL[0]}" == "jq" ]]; then
    jq -r 'def row($p; $v): [ (["$"] + ($p | map(tostring)) | join(".")), ($v | type),
             ($v | if type == "string" then . elif type == "array" or type == "object" then (length | tostring)
                   elif type == "null" then "" else tostring end) ] | @tsv;
           row([]; .), (paths as $p | row($p; getpath($p)))' "$1" | strip_cr
  else
    "${JSON_TOOL[@]}" -c '
import json, sys
def esc(s): return s.replace("\\", "\\\\").replace("\t", "\\t").replace("\n", "\\n").replace("\r", "\\r")
def kind(v):
    if v is None: return "null"
    if isinstance(v, bool): return "boolean"
    if isinstance(v, (int, float)): return "number"
    if isinstance(v, str): return "string"
    return "array" if isinstance(v, list) else "object"
out = []
def walk(path, v):
    k = kind(v)
    val = esc(v) if k == "string" else ("true" if v else "false") if k == "boolean" else "" if k == "null" \
        else str(len(v)) if k in ("array", "object") else json.dumps(v)
    out.append(esc(".".join(["$"] + [str(p) for p in path])) + "\t" + k + "\t" + val)
    for key, sub in (v.items() if k == "object" else enumerate(v) if k == "array" else []):
        walk(path + [key], sub)
walk([], json.load(open(sys.argv[1], encoding="utf-8")))
sys.stdout.buffer.write(("\n".join(out) + "\n").encode("utf-8"))' "$1" | strip_cr
  fi
}

raw_str() { sed -n 's/.*"'"$2"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1" | head -1 | strip_cr; }   # no parser at all
PA_ALIAS=(); PA_USER=(); PA_URL=(); PA_ERR=()
pa_load() {  # fills PA_* from the project's apex-sync.json (no file: no apps, no error)
  local cfg="$PROJECT_ROOT/apex-sync.json" flat t n i k a l
  [[ -n "$PROJECT_ROOT" && -f "$cfg" ]] || return 0
  ftype() { awk -F'\t' -v p="$1" '$1 == p { print $2; exit }' <<<"$flat"; }
  fval()  { awk -F'\t' -v p="$1" '$1 == p { print $3; exit }' <<<"$flat"; }
  fkeys() { awk -F'\t' -v pre="$1." 'index($1, pre) == 1 { k = substr($1, length(pre) + 1); if (k !~ /\./) print k }' <<<"$flat"; }
  fstr()  {  # $1 = app path, $2 = key → FS: the app's own string, else the top-level default
    local p                              # (a global: from a $(...) subshell the error was lost)
    FS=""
    for p in "$1.$2" "\$.$2"; do
      [[ -z "$(ftype "$p")" ]] && continue
      if [[ "$(ftype "$p")" == string ]]; then FS=$(fval "$p"); else PA_ERR+=("$2 must be a string"); fi
      return 0
    done
  }
  if (( ! ${#JSON_TOOL[@]} )); then
    # No parser: the one-app shape only, by its top-level keys — how this always read it.
    if grep -q '"apps"' "$cfg"; then PA_ERR+=("reading apps[] needs jq or a python3 that runs"); return 0; fi
    PA_ALIAS=("$(raw_str "$cfg" appAlias)"); PA_USER=("$(raw_str "$cfg" testUser)"); PA_URL=("$(raw_str "$cfg" runtimeUrl)")
  else
    flat=$(json_flatten "$cfg") || { PA_ERR+=("apex-sync.json is not valid JSON"); return 0; }
    [[ "$(ftype '$')" == object ]] || { PA_ERR+=("apex-sync.json must hold a JSON object"); return 0; }
    t=$(ftype '$.apps')
    if [[ -z "$t" ]]; then
      fstr '$' appAlias; PA_ALIAS=("$FS"); fstr '$' testUser; PA_USER=("$FS"); fstr '$' runtimeUrl; PA_URL=("$FS")
    elif [[ "$t" != array ]]; then
      PA_ERR+=("apps must be an array of app objects")
    else
      [[ -z "$(ftype '$.appId')$(ftype '$.appAlias')" ]] || PA_ERR+=("a top-level appId/appAlias cannot be combined with apps[]")
      n=$(fval '$.apps'); (( n > 0 )) || PA_ERR+=("apps is empty")
      for (( i = 0; i < n; i++ )); do
        [[ "$(ftype "\$.apps.$i")" == object ]] || { PA_ERR+=("apps.$i must be an object"); continue; }
        while IFS= read -r k; do
          [[ -z "$k" || "$k" =~ ^($APP_KEYS)$ ]] || PA_ERR+=("apps.$i: unknown key '$k'")
        done <<<"$(fkeys "\$.apps.$i")"
        [[ "$(ftype "\$.apps.$i.appAlias")" == string ]] || PA_ERR+=("apps.$i: appAlias is missing")
        PA_ALIAS+=("$(fval "\$.apps.$i.appAlias")")
        fstr "\$.apps.$i" testUser; PA_USER+=("$FS"); fstr "\$.apps.$i" runtimeUrl; PA_URL+=("$FS")
      done
    fi
  fi
  for (( i = 0; i < ${#PA_ALIAS[@]}; i++ )); do
    a=${PA_ALIAS[$i]}
    [[ -z "$a" && ${#PA_ALIAS[@]} -eq 1 ]] || [[ "$a" =~ $RE_APP_ALIAS ]] || PA_ERR+=("appAlias '$a' must match $RE_APP_ALIAS")
    [[ "${PA_URL[$i]}" != *session=* ]] || PA_ERR+=("the runtimeUrl of '${a:-the app}' carries a session token (session=…): the file is committed")
    for (( k = i + 1; k < ${#PA_ALIAS[@]}; k++ )); do
      l=${PA_ALIAS[$k]}
      [[ "$(upper "$a")" != "$(upper "$l")" ]] || PA_ERR+=("appAlias '$a' and '$l' collide (case does not count)")
    done
  done
  unset -f ftype fval fkeys fstr
  return 0
}
pa_load

if [[ "$CMD" == apps ]]; then           # the resolved list — what --app and login will use
  (( ! ${#PA_ERR[@]} )) || die "apex-sync.json is invalid:$(printf '\n  - %s' "${PA_ERR[@]}")"
  for (( i = 0; i < ${#PA_ALIAS[@]}; i++ )); do
    [[ -n "${PA_ALIAS[$i]}${PA_USER[$i]}${PA_URL[$i]}" ]] && printf '%s\t%s\t%s\n' "${PA_ALIAS[$i]}" "${PA_USER[$i]}" "${PA_URL[$i]}"
  done
  exit 0
fi

# Which app this call acts on. With several declared, a browser-holding command
# needs --app: guessing would log into one app with another's credentials.
APP_ALIAS=""; APP_I=0; ALL_APPS=0
case "$CMD" in
  install|install-browser) ;;
  *)
    (( ! ${#PA_ERR[@]} )) || die "apex-sync.json is invalid:$(printf '\n  - %s' "${PA_ERR[@]}")"
    if [[ -n "$OPT_APP" ]]; then
      APP_I=-1
      for (( i = 0; i < ${#PA_ALIAS[@]}; i++ )); do [[ "${PA_ALIAS[$i]}" == "$OPT_APP" ]] && APP_I=$i; done
      (( APP_I >= 0 )) || die "apex-sync.json declares no app '$OPT_APP'${PA_ALIAS[0]:+ — it declares: ${PA_ALIAS[*]}}"
      APP_ALIAS=$OPT_APP
    elif (( ${#PA_ALIAS[@]} > 1 )); then
      case "$CMD" in
        list|close-all|kill-all) ALL_APPS=1 ;;
        *) die "apex-sync.json declares ${#PA_ALIAS[@]} apps — name one: $(basename "$0") --app <$(IFS='|'; echo "${PA_ALIAS[*]}")> $CMD …" ;;
      esac
    else
      APP_ALIAS=${PA_ALIAS[0]:-}
    fi ;;
esac

# ------------------------------------------------------------------ workspace
# One stable directory per project for the whole verification loop, outside any
# repository so a run never leaves .playwright*/ droppings in the user's project.
# It used to be one shared /tmp/apex-sentinel-pw: two projects then drove the same
# browser, the same login and the same last-url.
: "${PW_SESSION:=apex}"
: "${PW_INSECURE_TLS:=1}"
case "$PW_INSECURE_TLS" in 0|1) ;; *) die "PW_INSECURE_TLS must be 0 or 1 (got '$PW_INSECURE_TLS')" ;; esac
slug() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-' | cut -c1-40; }
ws_base="${TMPDIR:-/tmp}/apex-sentinel-$(id -u)"
ws_for() {  # $1 = app alias ('' = none) → that app's default workspace
  local crc
  crc=$(printf '%s|%s' "$PROJECT_ROOT" "$1" | cksum | cut -d' ' -f1)
  printf '%s/%s-%s-%s' "$ws_base" "$(slug "$(basename "$PROJECT_ROOT")")" "$(slug "${1:-default}")" "$crc"
}
if [[ -n "${PW_WORKSPACE:-}" ]]; then
  WS_FROM=override
  ALL_APPS=0                          # one explicit workspace: there is nothing else to cover
else
  WS_FROM=default
  # Per user and private: the login snippet briefly holds the password in here.
  (umask 077; mkdir -p "$ws_base") || die "cannot create $ws_base"
  [[ -O "$ws_base" ]] || die "$ws_base is not owned by you — refusing to use it (another user could plant files there)"
  chmod 700 "$ws_base" 2>/dev/null || true
  if [[ -n "$PROJECT_ROOT" ]]; then
    PW_WORKSPACE=$(ws_for "$APP_ALIAS")
  else
    PW_WORKSPACE="$ws_base/default"
    warn "not inside a project repo — using the shared workspace $PW_WORKSPACE. Run pw.sh from inside the APEX project."
  fi
fi
mkdir -p "$PW_WORKSPACE/.playwright" || die "cannot create workspace $PW_WORKSPACE"
PW_WORKSPACE=$(cd "$PW_WORKSPACE" && pwd -P)      # absolute; --config needs it
# Never inside the project unless it is ignored there: .playwright/cli.config.json
# has been committed to a consuming repo exactly this way.
if [[ -n "$PROJECT_ROOT" && "$PW_WORKSPACE/" == "$PROJECT_ROOT/"* ]]; then
  if [[ "$WS_FROM" == default ]] || ! git -C "$PROJECT_ROOT" check-ignore -q "$PW_WORKSPACE/.playwright/cli.config.json"; then
    die "the Playwright workspace $PW_WORKSPACE is inside the project repo and not gitignored — point PW_WORKSPACE outside the repo, or add .playwright/ and .playwright-cli/ to its .gitignore first"
  fi
fi
CONFIG="$PW_WORKSPACE/.playwright/cli.config.json"
CONFIG_ARG=$(native_path "$CONFIG")                # what the CLI is handed
LAST_URL="$PW_WORKSPACE/.playwright/last-url"

# The URL to reopen after a crash, minus the APEX session token: the token is a
# credential, and without its cookie it only bounces to the login page anyway.
remember_url() {
  printf '%s\n' "$1" \
    | sed -E 's/([?&])session=[^&#]*/\1/; s/\?&/?/; s/&&/\&/; s/[?&](#|$)/\1/' > "$LAST_URL"
}

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
    remember_url "$1"
  else
    pw open --config "$CONFIG_ARG"
  fi
}

# The TLS setting lives in a config file the browser reads at launch. It used to be
# written once, so PW_INSECURE_TLS=0 set later silently changed nothing. It is now
# rewritten whenever it differs — and refused while a browser launched with the old
# setting is still open, since that browser would keep ignoring certificate errors.
if [[ "$PW_INSECURE_TLS" == 1 ]]; then
  WANT_CONFIG='{ "browser": { "contextOptions": { "ignoreHTTPSErrors": true } } }'
else
  WANT_CONFIG='{ "browser": { "contextOptions": {} } }'
fi
case "$CMD" in
  list|close-all|kill-all|install|install-browser) ;;   # never launch a browser
  *)
    if [[ "$(cat "$CONFIG" 2>/dev/null || true)" != "$WANT_CONFIG" ]]; then
      if [[ -f "$CONFIG" ]] && session_open; then
        die "PW_INSECURE_TLS changed, but session '$PW_SESSION' is open with the old setting — run pw.sh close-all first"
      fi
      { printf '%s\n' "$WANT_CONFIG" > "$CONFIG.tmp.$$" && mv -f "$CONFIG.tmp.$$" "$CONFIG"; } \
        || die "cannot write $CONFIG"
    fi ;;
esac

# --------------------------------------------------------- test-user credentials
# Only `login` reads these. A username is not a secret, so it sits with the rest of
# the project's config; the password never does, because apex-sync.json is committed.
#
#   user      $APEX_TEST_USER_<ALIAS>, else $APEX_TEST_USER, else the app's "testUser"
#             in apex-sync.json, else "user" in $APEX_TEST_FILE
#   password  the first of: $APEX_TEST_PASSWORD_<ALIAS>, APEX_TEST_PASSWORD_<ALIAS>= in
#             the repo root's .env, $APEX_TEST_PASSWORD, APEX_TEST_PASSWORD= in that .env,
#             "password" in $APEX_TEST_FILE (default ~/.apex-sentinel.json). The
#             per-app names (<ALIAS> upper-cased, other characters as _) let several
#             apps keep several test users; the plain ones serve a single app.
#             A project that keeps its env file elsewhere points $APEX_TEST_ENV at
#             it — this never goes looking, and never assumes a layout.
SENTINEL_PASSWORD=""      # declared early: redact() reads it on every warn/die

json_str() {  # $1 = file, $2 = key -> the string value on stdout, never on any argv
  if [[ "${JSON_TOOL[0]:-}" == jq ]]; then
    jq -r --arg k "$2" '.[$k] // empty' "$1" 2>/dev/null
  elif (( ${#JSON_TOOL[@]} )); then
    "${JSON_TOOL[@]}" -c 'import json, sys
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
  local ext=${APEX_TEST_FILE:-$HOME/.apex-sentinel.json} sfx="" v
  [[ -n "$APP_ALIAS" ]] && sfx="_$(upper "$APP_ALIAS" | tr -c 'A-Z0-9' '_')"

  v="APEX_TEST_USER$sfx"
  SENTINEL_USER=${!v:-${APEX_TEST_USER:-${PA_USER[$APP_I]:-}}}
  SENTINEL_APP_URL=${1:-${PA_URL[$APP_I]:-}}

  local envf=${APEX_TEST_ENV:-${PROJECT_ROOT:+$PROJECT_ROOT/.env}} k
  SENTINEL_PASSWORD=""
  for k in ${sfx:+"APEX_TEST_PASSWORD$sfx"} APEX_TEST_PASSWORD; do   # the app's own, then the shared one
    [[ -n "$SENTINEL_PASSWORD" ]] && break
    SENTINEL_PASSWORD=${!k:-}
    [[ -z "$SENTINEL_PASSWORD" && -n "$envf" && -f "$envf" ]] && SENTINEL_PASSWORD=$(env_str "$envf" "$k")
  done
  if [[ -z "$SENTINEL_PASSWORD" && -f "$ext" ]]; then
    SENTINEL_PASSWORD=$(json_str "$ext" password)
    [[ -z "$SENTINEL_USER" ]] && SENTINEL_USER=$(json_str "$ext" user)
  fi

  [[ -n "$SENTINEL_APP_URL" ]] || die "no runtime URL — pass it (pw.sh login <url>) or add \"runtimeUrl\" to apex-sync.json"
  [[ -n "$SENTINEL_USER" ]] || die "no test user — add \"testUser\" to apex-sync.json, or set \$APEX_TEST_USER"
  local which=""; [[ -n "$APP_ALIAS" ]] && which=" for app '$APP_ALIAS'"
  [[ -n "$SENTINEL_PASSWORD" ]] || die "no test password$which. Any one of:
        \$APEX_TEST_PASSWORD$sfx${sfx:+ (or \$APEX_TEST_PASSWORD, shared by every app)}
        APEX_TEST_PASSWORD$sfx= in the repo root's .env (gitignore it first)
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

case "$CMD" in
  open)
    # Idempotent: re-opening an open session would kill the browser and drop the
    # APEX login, so navigate the held session instead.
    if session_open; then
      if [[ -n "${1:-}" ]]; then
        remember_url "$1"
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

  const appUser = async () => String(await page.evaluate(
    () => (window.apex && apex.env && apex.env.APP_USER) || '').catch(() => '')).trim();
  // Every exit goes through verdict(). Leaving the login page is NOT a login: a public
  // landing page, an SSO redirect or a change-password interstitial all leave it too.
  // The only proof is APEX itself naming the test user as the session's APP_USER.
  const verdict = async () => {
    if (await onLoginPage())
      return 'LOGIN-FAILED|' + ((await errorText()) || 'still on the login page');
    const u = await appUser();
    if (!u) return 'LOGIN-UNVERIFIED|apex.env.APP_USER is not readable on ' + page.url();
    if (u.toLowerCase() === 'nobody') return 'LOGIN-UNVERIFIED|the page is anonymous (APP_USER=nobody)';
    if (u.toUpperCase() !== USER.toUpperCase()) return 'LOGIN-WRONG-USER|' + u;
    return 'LOGIN-OK|' + u + '|' + page.url();
  };

  // Check the page we are ALREADY holding before navigating anywhere. Going to the app
  // root without a token makes APEX open a fresh session and bounce to login — so a
  // `goto` first would destroy the very login this is supposed to preserve, and calling
  // login twice would silently cost you the session.
  const signedIn = async () => {
    if (!page.url().startsWith(APP.replace(/\/+$/, ''))) return false;   // some other app
    if (await onLoginPage()) return false;
    const u = await appUser();
    return !!u && u.toLowerCase() !== 'nobody';        // APEX calls an anonymous session 'nobody'
  };
  if (await signedIn()) return verdict();          // signed in — as whom? verdict() decides

  await page.goto(APP, { waitUntil: 'load' });
  await settle();
  if (!(await onLoginPage())) return verdict();    // a cookie session or a public page: verify it

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
  return verdict();
}
JS
      } > "$SNIP"
    ) || die "cannot write the login snippet to $SNIP"

    OUT=$(pw run-code --raw --filename "$(native_path "$SNIP")" 2>&1) || {
      rm -f "$SNIP"; die "the login snippet did not run: $OUT"
    }
    rm -f "$SNIP"
    # The verdict is the last non-empty line: anything the CLI printed before it (a
    # banner, a warning) must not decide whether a login happened.
    V=$(printf '%s\n' "$OUT" | tr -d '\r"' | grep -v '^[[:space:]]*$' | tail -1 \
        | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//') || V=""
    upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }      # bash 3.2 has no ${x^^}
    case "$V" in
      LOGIN-OK\|*)
        r=${V#LOGIN-OK|}; APPUSER=${r%%|*}; URL=${r#*|}
        # Second opinions on the snippet's verdict, because the failure they guard against
        # is the worst one this skill can produce: reporting a login that never happened.
        [[ "$(upper "$APPUSER")" == "$(upper "$SENTINEL_USER")" ]] \
          || die "the page says it is signed in as '$APPUSER', not '$SENTINEL_USER' — NOT verified."
        # The login page carries a ?session= token of its own, so a token is not evidence.
        case "$URL" in
          */login|*/login\?*|*/login#*)
            die "landed back on the login page as '$SENTINEL_USER' — NOT signed in: $URL
      Treat any assertion made from here as measuring a logged-out page." ;;
        esac ;;
      LOGIN-FAILED\|*)
        die "APEX rejected the login for user '$SENTINEL_USER': ${V#LOGIN-FAILED|}
      The runtime app login is its own scheme — not the ORDS/instance-admin and not the
      schema password. Failures are throttled with an escalating wait: pause ~12 s before
      retrying, or hammering only raises the timer." ;;
      LOGIN-WRONG-USER\|*)
        die "this browser is signed in as '${V#LOGIN-WRONG-USER|}', not '$SENTINEL_USER'.
      Run pw.sh close-all, then pw.sh login again." ;;
      LOGIN-UNVERIFIED\|*)
        die "cannot verify who is signed in: ${V#LOGIN-UNVERIFIED|}
      An SSO, social or custom scheme is not handled by pw.sh login (setup.md §2)." ;;
      *)
        die "the login snippet returned no verdict — treating it as NOT signed in. Last line: $(printf '%s' "$V" | cut -c1-200)" ;;
    esac

    remember_url "$URL"
    warn "workspace: $PW_WORKSPACE"
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
    # Session-independent; never trigger recovery. list and close-all act on one
    # workspace (the CLI scopes them to it), so without --app they visit every app's;
    # kill-all is global already.
    WSS=("$PW_WORKSPACE")
    if (( ALL_APPS )); then
      WSS=()
      for a in "${PA_ALIAS[@]}"; do w=$(ws_for "$a"); [[ -d "$w/.playwright" ]] && WSS+=("$w"); done
    fi
    rc=0
    for w in "${WSS[@]:-}"; do
      [[ -n "$w" ]] || continue
      (( ALL_APPS )) && [[ "$CMD" == list ]] && echo "== $w"
      if [[ "$CMD" != kill-all || "$w" == "${WSS[0]}" ]]; then
        (cd "$w" && "${LAUNCHER[@]}" "$CMD" "$@") || rc=$?
      fi
      # Snapshots are page dumps that can hold personal data: gone with the session.
      if [[ "$CMD" == close-all || "$CMD" == kill-all ]] && (( rc == 0 )); then
        rm -rf "$w/.playwright-cli"
      fi
    done
    exit "$rc"
    ;;

  *)
    # Everything else needs a live session. Recover if the daemon died — but the
    # restored page has no APEX session, so whatever this call prints measures a
    # logged-out page. A warning alone was easy to miss behind exit 0; the call now
    # exits 3, which the runtime gate reads as UNKNOWN for that step.
    recovered=0
    if ! session_open; then
      local_url=""
      [[ -f "$LAST_URL" ]] && local_url=$(cat "$LAST_URL")
      open_session "$local_url" >/dev/null
      warn "session '$PW_SESSION' was not open; reopened${local_url:+ at $local_url} (workspace $PW_WORKSPACE)."
      warn "Page state (APEX session token, unsaved edits) was LOST — re-login and re-navigate"
      warn "with the fresh ?session=<token>, then repeat this step (exit 3)."
      recovered=1
    fi
    if [[ "$CMD" == "goto" && -n "${1:-}" ]]; then
      remember_url "$1"
    fi
    rc=0; pw "$CMD" "$@" || rc=$?
    (( rc == 0 && recovered )) && exit 3
    exit "$rc"
    ;;
esac
