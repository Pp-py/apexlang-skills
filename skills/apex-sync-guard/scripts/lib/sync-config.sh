# shellcheck shell=bash
# apex-sync-guard — apex-sync.json, read one way for every script that needs it.
# Sourced by apex-sync-check.sh and apex-sync-hook.sh, so the gate and the hook that
# enforces it cannot disagree on which apps exist, where their source lives, or what
# makes the file invalid. bash 3.2-safe (macOS): no mapfile, no ${x,,}.
#
# The caller provides CFG (the apex-sync.json path) and JSON_TOOL (jq, or a python
# that actually runs). cfg_load sets, one entry per app — or, for an app with
# `environments`, one per environment — in file order:
#   APPS_ID APPS_ALIAS APPS_DIR (canonical: no './', no trailing '/', '' = repo root)
#   APPS_CONN APPS_IGNORE (newline-separated) APPS_USER APPS_URL
#   APPS_ENV (the environment's name, '' for an app without environments)
#   APPS_KEY (what state is keyed by: the alias, or <alias>.<env>)
#   APPS_PROT (1: a protected environment — the hook never lets an agent import or export there)
#   APPS_GROUP (which app object of the file the entry came from)
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
APP_KEYS='appId|appAlias|apexlangDir|sqlclConnection|ignorePaths|testUser|runtimeUrl|uiGate|securityGate|publicPages|lowPrivUser|environments'
# An environment of an app (R-1): its own Builder, runtime and test user. How many and
# what they are called is each project's choice; a name follows the alias pattern.
ENV_KEYS='sqlclConnection|appId|runtimeUrl|testUser|protected'

CFG_FLAT=""
CFG_P=(); CFG_T=(); CFG_V=()     # CFG_FLAT indexed: the path, type and value of each row
CFG_ERRORS=()
CFG_NOTES=()
APPS_ID=(); APPS_ALIAS=(); APPS_DIR=(); APPS_CONN=(); APPS_IGNORE=(); APPS_USER=(); APPS_URL=()
APPS_ENV=(); APPS_KEY=(); APPS_PROT=(); APPS_GROUP=(); CFG_GROUP=0
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
  local at=$1 label="apex-sync.json" t id alias dir conn ign="" i n v url user k
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
  local envs=0; cfg_get "$at.environments"; [[ -n "$CT" ]] && envs=1
  cfg_string "$at" sqlclConnection "$label"; conn=$CS
  cfg_get "$at.sqlclConnection"; [[ -n "$CT" ]] || cfg_get '$.sqlclConnection'; t=$CT
  if [[ -z "$t" ]]; then (( envs )) || cfg_err "$label: sqlclConnection is missing"
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
  # uiGate, securityGate, publicPages, lowPrivUser: read by apex-ux / apex-security and the orchestrator, not by
  # the guard; only their types are checked here, so a typo blocks instead of passing silently
  for k in uiGate securityGate; do
    cfg_get "$at.$k"
    [[ -z "$CT" || "$CT" == boolean ]] || cfg_err "$label: $k must be true or false (got a $CT)"
  done
  cfg_page_list "$at.publicPages" "$label"
  cfg_string "$at" lowPrivUser "$label"
  CFG_GROUP=$((CFG_GROUP + 1))
  if (( ! envs )); then
    cfg_push "$id" "$alias" "$dir" "$conn" "$ign" "$user" "$url" "" 0
    return 0
  fi
  # environments: one entry each, the same source dir, its own Builder and runtime.
  local ep="$at.environments" e eid econn eurl euser prot
  cfg_get "$ep"
  if [[ "$CT" != object ]]; then cfg_err "$label: environments must be an object of named environments, e.g. {\"dev\": {\"sqlclConnection\": \"dev_conn\"}}"; return 0; fi
  cfg_keys "$ep"
  (( ${#CK[@]} )) || { cfg_err "$label: environments is empty — name at least one, or drop the key"; return 0; }
  local names=("${CK[@]}")
  for e in "${names[@]}"; do
    [[ "$e" =~ $RE_APP_ALIAS ]] || { cfg_err "$label: environment name '$e' must match $RE_APP_ALIAS"; continue; }
    cfg_get "$ep.$e"; [[ "$CT" == object ]] || { cfg_err "$label: environments.$e must be an object"; continue; }
    cfg_keys "$ep.$e"
    for k in ${CK[@]+"${CK[@]}"}; do
      [[ "$k" =~ ^($ENV_KEYS)$ ]] || cfg_err "$label: environments.$e: unknown key '$k' (an environment takes: ${ENV_KEYS//|/, })"
    done
    cfg_get "$ep.$e.sqlclConnection"; econn=$CV
    if [[ "$CT" != string ]]; then cfg_err "$label: environments.$e: sqlclConnection is missing (each environment names its own Builder)"
    elif [[ ! "$econn" =~ $RE_CONNECTION ]]; then cfg_err "$label: environments.$e: sqlclConnection must be a saved connection NAME, never a connect string"; fi
    eid=$id; cfg_get "$ep.$e.appId"
    if [[ -n "$CT" ]]; then
      if [[ ( "$CT" == number || "$CT" == string ) && "$CV" =~ $RE_APP_ID ]]; then eid=$CV
      else cfg_err "$label: environments.$e: appId must be a positive integer"; fi
    fi
    eurl=$url; cfg_get "$ep.$e.runtimeUrl"
    if [[ -n "$CT" ]]; then
      if [[ "$CT" == string ]]; then eurl=$CV; else cfg_err "$label: environments.$e: runtimeUrl must be a string"; fi
      [[ "$eurl" != *session=* ]] || cfg_err "$label: environments.$e: runtimeUrl must not carry a session token (session=…): the file is committed"
    fi
    euser=$user; cfg_get "$ep.$e.testUser"
    if [[ -n "$CT" ]]; then if [[ "$CT" == string ]]; then euser=$CV; else cfg_err "$label: environments.$e: testUser must be a string"; fi; fi
    prot=0; cfg_get "$ep.$e.protected"
    case "$CT" in "") ;; boolean) [[ "$CV" == true ]] && prot=1 ;; *) cfg_err "$label: environments.$e: protected must be true or false" ;; esac
    cfg_push "$eid" "$alias" "$dir" "$econn" "$ign" "$euser" "$eurl" "$e" "$prot"
  done
}
cfg_push() {  # id alias dir conn ignore user url env protected — one entry
  APPS_ID+=("$1"); APPS_ALIAS+=("$2"); APPS_DIR+=("$3"); APPS_CONN+=("$4"); APPS_IGNORE+=("$5")
  APPS_USER+=("$6"); APPS_URL+=("$7"); APPS_ENV+=("$8"); APPS_PROT+=("$9"); APPS_GROUP+=("$CFG_GROUP")
  APPS_KEY+=("$2${8:+.$8}")
}

