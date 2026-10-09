# shellcheck shell=bash
# apex-sync-guard — apex-sync.json, read one way for every script that needs it.
# Sourced by apex-sync-check.sh and apex-sync-hook.sh, so the gate and the hook that
# enforces it cannot disagree on which apps exist, where their source lives, or what
# makes the file invalid. bash 3.2-safe (macOS): no mapfile, no ${x,,}.
#
# The caller provides CFG (the apex-sync.json path) and JSON_TOOL (jq, or a python
# that actually runs). cfg_load sets, one entry per app in file order:
#   APPS_ID APPS_ALIAS APPS_DIR (canonical: no './', no trailing '/', '' = repo root)
#   APPS_CONN APPS_IGNORE (newline-separated) APPS_USER APPS_URL
# plus EVIDENCE_DIR, CFG_ERRORS (every problem, reported together) and CFG_NOTES.
#
# Two shapes, never mixed:
#   one app    { "appId": 100, "appAlias": "hr", "apexlangDir": …, "sqlclConnection": … }
#   several    { "apexlangDir": …, "sqlclConnection": …, "apps": [ { "appId": 100, "appAlias": "hr" }, … ] }
# In the second, every top-level key except appId/appAlias is a default an app may
# override; ignorePaths is replaced, never merged.

# The rules every key must satisfy. The alias and connection-name patterns also
# live in apex-sentinel's pw.sh and in framework/schemas/common.schema.json.
RE_APP_ID='^[1-9][0-9]{0,9}$'
RE_APP_ALIAS='^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$'
RE_CONNECTION='^[^/@[:space:]\"'"'"']{1,128}$'   # a saved-connection NAME: never user/password@host
APP_KEYS='appId|appAlias|apexlangDir|sqlclConnection|ignorePaths|testUser|runtimeUrl'

CFG_FLAT=""
CFG_ERRORS=()
CFG_NOTES=()
APPS_ID=(); APPS_ALIAS=(); APPS_DIR=(); APPS_CONN=(); APPS_IGNORE=(); APPS_USER=(); APPS_URL=()
EVIDENCE_DIR=".apex-evidence"

# Every JSON read is stripped of carriage returns: native tooling on Windows writes
# CRLF, and a trailing \r survives command substitution. Windows then hides the
# damage for filesystem paths — the OS trims trailing whitespace — while a plain
# string comparison keeps failing: a repo-only ignorePaths entry was reported as a
# Builder-side deletion and every LOCAL comparison FAILed.
strip_cr() { tr -d '\r'; }

# One reading of apex-sync.json, identical under jq and python: every node becomes
# "path<TAB>type<TAB>value" ($.appId, $.apps.0.ignorePaths.1, …). All semantics —
# types, defaults, validation — then live once, here in bash. Reading keys one at a
# time with each parser had let them disagree: python iterated a string-valued
# ignorePaths character by character, so nearly every file was excluded from the
# comparison and the check PASSed without comparing anything.
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

