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
APP_KEYS='appId|appAlias|apexlangDir|sqlclConnection|ignorePaths|testUser|runtimeUrl|uiGate|publicPages|lowPrivUser'

CFG_FLAT=""
CFG_P=(); CFG_T=(); CFG_V=()     # CFG_FLAT indexed: the path, type and value of each row
CFG_ERRORS=()
CFG_NOTES=()
APPS_ID=(); APPS_ALIAS=(); APPS_DIR=(); APPS_CONN=(); APPS_IGNORE=(); APPS_USER=(); APPS_URL=()
EVIDENCE_DIR=".apex-evidence"

# One reading of apex-sync.json, identical under jq and python: every node becomes
# "path<TAB>type<TAB>value" ($.appId, $.apps.0.ignorePaths.1, …). All semantics —
# types, defaults, validation — then live once, here in bash. Reading keys one at a
# time with each parser had let them disagree: python iterated a string-valued
# ignorePaths character by character, so nearly every file was excluded from the
# comparison and the check PASSed without comparing anything.
# Handed back in JF, not printed: one process (the parser), where $(json_flatten)
# piped through tr cost four — and under Git Bash each costs tens of milliseconds.
# Carriage returns are dropped: native tooling on Windows writes CRLF, and a trailing
# \r survives command substitution. Windows then hides the damage for filesystem
# paths — the OS trims trailing whitespace — while a plain string comparison keeps
# failing: a repo-only ignorePaths entry was reported as a Builder-side deletion and
# every LOCAL comparison FAILed.
json_flatten() {  # $1 = json file → JF; non-zero exit if it is not valid JSON
  if [[ "${JSON_TOOL[0]}" == "jq" ]]; then
    JF=$(jq -r 'def row($p; $v): [ (["$"] + ($p | map(tostring)) | join(".")), ($v | type),
             ($v | if type == "string" then . elif type == "array" or type == "object" then (length | tostring)
                   elif type == "null" then "" else tostring end) ] | @tsv;
           row([]; .), (paths as $p | row($p; getpath($p)))' "$1") || return
  else
    JF=$("${JSON_TOOL[@]}" -c '
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
sys.stdout.buffer.write(("\n".join(out) + "\n").encode("utf-8"))' "$1") || return
  fi
  JF=${JF//$'\r'/}
}

# The rows of CFG_FLAT, split once into CFG_P/CFG_T/CFG_V by word splitting — no read
# loop: bash reads a pipe one byte per system call. Every key is then looked up
# here in this shell; an awk per key, through $(...), had cost two processes each,
# dozens per app.
cfg_index() {
  local IFS=$'\n' row rest rows=() noglob=0
  CFG_P=(); CFG_T=(); CFG_V=()
  [[ $- == *f* ]] && noglob=1
  set -f
  # shellcheck disable=SC2206   # split on newlines on purpose, with globbing off
  rows=($CFG_FLAT)
  (( noglob )) || set +f
  for row in ${rows[@]+"${rows[@]}"}; do
    rest=${row#*$'\t'}
    CFG_P+=("${row%%$'\t'*}"); CFG_T+=("${rest%%$'\t'*}"); CFG_V+=("${rest#*$'\t'}")
  done
}
CT=""; CV=""
cfg_get() {  # $1 = JSON path → CT (its type, '' when absent) and CV (its value); always 0
  local i
  CT=""; CV=""
  for (( i = 0; i < ${#CFG_P[@]}; i++ )); do
    if [[ "${CFG_P[$i]}" == "$1" ]]; then CT=${CFG_T[$i]}; CV=${CFG_V[$i]}; return 0; fi
  done
  return 0
}
CK=()
cfg_keys() {  # $1 = JSON path → CK: the keys of its direct members, in file order
  local i k pre="$1."
  CK=()
  for (( i = 0; i < ${#CFG_P[@]}; i++ )); do
    [[ "${CFG_P[$i]}" == "$pre"* ]] || continue
    k=${CFG_P[$i]#"$pre"}
    [[ "$k" == *.* ]] || CK+=("$k")
  done
}
cfg_err()   { CFG_ERRORS+=("$*"); }

rel_path_ok() {  # relative, forward slashes, no '..' segment, no drive letter
  local p=$1
  [[ -n "$p" && "$p" != /* && "$p" != *\\* && "$p" != *:* && "/$p/" != */../* ]]
}

CANON=""
canon_rel() {  # a path rel_path_ok accepted → CANON: no './' or empty segments, no trailing '/'; '' = the root
  local p=$1 out="" seg
  while [[ -n "$p" ]]; do
    seg=${p%%/*}
    if [[ "$p" == */* ]]; then p=${p#*/}; else p=""; fi
    [[ -z "$seg" || "$seg" == . ]] || out+="${out:+/}$seg"
  done
  CANON=$out
}

# A string setting of the app at JSON path $1: its own value, else the top-level
# default, in CS ('' when absent). A global, not printed: called as $(...) the
# type error below was recorded in a subshell and lost — a non-string testUser
# then read as "not set" instead of as an error.
CS=""
cfg_string() {  # $1 = app path, $2 = key, $3 = label for messages
  local p
  CS=""
  for p in "$1.$2" "\$.$2"; do
    cfg_get "$p"
    [[ -z "$CT" ]] && continue
    if [[ "$CT" == string ]]; then CS=$CV; else cfg_err "$3: $2 must be a string (got a $CT)"; fi
    return 0
  done
}

cfg_page_list() {  # $1 = JSON path, $2 = label: absent, or an array of page numbers
  local i n
  cfg_get "$1"
  [[ -z "$CT" ]] && return 0
  if [[ "$CT" != array ]]; then cfg_err "$2: ${1##*.} must be an array of page numbers, e.g. [9999] (got a $CT)"; return 0; fi
  n=$CV
  for (( i = 0; i < n; i++ )); do
    cfg_get "$1.$i"
    [[ "$CT" == number && "$CV" =~ ^[0-9]{1,6}$ ]] || cfg_err "$2: ${1##*.}[$i] must be a page number"
  done
}

cfg_app() {  # $1 = JSON path of the app object; appends one app or records errors
  local at=$1 label="apex-sync.json" t id alias dir conn ign="" i n v url user
  [[ "$at" == "\$" ]] || label="apex-sync.json ${at#\$.}"
  cfg_get "$at.appId"; t=$CT; id=$CV
  case "$t" in
    number|string) [[ "$id" =~ $RE_APP_ID ]] || cfg_err "$label: appId must be a positive integer (got '$id')" ;;
    "")            cfg_err "$label: appId is missing" ;;
    *)             cfg_err "$label: appId must be a positive integer" ;;
  esac
  cfg_get "$at.appAlias"; t=$CT; alias=$CV
  if [[ -z "$t" ]]; then cfg_err "$label: appAlias is missing"
  elif [[ "$t" != string || ! "$alias" =~ $RE_APP_ALIAS ]]; then
    cfg_err "$label: appAlias must match $RE_APP_ALIAS (letters, digits, '_' and '-'; it names a git ref and a directory)"
  fi
  cfg_string "$at" apexlangDir "$label"; dir=$CS
  cfg_get "$at.apexlangDir"; [[ -n "$CT" ]] || cfg_get '$.apexlangDir'; t=$CT
  if [[ -z "$t" ]]; then cfg_err "$label: apexlangDir is missing"
  elif [[ "$t" != string ]]; then :      # cfg_string recorded it
  elif ! rel_path_ok "$dir"; then cfg_err "$label: apexlangDir must be a relative path with forward slashes and no '..' (got '$dir')"
  else canon_rel "$dir"; dir=$CANON; fi
  cfg_string "$at" sqlclConnection "$label"; conn=$CS
  cfg_get "$at.sqlclConnection"; [[ -n "$CT" ]] || cfg_get '$.sqlclConnection'; t=$CT
  if [[ -z "$t" ]]; then cfg_err "$label: sqlclConnection is missing"
  elif [[ "$t" != string ]]; then :      # cfg_string recorded it
  elif [[ ! "$conn" =~ $RE_CONNECTION ]]; then
    cfg_err "$label: sqlclConnection must be a saved connection NAME (sql -name <name>), never a connect string — no '/', '@', quotes or spaces"
  fi
  # ignorePaths: the app's own list replaces the top-level one (no merging).
  local ip="$at.ignorePaths"
  cfg_get "$ip"; [[ -n "$CT" ]] || { ip="\$.ignorePaths"; cfg_get "$ip"; }
  t=$CT
  if [[ -n "$t" && "$t" != array ]]; then
    cfg_err "$label: ignorePaths must be an array of paths, e.g. [\"apex-exports/\"] (got a $t)"
  elif [[ "$t" == array ]]; then
    n=$CV
    for (( i = 0; i < n; i++ )); do
      cfg_get "$ip.$i"; v=$CV
      if [[ "$CT" != string ]] || ! rel_path_ok "$v"; then
        cfg_err "$label: ignorePaths[$i] must be a relative path with forward slashes and no '..'"
      else
        ign+="$v"$'\n'
      fi
    done
  fi
  cfg_string "$at" runtimeUrl "$label"; url=$CS
  [[ "$url" != *session=* ]] || cfg_err "$label: runtimeUrl must not carry a session token (session=…): the file is committed"
  cfg_string "$at" testUser "$label"; user=$CS
  # uiGate, publicPages, lowPrivUser: read by apex-ux / apex-security and the orchestrator, not by
  # the guard; only their types are checked here, so a typo blocks instead of passing silently
  cfg_get "$at.uiGate"
  [[ -z "$CT" || "$CT" == boolean ]] || cfg_err "$label: uiGate must be true or false (got a $CT)"
  cfg_page_list "$at.publicPages" "$label"
  cfg_string "$at" lowPrivUser "$label"
  APPS_ID+=("$id"); APPS_ALIAS+=("$alias"); APPS_DIR+=("$dir"); APPS_CONN+=("$conn"); APPS_IGNORE+=("$ign")
  APPS_USER+=("$user"); APPS_URL+=("$url")
}

SR=""
app_src() { SR=${APPS_DIR[$1]:+${APPS_DIR[$1]}/}${APPS_ALIAS[$1]}; }   # $1 = app index → SR, its source dir (repo-relative)

# shellcheck disable=SC2034   # APP_I is read by the scripts that source this file
app_index() {  # $1 = alias → APP_I (exact match); 1 if there is no such app
  local i
  for (( i = 0; i < ${#APPS_ALIAS[@]}; i++ )); do
    [[ "${APPS_ALIAS[$i]}" == "$1" ]] && { APP_I=$i; return 0; }
  done
  return 1
}

# What no single entry shows: apps that would share a ref, a Builder app or files.
same_alias() {  # $1 $2 → 0 when equal but for case. Aliases are ASCII here (RE_APP_ALIAS held).
  local r=1 nc=0
  shopt -q nocasematch && nc=1
  shopt -s nocasematch
  [[ "$1" == "$2" ]] && r=0
  (( nc )) || shopt -u nocasematch
  return "$r"
}

cfg_cross_check() {
  local i j a b
  for (( i = 0; i < ${#APPS_ALIAS[@]}; i++ )); do
    app_src "$i"; a=$SR
    for (( j = i + 1; j < ${#APPS_ALIAS[@]}; j++ )); do
      app_src "$j"; b=$SR
      if same_alias "${APPS_ALIAS[$i]}" "${APPS_ALIAS[$j]}"; then
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
  json_flatten "$CFG" || { cfg_err "apex-sync.json is not valid JSON"; return 0; }
  CFG_FLAT=$JF; cfg_index
  cfg_get '$'; [[ "$CT" == object ]] || { cfg_err "apex-sync.json must hold a JSON object"; return 0; }
  cfg_get '$.apps'; t=$CT
  if [[ -z "$t" ]]; then
    cfg_app '$'
  elif [[ "$t" != array ]]; then
    cfg_err "apex-sync.json: apps must be an array of app objects (got a $t)"
  else
    cfg_get '$.appId'; k=$CT; cfg_get '$.appAlias'
    [[ -z "$k$CT" ]] \
      || cfg_err "apex-sync.json: a top-level appId/appAlias cannot be combined with apps[] — move that app into apps[]"
    cfg_get '$.apps'; n=$CV
    (( n > 0 )) || cfg_err "apex-sync.json: apps is empty"
    for (( i = 0; i < n; i++ )); do
      cfg_get "\$.apps.$i"
      if [[ "$CT" != object ]]; then cfg_err "apex-sync.json apps.$i must be an object"; continue; fi
      # Strict inside an app: a misspelled key there silently falls back to the
      # top-level default — checking the right app through the wrong connection.
      cfg_keys "\$.apps.$i"
      for k in ${CK[@]+"${CK[@]}"}; do
        [[ -z "$k" || "$k" =~ ^($APP_KEYS)$ ]] \
          || cfg_err "apex-sync.json apps.$i: unknown key '$k' (an app takes: ${APP_KEYS//|/, })"
      done
      cfg_app "\$.apps.$i"
    done
  fi
  if [[ "$t" == array ]]; then          # the top-level default under apps[]; one app's own is checked above
    cfg_get '$.uiGate'
    [[ -z "$CT" || "$CT" == boolean ]] || cfg_err "apex-sync.json: uiGate must be true or false (got a $CT)"
    cfg_page_list '$.publicPages' "apex-sync.json"
  fi
  cfg_get '$.evidenceDir'
  if [[ -n "$CT" ]]; then
    cfg_string '$' evidenceDir "apex-sync.json"; EVIDENCE_DIR=$CS
    cfg_get '$.evidenceDir'
    if [[ "$CT" != string ]]; then
      :                                  # the type error is already recorded
    elif rel_path_ok "$EVIDENCE_DIR" && canon_rel "$EVIDENCE_DIR" && [[ -n "$CANON" ]]; then
      EVIDENCE_DIR=$CANON
    else
      cfg_err "apex-sync.json: evidenceDir must be a directory below the repo root — relative, forward slashes, no '..'"
    fi
  fi
  cfg_keys '$'
  for k in ${CK[@]+"${CK[@]}"}; do
    [[ -z "$k" || "$k" =~ ^($APP_KEYS|evidenceDir|apps)$ ]] || CFG_NOTES+=("unknown key '$k' ignored (typo?)")
  done
  (( ${#CFG_ERRORS[@]} )) || cfg_cross_check
}