# What a check's marker is bound to (GAP-9): the app's source dir as the working tree holds
# it now — tracked and untracked files, ignored ones left out — as a git tree hash, through
# a copy of the index, so the real index is never touched. Computed by the check when it
# starts and when it writes the marker, and by the hook before it lets an import or an
# export run: a LOCAL that changed since the check no longer matches. ST="" when git
# cannot say; an empty or missing dir is git's empty tree.
ST=""
EMPTY_TREE=4b825dc642cb6eb9a060e54bf8d69288fbee4904
src_tree() {  # $1 = repo root, $2 = its git dir, $3 = the source dir (repo-relative) → ST
  local idx="$2/apex-sync-src.$$.idx" t=""
  ST=""
  rm -f "$idx"
  if [[ -f "$2/index" ]]; then cp -p "$2/index" "$idx" 2>/dev/null || true; fi
  if GIT_INDEX_FILE=$idx env -u GIT_ATTR_NOSYSTEM git -C "$1" add -A -- "$3" >/dev/null 2>&1 || [[ ! -e "$1/$3" ]]; then
    t=$(GIT_INDEX_FILE=$idx env -u GIT_ATTR_NOSYSTEM git -C "$1" write-tree 2>/dev/null) || t=""
  fi
  if [[ -n "$t" ]]; then ST=$(git -C "$1" rev-parse -q --verify "$t:$3" 2>/dev/null) || ST=$EMPTY_TREE; fi
  rm -f "$idx" "$idx.lock"
  [[ "$ST" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || ST=""
  return 0
}

SR=""
app_src() { SR=${APPS_DIR[$1]:+${APPS_DIR[$1]}/}${APPS_ALIAS[$1]}; }   # $1 = app index → SR, its source dir (repo-relative)

# shellcheck disable=SC2034   # APP_I is read by the scripts that source this file
app_index() {  # $1 = alias → APP_I (its first entry, exact match); 1 if there is no such app
  local i
  for (( i = 0; i < ${#APPS_ALIAS[@]}; i++ )); do
    [[ "${APPS_ALIAS[$i]}" == "$1" ]] && { APP_I=$i; return 0; }
  done
  return 1
}
# shellcheck disable=SC2034   # APP_I is read by the scripts that source this file
key_index() {  # $1 = a state key (alias, or alias.env) → APP_I; 1 if there is no such entry
  local i
  for (( i = 0; i < ${#APPS_KEY[@]}; i++ )); do
    [[ "${APPS_KEY[$i]}" == "$1" ]] && { APP_I=$i; return 0; }
  done
  return 1
}
ENVS=""
app_envs() {  # $1 = alias → ENVS: its environments' names, space-separated ('' = it has none)
  local i
  ENVS=""
  for (( i = 0; i < ${#APPS_ALIAS[@]}; i++ )); do
    [[ "${APPS_ALIAS[$i]}" == "$1" && -n "${APPS_ENV[$i]}" ]] && ENVS+="${ENVS:+ }${APPS_ENV[$i]}"
  done
  return 0
}
ALIASES=()
app_aliases() {  # → ALIASES: each app once, in file order
  local i a seen=" "
  ALIASES=()
  for (( i = 0; i < ${#APPS_ALIAS[@]}; i++ )); do
    a=${APPS_ALIAS[$i]}; [[ "$seen" == *" $a "* ]] && continue
    seen+="$a "; ALIASES+=("$a")
  done
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
      if [[ "${APPS_GROUP[$i]}" == "${APPS_GROUP[$j]}" ]]; then   # two environments of one app: one source
        [[ "${APPS_ID[$i]}|${APPS_CONN[$i]}" != "${APPS_ID[$j]}|${APPS_CONN[$j]}" ]] \
          || cfg_err "apex-sync.json: environments '${APPS_ENV[$i]}' and '${APPS_ENV[$j]}' of '${APPS_ALIAS[$i]}' are the same Builder app (id ${APPS_ID[$i]} through '${APPS_CONN[$i]}')"
        continue
      fi
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
    cfg_get '$.environments'
    [[ -z "$CT" ]] || cfg_err "apex-sync.json: environments belongs inside each app of apps[], not at the top level"
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
    for k in uiGate securityGate; do
      cfg_get "\$.$k"
      [[ -z "$CT" || "$CT" == boolean ]] || cfg_err "apex-sync.json: $k must be true or false (got a $CT)"
    done
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
