# Principles

Ten rules. Each names where it is enforced — a rule nothing enforces is a wish, and is
listed as such in [CAPABILITIES.md](CAPABILITIES.md) §Declared gaps.

## P1 — Single write path

Every write to application data goes through a PL/SQL package; never region-bound
Automatic Row Processing, never DML in a page process. The package is the one place a
business rule holds, whatever reaches the table — a page, a job, a REST handler, SQLcl.

*Enforced by:* `apexlang-architecture` (procedures A/B in `package-boundaries.md`, red-flag
scan) → the Architecture gate. Interim rule while KC-4 stands: a thin `executeCode` wrapper
and `invokeApi` both satisfy it.

## P2 — Single ownership

Every concern has exactly one owner: each table one package, each rule one place, each
gate one producer, each topic one document. Two owners means two versions of the truth.

*Enforced by:* package boundaries (architecture); one reader of `apex-sync.json` per
skill, held equal by `config-parity.sh`; one status vocabulary ([CONTRACTS.md](CONTRACTS.md)).

## P3 — Fail closed

What cannot be decided blocks. A gate that cannot reach the Builder, read its config,
resolve the target app or compute a marker's age does not let the operation through.
A guard that crashes blocks.

*Enforced by:* `apex-sync-check.sh` (UNKNOWN, exit 3, on any unclassified exit), the hook
(any failure after the prefilter is a block), `pw.sh` (an unverifiable login is refused),
the upstream tests (a missing prerequisite is BLOCKED, never a pass).

## P4 — No success without evidence

PASS means a check ran to the end and something it executed proves the condition.
**PASS ≠ NOT_RUN ≠ UNKNOWN ≠ "the agent says it worked".** A green `validate` is not a
rendered page; a successful import is not a working app.

*Enforced by:* the schemas — a sync PASS needs a command or query that exited 0; a runtime
PASS needs every required criterion PASS, each on a saved file or an exit-0 command; an
architecture PASS needs a red-flag scan that ran (exit 0 or 1) — and `tests/contract/`
(negatives that encode each way to fake one).

## P5 — Separate stages, separate verdicts

Generation, validation, sync and runtime are different stages with different owners. One
stage's success says nothing about another's: `apex validate` proves grammar, `import`
loads metadata, neither renders a page — and the 26.1 lint is not the compiler.

*Enforced by:* the gate model ([GATES.md](GATES.md)): each gate states what it does **not**
establish.

## P6 — Delegate, with a precedence

This repo never duplicates what Oracle's skills do. For grammar and components the
authority is, in order: **SQLcl `apex validate` > Oracle's 26.1 lint > Oracle's inventory,
policies and templates > this repo**. This repo owns what Oracle's skills do not cover:
the write path, ownership, the data contracts behind the UI, sync safety, runtime proof,
the gates and the evidence. Where a recipe here disagrees with Oracle, the disagreement is
recorded as a known conflict, not silently kept or silently dropped.

*Enforced by:* `tests/upstream/verify-citations.sh` (every quotation still says what we
claim, at the locked revision), [CAPABILITIES.md](CAPABILITIES.md) §Known conflicts.

## P7 — Complexity has to be earned

A layer, a package, a script, a field or a document exists because a real responsibility
needs it — never for symmetry or future use. A flow package around one entity, a schema
field nobody reads, a wrapper with nothing to abstract: each is a defect.

*Enforced by:* review; the architecture red flags (`FLOW_WRAPS_ONE_ENTITY`); the schemas'
`additionalProperties: false`.

## P8 — Scoped and perishable

An authorization is scoped and expires: a sync marker covers one app, one direction, ten
minutes, and is withdrawn when the next check of that direction starts. A result belongs
to a task and a revision; read later or elsewhere, it is stale — NOT_RUN, not PASS.

*Enforced by:* the hook (TTL, per-app, per-direction markers), `--task` result paths,
the orchestration contract in [GATES.md](GATES.md).

## P9 — PASS is not consent

A PASS says an operation is safe or a change is sound. It does not decide to deploy, to
overwrite a replica, or to override a guard — the user does. `record-sync --force`,
setting a syncpoint aside, deploying to an environment: a person's call, never an agent's.

*Enforced by:* the hook refuses `record-sync --force` and writes to the guard's markers,
refs and state, even with a fresh marker.

## P10 — No secrets, no personal data

Evidence never carries a password, a connect string, an APEX session id, a home path or a
customer's data. Credentials live in the environment, a gitignored `.env` or a file
outside the repo — never in `apex-sync.json`, which is committed. Raw artifacts
(snapshots, page dumps) are machine-local and never committed.

*Enforced by:* the schemas' `safeText` / `connectionName` / `runtimeUrl` patterns, the
sync writer's redaction, `pw.sh` (password by mode-600 file, never argv; token stripped
from `last-url`), `.apex-evidence/.gitignore`. See [EVIDENCE.md](EVIDENCE.md) §Redaction.
