#!/usr/bin/env bash
# apex-sentinel's Package gate (skills/apex-sentinel/scripts/pkg-check.py), offline: the real script
# against a stubbed SQLcl that records what it was sent (argv, stdin) and answers with canned rows —
#   * PASS needs every package found VALID, no ALL_ERRORS, every called procedure declared;
#   * an absent package or procedure, a compile error, a missing body → FAIL;
#   * INVALID with no visible error, a package the session cannot see, a synonym (a DB link too), a call in
#     a code block that names no package → UNKNOWN, never PASS;
#   * what the gate cannot look up in the right place (an owner, a remote database, an unknown invoke
#     type, a parsing schema the source changes) is unparsed or UNKNOWN, never PASS;
#   * nothing to look up (zero pairs), a file that is not .apx, no SQLcl, no connection, an app not
#     visible, an unsafe name → BLOCKED, and an unsafe name never reaches SQLcl;
#   * a crash or a half answer is UNKNOWN (never exit 1 = FAIL); secrets seeded in SQLcl's stderr, its
#     banner and an ALL_ERRORS message never reach the result;
#   * only SELECTs are sent, the connection is a NAME in argv;
#   * a protected environment is read; an app with environments needs --env.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
CHK="$REPO/skills/apex-sentinel/scripts/pkg-check.py"
FIX="$REPO/tests/integration/fixtures/pkg-check"
EX="$REPO/skills/apexlang-architecture/examples"
PY=$(command -v python3 || command -v python || true)
[[ -n "$PY" ]] || { echo "pkg-check: BLOCKED — python3 is required" >&2; exit 2; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/pkg-check-XXXXXX")
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/proj"
cat > "$WORK/bin/sql" <<'STUB'
#!/usr/bin/env bash
# stands in for SQLcl: the connection NAME arrives in argv, the statements on stdin
printf '%s\n' "$*" > "$SQL_ARGV"
cat > "$SQL_IN"
[[ -z "${FAKE_SLEEP:-}" ]] || exec sleep "$FAKE_SLEEP"
[[ ! -s "$FAKE_ROWS" ]] || cat "$FAKE_ROWS"
[[ -z "${FAKE_STDERR:-}" ]] || printf '%s\n' "$FAKE_STDERR" >&2
exit "${FAKE_RC:-0}"
STUB
chmod +x "$WORK/bin/sql"
# the stub is found the way the real SQLcl is: through PATH (no path in an environment variable: Git Bash converts those unpredictably)
export PATH="$WORK/bin:$PATH" SQL_ARGV="$WORK/sql.argv" SQL_IN="$WORK/sql.in" FAKE_ROWS="$WORK/rows"

cd "$WORK/proj"; git init -q
config() { printf '%s\n' "$1" > apex-sync.json; }
config '{ "appId": 100, "appAlias": "hr", "apexlangDir": "src", "sqlclConnection": "dev_hr" }'
cp "$FIX"/*.apx "$FIX"/*.sql .
cp -r "$EX" examples

pass=0; fail=0
ok()  { echo "ok   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1"; fail=$((fail + 1)); sed 's/^/       | /' "$WORK/err.txt" | tail -6; }
rows() { printf '%s\n' "$@" > "$FAKE_ROWS"; }
run() {  # $1 = label, $2 = expected exit, rest = pkg-check.py args; stdout → out.json
  local label=$1 want=$2 rc=0; shift 2
  rm -f "$SQL_IN" "$SQL_ARGV"
  "$PY" "$CHK" "$@" > "$WORK/out.json" 2> "$WORK/err.txt" || rc=$?
  if [[ $rc -eq $want ]]; then ok "$label (exit $rc)"; else bad "$label: exit $rc, expected $want"; fi
}
q() {  # $1 = label, $2 = python assertion on d (the result), c (criteria by id → status), sql (what SQLcl was sent) and raw
  if "$PY" -c "import json,sys,os
d = json.load(open(sys.argv[1])); c = {x['id']: x['status'] for x in d['criteria']}
sql = open(sys.argv[2]).read() if os.path.isfile(sys.argv[2]) else ''
raw = open(sys.argv[1]).read()
assert $2, (d['status'], d['reasons'], c)" "$WORK/out.json" "$SQL_IN" 2> "$WORK/err.txt"; then ok "$1"; else bad "$1"; fi
}
sent() { [[ -s "$SQL_IN" ]]; }                              # SQLcl was reached
not_sent() { if ! sent; then ok "SQLcl was not reached: $1"; else bad "SQLcl was reached: $1"; fi; }
OWN='pkgchk|ctx|HR|HR'
FOUND=('pkgchk|obj|PKG_EMPLOYEES|PACKAGE|VALID' 'pkgchk|obj|PKG_EMPLOYEES|PACKAGE BODY|VALID'
       'pkgchk|obj|PKG_SECTORS|PACKAGE|VALID' 'pkgchk|obj|PKG_SECTORS|PACKAGE BODY|VALID'
       'pkgchk|proc|PKG_EMPLOYEES|CREATE_ROW' 'pkgchk|proc|PKG_EMPLOYEES|UPDATE_ROW' 'pkgchk|proc|PKG_SECTORS|SAVE_ROW')
PKGA=('pkgchk|obj|PKG_A|PACKAGE|VALID' 'pkgchk|obj|PKG_A|PACKAGE BODY|VALID' 'pkgchk|proc|PKG_A|DO_IT')

rows "$OWN" "${FOUND[@]}" 'pkgchk|end'
run "every package VALID, every procedure declared → PASS" 0 --app hr --task T-1 calls.apx
q "PASS: the three criteria PASS, the database and the app are named" "d['status'] == 'PASS' and set(c.values()) == {'PASS'} and d['database'] == {'owner': 'HR', 'sessionUser': 'HR'} and d['app'] == {'appAlias': 'hr', 'appId': 100} and d['context']['target']['connectionName'] == 'dev_hr'"
q "PASS: standalone procedures (untyped, and type plsqlProcedureOrFunction) are advised, not looked up, and do not make the run UNKNOWN" "[a['id'] for a in d['advisories']] == ['PKG-STANDALONE'] * 2 and 'LEGACY_PROC' not in sql.upper() and 'LEGACY_TYPED' not in sql.upper()"
q "PASS: the executeCode call is looked up, Oracle's own package and a collection method are not" "'PKG_SECTORS' in sql and 'APEX_ERROR' not in sql and 'L_TAB' not in sql.upper()"
q "PASS: the query evidence ran and says how many rows" "len(d['evidence']) == 5 and all(e['kind'] == 'sql' and e['exitCode'] == 0 for e in d['evidence'])"
if [[ -f .apex-evidence/T-1/package-hr.json ]]; then ok "--task writes package-<alias>.json"; else bad "--task wrote no package-hr.json"; fi
if [[ "$(cat "$SQL_ARGV")" == "-S -name dev_hr" ]]; then ok "SQLcl got the saved connection's NAME and nothing else in argv"; else bad "argv was: $(cat "$SQL_ARGV")"; fi
if ! grep -viE '^(select |set |whenever |exit$)' "$SQL_IN" | grep -q .; then ok "only SELECTs (and SQLcl settings) were sent: no DDL, no DML, no compile"
else bad "something other than a SELECT was sent"; grep -viE '^(select |set |whenever |exit$)' "$SQL_IN" | head -3; fi
if ! grep -qi 'db_link is null' "$SQL_IN"; then ok "the synonym query does not hide the synonyms that go through a DB link"; else bad "the synonym query filters db_link"; fi

# seeds are assembled from pieces: written whole, they would be findings of this repo's own secrets scan
SEED_CONN='jdbc:oracle:thin:u''/p@dbhost'
SEED_PW='pass''word=hunter2'
SEED_ERR='hr''/secret@dbhost'
# a secret that SQLcl or the database says travels nowhere: stderr and the banner are not copied
rows "$OWN" "Connected to ${SEED_CONN}:1521/XEPDB1 ${SEED_PW}" "${FOUND[@]}" 'pkgchk|end'
FAKE_STDERR="SP2-0640: Not connected: ${SEED_CONN} ${SEED_PW}" run "secrets seeded in SQLcl's banner and stderr → PASS" 0 --app hr calls.apx
if ! grep -qE 'hunter2|u/p@|dbhost' "$WORK/out.json" "$WORK/err.txt" "$SQL_ARGV" "$SQL_IN"; then ok "no secret and no connect string in the result, the script's stderr, argv or statements"
else bad "a seeded secret or connect string leaked"; fi

rows "$OWN" "${FOUND[@]}" 'pkgchk|end'
run "everything found, but a file was not read → UNKNOWN, never PASS" 3 --app hr calls.apx unparsed.apx
q "UNKNOWN: unparsed is named, the criteria that ran still PASS" "d['unparsed'][0]['path'] == 'unparsed.apx' and 'a file was not read' in d['reasons'][0]['message'] and set(c.values()) == {'PASS'}"
rows "$OWN" "${FOUND[@]:0:4}" 'pkgchk|proc|PKG_EMPLOYEES|CREATE_ROW' 'pkgchk|proc|PKG_SECTORS|SAVE_ROW' 'pkgchk|end'
run "a called procedure the specification does not declare → FAIL" 1 --app hr calls.apx
q "FAIL: PKG-PROC-EXISTS, naming the procedure, the file and the line" "c['PKG-PROC-EXISTS'] == 'FAIL' and c['PKG-EXISTS'] == 'PASS' and any(f.get('procedure') == 'UPDATE_ROW' and f['path'] == 'calls.apx' and f['line'] > 0 for x in d['criteria'] for f in x['findings'])"

rows "$OWN" "${FOUND[@]:2}" 'pkgchk|end'
run "a package absent from its owner's own schema → FAIL" 1 --app hr calls.apx
q "FAIL: PKG-EXISTS on PKG_EMPLOYEES" "c['PKG-EXISTS'] == 'FAIL' and d['criteria'][0]['findings'][0]['package'] == 'PKG_EMPLOYEES'"
rows 'pkgchk|ctx|DEVELOPER|HR' "${FOUND[@]:2}" 'pkgchk|end'
run "the same, seen by another user (absent or not granted) → UNKNOWN, never FAIL" 3 --app hr calls.apx
q "UNKNOWN: not visible to the session's user" "c['PKG-EXISTS'] == 'UNKNOWN' and 'not visible to DEVELOPER' in d['criteria'][0]['findings'][0]['detail']"
rows "$OWN" "${FOUND[@]:2}" 'pkgchk|syn|PKG_EMPLOYEES|SHARED.PKG_EMPLOYEES' 'pkgchk|end'
run "a package reached only through a synonym → UNKNOWN (not followed)" 3 --app hr calls.apx
q "UNKNOWN: the synonym's target is named" "'SHARED.PKG_EMPLOYEES' in d['criteria'][0]['findings'][0]['detail']"
rows "$OWN" "${FOUND[@]:2}" 'pkgchk|syn|PKG_EMPLOYEES|SHARED.PKG_EMPLOYEES@REMOTE_LINK' 'pkgchk|end'
run "the owner's package is absent but a synonym goes through a DB link → UNKNOWN, never FAIL" 3 --app hr calls.apx
q "UNKNOWN: the link is named" "c['PKG-EXISTS'] == 'UNKNOWN' and '@REMOTE_LINK' in d['criteria'][0]['findings'][0]['detail']"

rows "$OWN" "${FOUND[@]}" 'pkgchk|err|PKG_SECTORS|PACKAGE BODY|41:7|PLS-00201: identifier '"'"'HR_SECTORZ'"'"' must be declared' 'pkgchk|end'
run "ALL_ERRORS holds an error → FAIL" 1 --app hr calls.apx
q "FAIL: PKG-COMPILED carries the error's line, position and text" "c['PKG-COMPILED'] == 'FAIL' and 'PLS-00201' in d['criteria'][1]['findings'][0]['detail'] and '41:7' in d['criteria'][1]['findings'][0]['detail']"
rows "$OWN" "${FOUND[@]}" "pkgchk|err|PKG_SECTORS|PACKAGE BODY|9:1|PLS-00201: identifier x, ${SEED_PW}-not-real, ${SEED_ERR}" 'pkgchk|end'
run "database text is redacted before it lands in a result" 1 --app hr calls.apx
if ! grep -qE 'hunter2|secret@' "$WORK/out.json"; then ok "an ALL_ERRORS message carrying a password or a connect string comes back <redacted>"; else bad "a secret from the database reached the result"; fi
rows "$OWN" "${FOUND[@]}" 'pkgchk|err|PKG_SECTORS|PACKAGE BODY|12:5|PLS-00103: Encountered the symbol "'"'"'s3cr3t-token'"'"'" when expecting one of the following' 'pkgchk|end'
run "ALL_ERRORS quotes a literal of the code (PLS-00103) → FAIL" 1 --app hr calls.apx
q "FAIL: the quoted symbol is not in the result; the code and the position are" "'s3cr3t-token' not in raw and 'PLS-00103' in d['criteria'][1]['findings'][0]['detail'] and '12:5' in d['criteria'][1]['findings'][0]['detail']"
rows "$OWN" 'pkgchk|obj|PKG_EMPLOYEES|PACKAGE|VALID' 'pkgchk|obj|PKG_EMPLOYEES|PACKAGE BODY|INVALID' "${FOUND[@]:2}" 'pkgchk|end'
run "INVALID with no error to read → UNKNOWN, never PASS" 3 --app hr calls.apx
q "UNKNOWN: PKG-COMPILED, not recompiled" "c['PKG-COMPILED'] == 'UNKNOWN' and 'not recompiled' in d['criteria'][1]['findings'][0]['detail']"
rows "$OWN" 'pkgchk|obj|PKG_EMPLOYEES|PACKAGE|VALID' 'pkgchk|proc|PKG_EMPLOYEES|CREATE_ROW' 'pkgchk|proc|PKG_EMPLOYEES|UPDATE_ROW' 'pkgchk|obj|PKG_SECTORS|PACKAGE|VALID' 'pkgchk|obj|PKG_SECTORS|PACKAGE BODY|VALID' 'pkgchk|proc|PKG_SECTORS|SAVE_ROW' 'pkgchk|end'
run "a specification with subprograms and no body → FAIL" 1 --app hr calls.apx

# what invokeApi can say besides package + procedure (the inventory's invoke.type, owner, source.location; a workflow activity)
rows "$OWN" "${PKGA[@]}" 'pkgchk|end'
run "invoke.owner names another schema → not looked up, UNKNOWN, SQLcl not reached" 3 --app hr owner.apx
q "unparsed says the owner and the line" "d['reasons'][0]['code'] == 'UNPARSED' and 'owner' in d['unparsed'][0]['detail'] and 'line ' in d['unparsed'][0]['detail']"
not_sent "an owner other than the parsing schema"
run "the process runs on a remote database (source.location) → UNKNOWN, SQLcl not reached" 3 --app hr remote.apx
q "unparsed says the remote database" "d['reasons'][0]['code'] == 'UNPARSED' and 'remote' in d['unparsed'][0]['detail']"
not_sent "a remote database"
run "an invoke.type this gate does not know → UNKNOWN, SQLcl not reached" 3 --app hr unknown-type.apx
not_sent "an unknown invoke.type"
run "a REST Source operation next to a valid package call → PASS (no PL/SQL in it)" 0 --app hr rest.apx
q "the REST Source is skipped, the package is looked up" "'PKG_A' in sql and 'MY_REST' not in sql.upper() and not d['unparsed']"
rows "$OWN" "${PKGA[@]}" 'pkgchk|end'
run "a workflow activity names a package that is absent → FAIL" 1 --app hr activity.apx
q "FAIL: PKG-EXISTS on the activity's package, with file and line" "c['PKG-EXISTS'] == 'FAIL' and any(f['package'] == 'PKG_MISSING' and f['path'] == 'activity.apx' and f['line'] > 0 for f in d['criteria'][0]['findings'])"
rows "$OWN" "${PKGA[@]}" 'pkgchk|end'
run "the source declares a parsing schema other than the database's → UNKNOWN" 3 --app hr parsing-schema.apx
q "PARSING_SCHEMA names both" "d['reasons'][0]['code'] == 'PARSING_SCHEMA' and 'HR2' in d['reasons'][0]['message'] and 'HR' in d['reasons'][0]['message']"
rows 'pkgchk|ctx|HR2|HR2' "${PKGA[@]}" 'pkgchk|end'
run "the source declares the parsing schema the database has → PASS" 0 --app hr parsing-schema.apx

# calls inside code blocks: a name that is no package of the schema decides nothing
rows "$OWN" 'pkgchk|end'
run "a code-block call to a package that is not there (a typo) → UNKNOWN, never PASS or FAIL" 3 --app hr code-unresolved.apx
q "UNKNOWN: PKG-EXISTS names the package, file and line" "c['PKG-EXISTS'] == 'UNKNOWN' and d['criteria'][0]['findings'][0]['package'] == 'PKG_SECTRS' and d['criteria'][0]['findings'][0]['line'] > 0 and not d['advisories']"
rows "$OWN" "${PKGA[@]}" 'pkgchk|end'
run "a method of a variable the block declares is not a package call → PASS" 0 --app hr code-local.apx
q "the declared variable's name was not looked up, the package was" "\"'L_OBJ'\" not in sql.upper() and \"'PKG_A'\" in sql"

# nothing to look up, no way to look it up
run "an .apx with no call at all → BLOCKED (zero pairs), SQLcl not reached" 2 --app hr no-calls.apx
q "NO_PAIRS" "d['reasons'][0]['code'] == 'NO_PAIRS'"
not_sent "no pair to look up"
run "only a standalone procedure → BLOCKED (nothing checkable), SQLcl not reached" 2 --app hr standalone-only.apx
not_sent "nothing checkable"
run "a SQL file is named → BLOCKED (the gate reads .apx), SQLcl not reached" 2 --app hr calls.apx sql-source.sql
q "NOT_APX, and the file is named" "d['reasons'][0]['code'] == 'NOT_APX' and 'sql-source.sql' in d['reasons'][0]['message']"
not_sent "a .sql file"
run "an unsafe name in the .apx → BLOCKED before any query" 2 --app hr evil.apx
q "BAD_IDENTIFIER, and the name itself is not echoed" "d['reasons'][0]['code'] == 'BAD_IDENTIFIER' and 'drop' not in raw"
not_sent "an unsafe name"
{ echo 'page 60 ('; echo '    name: Many'; for i in $(seq 1 501); do
    printf '    process p%s (\n        name: P%s\n        type: invokeApi\n        invoke {\n            package: pkg_n%s\n            procedureOrFunction: go\n        }\n    )\n' "$i" "$i" "$i"; done; echo ')'; } > toomany.apx
run "more packages than one query can name → BLOCKED, SQLcl not reached" 2 --app hr toomany.apx
q "TOO_MANY" "d['reasons'][0]['code'] == 'TOO_MANY'"
not_sent "501 packages"
run "an unparsed .apx and nothing else → UNKNOWN" 3 --app hr unparsed.apx
run "no file given → BLOCKED" 2 --app hr
run "a missing file → BLOCKED" 2 --app hr nope.apx
rows "$OWN" "${FOUND[@]}" 'pkgchk|end'
SQLCL_BIN=pkg-check-no-such-sqlcl run "no SQLcl → BLOCKED (NO_SQLCL)" 2 --app hr calls.apx
q "NO_SQLCL" "d['reasons'][0]['code'] == 'NO_SQLCL'"
config '{ "appId": 100, "appAlias": "hr", "apexlangDir": "src" }'
run "no sqlclConnection → BLOCKED, SQLcl not reached" 2 --app hr calls.apx
not_sent "no connection"
config '{ "appAlias": "hr", "apexlangDir": "src", "sqlclConnection": "dev_hr" }'
run "no appId → BLOCKED" 2 --app hr calls.apx
config '{ "appId": 100, "appAlias": "hr", "apexlangDir": "src", "sqlclConnection": "-S" }'
run "a connection name that reads as an option → BLOCKED" 2 --app hr calls.apx
config '{ "appId": 100, "appAlias": "hr", "apexlangDir": "src", "sqlclConnection": "dev_hr" }'

# the real SQLcl pads every line to the width of its widest column and may print CRLF, a banner or an echo:
# padding is not content (found live on a real SQLcl 26.1: the closing tag arrived as "pkgchk|end" + spaces)
PAD="$(printf '%*s' 120 '')"
rows "$OWN${PAD}" "${FOUND[@]/%/${PAD}}" "pkgchk|end${PAD}"
run "rows padded with trailing spaces, as the real SQLcl prints them → PASS" 0 --app hr calls.apx
q "padded: the owner and every package read as in the unpadded run" "d['status'] == 'PASS' and d['database'] == {'owner': 'HR', 'sessionUser': 'HR'} and set(c.values()) == {'PASS'}"
printf '%s\r\n' 'Connected.' "$OWN${PAD}" "${FOUND[@]}" "pkgchk|end${PAD}" 'Disconnected from Oracle Database' > "$FAKE_ROWS"
run "CRLF, a banner before and a trailer after the rows → PASS" 0 --app hr calls.apx
rows "$OWN${PAD}" "${FOUND[@]}" "pkgchk|err|PKG_SECTORS|PACKAGE BODY|41:7|PLS-00201: identifier 'X' must be declared${PAD}" "pkgchk|end${PAD}"
run "padding after an error text is not part of it → FAIL" 1 --app hr calls.apx
q "padded err: the text is kept without the padding" "'PLS-00201: identifier' in raw and not any(len(v) - len(v.rstrip()) for x in d['criteria'] for f in x['findings'] for v in f.values() if isinstance(v, str))"
rows "$OWN${PAD}" "${FOUND[@]}"
run "padded rows and no closing tag stay UNKNOWN (the check of the end remains)" 3 --app hr calls.apx

# SQLcl answers badly: never a crash that reads as FAIL, never a half answer that reads as PASS
rows ''; FAKE_RC=1 run "SQLcl that never answers (connection failed, or a view it cannot read) → BLOCKED" 2 --app hr calls.apx
q "NO_ANSWER" "d['reasons'][0]['code'] == 'NO_ANSWER'"
rows "$OWN" "${FOUND[@]}"; FAKE_RC=1 run "SQLcl that dies after answering the first query → UNKNOWN" 3 --app hr calls.apx
rows "$OWN" "${FOUND[@]}"; run "an answer with no last row → UNKNOWN" 3 --app hr calls.apx
rows "$OWN" 'pkgchk|obj|PKG_EMPLOYEES|PACKAGE' 'pkgchk|end'
run "a row with a field missing → UNKNOWN (BAD_ANSWER), not a crash" 3 --app hr calls.apx
q "BAD_ANSWER" "d['reasons'][0]['code'] == 'BAD_ANSWER'"
if ! grep -q Traceback "$WORK/err.txt"; then ok "no traceback"; else bad "the script crashed on a truncated row"; fi
rows "$OWN" 'ORA-00942: table or view does not exist' "${FOUND[@]}" 'pkgchk|end'
run "an ORA- error in the output, with the last row and exit 0 → UNKNOWN" 3 --app hr calls.apx
q "QUERY_FAILED" "d['reasons'][0]['code'] == 'QUERY_FAILED'"
rows "$OWN" 'Error starting at line : 5 in command -' "${FOUND[@]}" 'pkgchk|end'
run "SQLcl's 'Error starting at line' in the output → UNKNOWN" 3 --app hr calls.apx
rows 'pkgchk|ctx|hr|HR' "${FOUND[@]}" 'pkgchk|end'
run "a session user that is no upper-case identifier → UNKNOWN (ODD_SCHEMA)" 3 --app hr calls.apx
q "ODD_SCHEMA" "d['reasons'][0]['code'] == 'ODD_SCHEMA'"
rows "$OWN" "${FOUND[@]}" 'pkgchk|end'
PKG_CHECK_TIMEOUT=abc run "a PKG_CHECK_TIMEOUT that is no number falls back to the default → PASS" 0 --app hr calls.apx
rows 'pkgchk|ctx|HR|-' 'pkgchk|end'
run "the app is not visible through the connection → BLOCKED" 2 --app hr calls.apx
q "APP_NOT_VISIBLE" "d['reasons'][0]['code'] == 'APP_NOT_VISIBLE'"
rows "$OWN" 'pkgchk|end'; FAKE_SLEEP=5 PKG_CHECK_TIMEOUT=1 run "SQLcl that does not finish in time → UNKNOWN" 3 --app hr calls.apx

# environments: the app names its environment, a protected one is read
config '{ "appId": 100, "appAlias": "hr", "apexlangDir": "src", "environments": { "dev": { "sqlclConnection": "dev_hr" }, "prod": { "sqlclConnection": "prod_hr", "protected": true } } }'
rows "$OWN" "${FOUND[@]}" 'pkgchk|end'
run "an app with environments and no --env → BLOCKED" 2 --app hr --task T-2 calls.apx
q "ENV_REQUIRED" "d['reasons'][0]['code'] == 'ENV_REQUIRED'"
run "--env dev → PASS, the result keyed alias.env, the environment named" 0 --app hr --env dev --task T-2 calls.apx
q "environment: dev" "d['app'].get('environment') == 'dev' and d['context']['target']['connectionName'] == 'dev_hr'"
if [[ -f .apex-evidence/T-2/package-hr.dev.json ]]; then ok "--env writes package-<alias>.<env>.json"; else bad "no package-hr.dev.json"; fi
run "--env prod (protected) is read: checks only read" 0 --app hr --env prod calls.apx
if [[ "$(cat "$SQL_ARGV")" == "-S -name prod_hr" ]]; then ok "the protected environment's own connection was used"; else bad "argv was: $(cat "$SQL_ARGV")"; fi
run "an environment the app does not declare → BLOCKED" 2 --app hr --env qa calls.apx

# the repo's own examples: every invokeApi pair and the IG wrapper's call are looked up; what only a .sql defines is not
config '{ "appId": 100, "appAlias": "hr", "apexlangDir": "src", "sqlclConnection": "dev_hr" }'
rows "$OWN" 'pkgchk|obj|PKG_ABSENCES|PACKAGE|VALID' 'pkgchk|obj|PKG_ABSENCES|PACKAGE BODY|VALID' 'pkgchk|proc|PKG_ABSENCES|APPROVE' 'pkgchk|proc|PKG_ABSENCES|REJECT' \
  'pkgchk|obj|PKG_EMPLOYEES|PACKAGE|VALID' 'pkgchk|obj|PKG_EMPLOYEES|PACKAGE BODY|VALID' 'pkgchk|proc|PKG_EMPLOYEES|CREATE_ROW' 'pkgchk|proc|PKG_EMPLOYEES|UPDATE_ROW' 'pkgchk|proc|PKG_EMPLOYEES|DELETE_ROW' \
  'pkgchk|obj|PKG_SECTORS|PACKAGE|VALID' 'pkgchk|obj|PKG_SECTORS|PACKAGE BODY|VALID' 'pkgchk|proc|PKG_SECTORS|SAVE_ROW' 'pkgchk|end'
run "the examples: three packages called (invokeApi, and the IG wrapper's executeCode) → PASS" 0 --app hr examples
q "the three were looked up; PKG_ERRORS, which only a .sql defines, was not" "all(p in sql for p in ('PKG_ABSENCES', 'PKG_EMPLOYEES', 'PKG_SECTORS')) and 'PKG_ERRORS' not in sql and all(f.endswith('.apx') for f in d['files'])"
rows "$OWN" 'pkgchk|obj|PKG_ABSENCES|PACKAGE|VALID' 'pkgchk|obj|PKG_ABSENCES|PACKAGE BODY|VALID' 'pkgchk|proc|PKG_ABSENCES|APPROVE' 'pkgchk|proc|PKG_ABSENCES|REJECT' 'pkgchk|end'
run "the examples with the other packages absent → FAIL" 1 --app hr examples

echo
echo "pkg-check: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