cfg_type()  { awk -F'\t' -v p="$1" '$1 == p { print $2; exit }' <<<"$CFG_FLAT"; }
cfg_value() { awk -F'\t' -v p="$1" '$1 == p { print $3; exit }' <<<"$CFG_FLAT"; }
cfg_keys()  { awk -F'\t' -v pre="$1." 'index($1, pre) == 1 { k = substr($1, length(pre) + 1); if (k !~ /\./) print k }' <<<"$CFG_FLAT"; }
cfg_err()   { CFG_ERRORS+=("$*"); }
lower()     { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

rel_path_ok() {  # relative, forward slashes, no '..' segment, no drive letter
  local p=$1
  [[ -n "$p" && "$p" != /* && "$p" != *\\* && "$p" != *:* && "/$p/" != */../* ]]
}

canon_rel() {  # a path rel_path_ok accepted → no './' or empty segments, no trailing '/'; '' = the root
  local p=$1 out="" seg
  while [[ -n "$p" ]]; do
    seg=${p%%/*}
    if [[ "$p" == */* ]]; then p=${p#*/}; else p=""; fi
    [[ -z "$seg" || "$seg" == . ]] || out+="${out:+/}$seg"
  done
  printf '%s' "$out"
}

# A string setting of the app at JSON path $1: its own value, else the top-level
# default. Prints the value; a wrong type is an error, absence prints nothing.
cfg_string() {  # $1 = app path, $2 = key, $3 = label for messages
  local p t
  for p in "$1.$2" "\$.$2"; do
    t=$(cfg_type "$p")
    [[ -z "$t" ]] && continue
    if [[ "$t" == string ]]; then cfg_value "$p"; else cfg_err "$3: $2 must be a string"; fi
    return 0
  done
}

cfg_app() {  # $1 = JSON path of the app object; appends one app or records errors
  local at=$1 label="apex-sync.json" t id alias dir conn ign="" i n v url user
  [[ "$at" == "\$" ]] || label="apex-sync.json ${at#\$.}"
  t=$(cfg_type "$at.appId"); id=$(cfg_value "$at.appId")
  case "$t" in
    number|string) [[ "$id" =~ $RE_APP_ID ]] || cfg_err "$label: appId must be a positive integer (got '$id')" ;;
    "")            cfg_err "$label: appId is missing" ;;
    *)             cfg_err "$label: appId must be a positive integer" ;;
  esac
  t=$(cfg_type "$at.appAlias"); alias=$(cfg_value "$at.appAlias")
  if [[ -z "$t" ]]; then cfg_err "$label: appAlias is missing"
  elif [[ "$t" != string || ! "$alias" =~ $RE_APP_ALIAS ]]; then
    cfg_err "$label: appAlias must match $RE_APP_ALIAS (letters, digits, '_' and '-'; it names a git ref and a directory)"
  fi
  dir=$(cfg_string "$at" apexlangDir "$label")
  if [[ -z "$dir" ]]; then cfg_err "$label: apexlangDir is missing"
  elif ! rel_path_ok "$dir"; then cfg_err "$label: apexlangDir must be a relative path with forward slashes and no '..' (got '$dir')"
  else dir=$(canon_rel "$dir"); fi
  conn=$(cfg_string "$at" sqlclConnection "$label")
  if [[ -z "$conn" ]]; then cfg_err "$label: sqlclConnection is missing"
  elif [[ ! "$conn" =~ $RE_CONNECTION ]]; then
    cfg_err "$label: sqlclConnection must be a saved connection NAME (sql -name <name>), never a connect string — no '/', '@', quotes or spaces"
  fi
  # ignorePaths: the app's own list replaces the top-level one (no merging).
  local ip="$at.ignorePaths"
  [[ -n "$(cfg_type "$ip")" ]] || ip="\$.ignorePaths"
  t=$(cfg_type "$ip")
  if [[ -n "$t" && "$t" != array ]]; then
    cfg_err "$label: ignorePaths must be an array of paths, e.g. [\"apex-exports/\"] (got a $t)"
  elif [[ "$t" == array ]]; then
    n=$(cfg_value "$ip")
    for (( i = 0; i < n; i++ )); do
      v=$(cfg_value "$ip.$i")
      if [[ "$(cfg_type "$ip.$i")" != string ]] || ! rel_path_ok "$v"; then
        cfg_err "$label: ignorePaths[$i] must be a relative path with forward slashes and no '..'"
      else
        ign+="$v"$'\n'
      fi
    done
  fi
  url=$(cfg_string "$at" runtimeUrl "$label")
  [[ "$url" != *session=* ]] || cfg_err "$label: runtimeUrl must not carry a session token (session=…): the file is committed"
  user=$(cfg_string "$at" testUser "$label")
  APPS_ID+=("$id"); APPS_ALIAS+=("$alias"); APPS_DIR+=("$dir"); APPS_CONN+=("$conn"); APPS_IGNORE+=("$ign")
  APPS_USER+=("$user"); APPS_URL+=("$url")
}

app_src_rel() { printf '%s' "${APPS_DIR[$1]:+${APPS_DIR[$1]}/}${APPS_ALIAS[$1]}"; }   # $1 = app index

