# Check: package — the Package gate

**Verifies** that the packages and procedures a change names exist in the database the page runs against, compile, and declare what the page calls. Unlike the page checks it drives no browser and needs no test user: it reads the database through the app's saved SQLcl connection with `SELECT` statements only — never DDL, never a recompile. `apex validate` proves grammar; a process can name a procedure that does not exist and still validate.

**Gate:** Package (`framework/GATES.md`) — after Validation, before Sync; required for an app with `"packageGate": true` in `apex-sync.json` (the top-level default, or the app's own), opt-in until 1.0.0. Reading a `protected` environment is allowed: nothing is written. An app with environments needs `--env`, as every gate does. Connection, `SQLCL_BIN` and `PKG_CHECK_TIMEOUT`: `setup.md` §5.

## Run

```bash
python3 <skill-dir>/scripts/pkg-check.py --app <alias> [--env <name>] --task <id> <the .apx files or directories>
```

Exit 0 PASS · 1 FAIL · 2 BLOCKED · 3 UNKNOWN. Exit 3 authorizes nothing: fix the cause and run it again. With `--task` the result lands in `<evidenceDir>/<task>/package-<alias>[.<env>].json`, for every status once the app is resolved.

## What it looks up

In the app's **parsing schema** (`apex_applications.owner` for the app's `appId`, the schema APEX resolves an unqualified package name in). The connection's own `SESSION_USER` is compared to it: the owner sees all of its objects, so for the owner "absent" means absent; any other user cannot tell absent from not granted.

| Source in the `.apx` | Looked up |
|---|---|
| a page process or a workflow activity of `type: invokeApi` | `invoke.package` and `invoke.procedureOrFunction`, strictly: absent is a FAIL (the owner) or UNKNOWN (another user) |
| a named-notation call, `pkg.proc(p_x => ...)`, in a `sql` or `plsql` block (an `executeCode` thin wrapper, a region query) | the same pair, best effort: Oracle's own packages (`apex_`, `dbms_`, `utl_`, `owa_`, `wwv_`, `json_`, `sdo_`, `ctx_`, `sys`, `htp`, `htf`, `xmltype`) and a name the block declares as a variable are skipped |

A name that is no plain Oracle identifier (`[A-Za-z][A-Za-z0-9_$#]{0,127}`) in an `invokeApi` stops the run BLOCKED before any query; nothing from a file is pasted into SQL unvalidated. Lower and upper case both resolve; quoted or owner-qualified names do not. Not looked up, and never a PASS: an `invokeApi` with `invoke.owner`, with `source.location` on a remote database, or with an `invoke.type` this reader does not know, and a parsing schema the source declares that differs from the database's — all UNKNOWN. A REST Source operation (`invoke.type: restSource`) is no PL/SQL and is skipped.

## Pass criteria

Each criterion has an ID: a package-result (`framework/schemas/package-result.schema.json`) reports it by that ID, with findings by package, procedure, file and line — never code. A PASS needs `PKG-EXISTS`, `PKG-COMPILED` and `PKG-PROC-EXISTS` all PASS.

- `PKG-EXISTS` — Every package looked up has a specification in the parsing schema and, when the specification declares subprograms, a package body. FAIL when the session's user is the owner and the package or the body is absent. UNKNOWN when it is another user, when the name resolves only through a synonym (synonyms are not followed, a DB link included), or when a code-block call names no package at all (an undeclared name that is no package makes the run UNKNOWN: a typo, or an object this reader cannot tell from one).
- `PKG-COMPILED` — Specification and body are `VALID` and `ALL_ERRORS` holds no `ERROR` for them. FAIL on an error (line:position and message; the message text is kept minus quoted symbols). UNKNOWN on `INVALID` with no error to read: Oracle recompiles a package invalidated by a dependency on first use, or this user cannot read its errors. Compile it through your usual database path (this gate never does) and run it again.
- `PKG-PROC-EXISTS` — Each procedure a file calls is declared in the specification of a package that was found (`ALL_PROCEDURES`; a private subprogram cannot be called). FAIL when it is not declared.
- `PKG-STANDALONE` — Advisory, never a verdict: an `invokeApi` process names a standalone procedure or function (`invoke.type: plsqlProcedureOrFunction`, or no package), which this version does not look up.

