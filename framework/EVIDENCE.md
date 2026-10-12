# Evidence

A result is a claim; its evidence is what lets someone else re-check it without
trusting whoever made it (P4).

## What counts, and what does not

| Evidence | Not evidence |
|---|---|
| a command that ran, with its exit code (and a summary of its output) | an agent saying it worked, however detailed |
| a SQL statement, with its exit code and result | a green `apex validate` offered for a runtime criterion, or a successful import |
| a file — snapshot, `eval` output, log — with its sha256 | Oracle's 26.1 lint offered as Validation (advisory, P6) |
| a result file of another gate, cited by path and sha256 | a screenshot alone for a behavioral criterion: it shows a moment, not a behavior (a chart that drew is the exception — drawing *is* the criterion) |
| | a result from another task, or from before the inputs changed (stale → `NOT_RUN`) |

## What every result records about itself

Each result carries a `context` (`schemas/common.schema.json`). A field that was not
observed is absent — never guessed.

| Recorded | Field |
|---|---|
| the task | `context.task` (null outside a task) |
| the repository revision | `context.repo.commit`, `context.repo.dirty` when the working tree differed from it, and `context.repo.tree`, the working tree it judged as a git tree hash (what freshness is checked against) |
| the framework revision | `context.frameworkVersion` (the apexlang-skills release) |
| what it ran against | `context.target`: `connectionName` (sync), `runtimeUrl` (runtime), and — when the run talked to them — `apexVersion` and `sqlclVersion` |
| the APEXlang version of the app | `app.mmdVersion`, from the app's `.apex/apexlang.json` |
| when | `context.timestamp` (UTC) |
| who decided | `context.producer`: the skill, and `method` — `tool` (a script computed it), `agent`, or `human` |
| the gate and the verdict | the result's `kind` and `status`, with `reasons` |
| what it rests on | `evidence[]` — and per criterion, `criteria[].evidence[]` |

An `evidenceRef` is one of: `{kind: command, command, exitCode, output?}`,
`{kind: sql, statement, exitCode, result?}`, `{kind: file, path, sha256, description?}`. Output
that may hold hostnames or data is summarized, never copied: the sync guard keeps a SQL
count only when it is a clean number.

## Where it lives

Under `<evidenceDir>/<task>/` — default `.apex-evidence/`, set by `evidenceDir` in
`apex-sync.json` — with raw artifacts in `raw/<gate>-<alias>/` (paths in
[CONTRACTS.md](CONTRACTS.md) §Where results land). The directory carries a `.gitignore` of `*` —
created by whoever writes there first, put back by the guard whenever it is missing: **evidence
is machine-local and never committed by accident.** Committing is an opt-in: *edit* that
`.gitignore` (a deleted one comes back) to admit `*/manifest.json` and the result files it
cites — never `raw/`.

## Redaction

| Where | What |
|---|---|
| the sync writer, automatically | in messages and recorded commands, a path that begins with the repo root becomes `<repo>/…` and one under `$HOME` becomes `~/…` — in the shell's form and in the `C:/…` form native tools print; the scratch dir in a recorded command becomes `<scratch>`; a SQL error text is never kept |
| `evidence.py`, automatically | `capture` strips session ids, shortens local paths and replaces a password assignment or a connect string with `<redacted>` before a raw file is saved; `write` strips session ids and paths from a draft and refuses one holding a password or a connect string, naming the field, never the value |
| `pw.sh`, automatically | the password reaches the browser through a mode-600 file deleted on exit, never argv or output; the `?session=` token is stripped from the URL it remembers; `close-all` deletes the session's snapshots |
| the schemas, on every result | they reject an APEX session id (`session=…`, `f?p=…:…:<id>`), a password assignment, a `user/password@host` connect string, a connect string as a connection name, an absolute, `~` or `..` path |
| the agent, by discipline | assert with `eval` on the value under test rather than full-page snapshots; keep page dumps under `raw/` only; record no customer data in `observed` |

Anything that slips past all of this lands only in the ignored evidence dir; that is the
last line, not the first.