# shellcheck disable=SC2034   # APP_I is read by the scripts that source this file
app_index() {  # $1 = alias → APP_I (exact match); 1 if there is no such app
  local i
  for (( i = 0; i < ${#APPS_ALIAS[@]}; i++ )); do
    [[ "${APPS_ALIAS[$i]}" == "$1" ]] && { APP_I=$i; return 0; }
  done
  return 1
}

# What no single entry shows: apps that would share a ref, a Builder app or files.
cfg_cross_check() {
  local i j a b
  for (( i = 0; i < ${#APPS_ALIAS[@]}; i++ )); do
    a=$(app_src_rel "$i")
    for (( j = i + 1; j < ${#APPS_ALIAS[@]}; j++ )); do
      b=$(app_src_rel "$j")
      if [[ "$(lower "${APPS_ALIAS[$i]}")" == "$(lower "${APPS_ALIAS[$j]}")" ]]; then
        cfg_err "apex-sync.json: appAlias '${APPS_ALIAS[$i]}' and '${APPS_ALIAS[$j]}' collide — an alias names a git ref and a directory, which compare without case on Windows and macOS"
      fi
      if [[ "${APPS_ID[$i]}" == "${APPS_ID[$j]}" && "${APPS_CONN[$i]}" == "${APPS_CONN[$j]}" ]]; then
        cfg_err "apex-sync.json: '${APPS_ALIAS[$i]}' and '${APPS_ALIAS[$j]}' are the same Builder app (id ${APPS_ID[$i]} through '${APPS_CONN[$i]}')"
      fi
      if [[ "$a/" == "$b/"* || "$b/" == "$a/"* ]]; then
        cfg_err "apex-sync.json: the source dirs of '${APPS_ALIAS[$i]}' ($a) and '${APPS_ALIAS[$j]}' ($b) overlap — each comparison would take in the other app's files"
      fi
    done
    [[ "$EVIDENCE_DIR/" != "$a/"* ]] \
      || cfg_err "apex-sync.json: evidenceDir ($EVIDENCE_DIR) is inside the source dir of '${APPS_ALIAS[$i]}' — the evidence would be compared as app source"
  done
}

cfg_load() {
  local k i n t
  CFG_FLAT=$(json_flatten "$CFG") || { cfg_err "apex-sync.json is not valid JSON"; return 0; }
  [[ "$(cfg_type '$')" == object ]] || { cfg_err "apex-sync.json must hold a JSON object"; return 0; }
  t=$(cfg_type '$.apps')
  if [[ -z "$t" ]]; then
    cfg_app '$'
  elif [[ "$t" != array ]]; then
    cfg_err "apex-sync.json: apps must be an array of app objects (got a $t)"
  else
    [[ -z "$(cfg_type '$.appId')$(cfg_type '$.appAlias')" ]] \
      || cfg_err "apex-sync.json: a top-level appId/appAlias cannot be combined with apps[] — move that app into apps[]"
    n=$(cfg_value '$.apps')
    (( n > 0 )) || cfg_err "apex-sync.json: apps is empty"
    for (( i = 0; i < n; i++ )); do
      if [[ "$(cfg_type "\$.apps.$i")" != object ]]; then cfg_err "apex-sync.json apps.$i must be an object"; continue; fi
      # Strict inside an app: a misspelled key there silently falls back to the
      # top-level default — checking the right app through the wrong connection.
      while IFS= read -r k; do
        [[ -z "$k" || "$k" =~ ^($APP_KEYS)$ ]] \
          || cfg_err "apex-sync.json apps.$i: unknown key '$k' (an app takes: ${APP_KEYS//|/, })"
      done <<<"$(cfg_keys "\$.apps.$i")"
      cfg_app "\$.apps.$i"
    done
  fi
  if [[ -n "$(cfg_type '$.evidenceDir')" ]]; then
    EVIDENCE_DIR=$(cfg_string '$' evidenceDir "apex-sync.json")
    if rel_path_ok "$EVIDENCE_DIR" && [[ -n "$(canon_rel "$EVIDENCE_DIR")" ]]; then
      EVIDENCE_DIR=$(canon_rel "$EVIDENCE_DIR")
    else
      cfg_err "apex-sync.json: evidenceDir must be a directory below the repo root — relative, forward slashes, no '..'"
    fi
  fi
  while IFS= read -r k; do
    [[ -z "$k" || "$k" =~ ^($APP_KEYS|evidenceDir|apps)$ ]] || CFG_NOTES+=("unknown key '$k' ignored (typo?)")
  done <<<"$(cfg_keys '$')"
  (( ${#CFG_ERRORS[@]} )) || cfg_cross_check
}