## Reading the result

- `status` and `reasons[0].code` say which of the cases below it is; `criteria[]` carries each criterion's status and its `findings`.
- `database.owner` and `database.sessionUser` say where the names were looked up and as whom. `owner` equal to `sessionUser` is what makes an absent package a FAIL rather than UNKNOWN.
- `evidence[]` is the five `SELECT`s that ran (`apex_applications` with `ALL_OBJECTS`, `ALL_ERRORS`, `ALL_PROCEDURES`, `ALL_SYNONYMS`), each with its exit code and row count. `ALL_OBJECTS` and `ALL_SYNONYMS` back `PKG-EXISTS`; `ALL_OBJECTS` and `ALL_ERRORS` back `PKG-COMPILED`; `ALL_PROCEDURES` backs `PKG-PROC-EXISTS`. A row count of 0 behind an UNKNOWN is the session's visibility, not proof the code is absent.
- `files` lists the `.apx` read: a file the agent did not pass is not covered. `unparsed` lists what could not be followed, each with its file and line: a non-empty `unparsed` is never a PASS.
- `context.timestamp` is when the database was read. The result is fresh while the working tree is unchanged; it says nothing about the database after that moment.

## BLOCKED and UNKNOWN

BLOCKED (nothing was decided; fix the input): `NO_PAIRS` (nothing to look up — no `invokeApi` and no named-notation call — or nothing resolved), `NOTHING_TO_SCAN`, `NOT_APX` and `OUTSIDE_REPO` (a path the gate does not read), `UNREADABLE`, `BAD_IDENTIFIER`, `TOO_MANY` (more than 500 packages), `NO_APP_ID`, `NO_CONNECTION`, `NO_SQLCL`, `NO_BASH`, `NO_ANSWER` (SQLcl never answered: the connection, a privilege or a view — run `apex-sync-check.sh doctor`), `APP_NOT_VISIBLE` (the app has no row in `apex_applications` through this connection: not imported yet, wrong workspace or `appId`), and the common ones (`APP_REQUIRED`, `ENV_REQUIRED`, `ENV_UNKNOWN`, `BAD_APP`, `BAD_ENV`, `BAD_TASK`).

UNKNOWN (something was found that the gate cannot read as held or failed; never PASS): `UNVERIFIED` (a criterion UNKNOWN, or a file not read), `UNPARSED` (nothing could be followed), `PARSING_SCHEMA`, `ODD_SCHEMA`, `QUERY_FAILED`, `BAD_ANSWER`, `TIMEOUT` (`PKG_CHECK_TIMEOUT`).

## A change with no page, and what this gate cannot resolve

A change that touches no page has nothing for this gate to look up: record `--skip package:<reason>` with `delivery.py`. The SQL source is Security's `plsql` scope, and nothing compares the database with it. The same `--skip` is the only way out of two cases the gate cannot resolve: the first import of an app (BLOCKED `APP_NOT_VISIBLE`: there is nothing in the database yet), and an `invokeApi` call to an Oracle package or to a shared package reached by a public synonym (UNKNOWN every time: synonyms are not followed, a DB link included).

## What a PASS does not establish

That the package does what it should (Runtime does); that the database holds the source in the repo (`ALL_SOURCE` is not compared, and the SQL files are never read); calls the scan cannot see — dynamic SQL, validations, computations, authorization schemes, jobs, a positional-notation call in an `executeCode`, owner-qualified calls, workflow and `appProcess` calls outside code blocks, standalone procedures and functions; parameter names or types, which overload is called, whether a subprogram is a procedure or a function; that anything is imported or renders; another environment, or another edition (EBR); that the files passed are the app's own; that the parsing schema in the database is the one the source declares, unless the source declares one; that the state still holds after the run; the grants of the app's own users.
