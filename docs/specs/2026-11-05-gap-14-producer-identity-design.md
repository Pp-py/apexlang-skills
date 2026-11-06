# GAP-14 — identity of the attempt and the producer (design, revision 2, 2026-11-05)

Status: **accepted 2026-11-05; A and B built in PR #38 (0.8.0), C out of scope.** Exceptions to B, found while building it: `ux-check.py` (its destination page is known only after the page is measured; covered by A with a declared `--page`) and `evidence.py write` (the verdict is the agent's, made before the command starts). Original status line: Revision 2 answers the review of the first draft (blocking: the
single-use run id, and a false schema claim). Build only after the owner accepts "Decisions needed", test first.
The frozen interface (`framework/CONTRACTS.md`) allows additions only; what follows adds, and none of it is
needed for the gates that work today.

## What is built, what is left

Built (PR #38): an optional `context.runId`, written by every producer from `APEX_RUN_ID` (and into
Validation's `.exit.json`), and `delivery.py --run <id>`: a result of another run, or none, is `NOT_RUN`.
Backstop: a gate whose command exited non-zero is never PASS.

Left: **(A)** `--exit` speaks for a whole gate; **(B)** a producer that dies before writing leaves its previous
file in the task dir. Not proposed, and left open on purpose: **(C)** detecting that one run id was used for two
attempts (see "Out of scope").

## A. Exit per producer

`delivery.py --exit <gate>[/<producer>]:<code>`; the gate-only form keeps today's meaning.

### Producer keys

| Gate | Producer keys | Result it speaks for |
|---|---|---|
| architecture | `architecture` | `architecture.json` |
| validation | `validation` | the capture and its `.exit.json` |
| package | `package` | `package-<key>.json` |
| sync | `check-import` | `sync-<key>-check-import.json` |
| runtime | `walkthrough`, `record-sync` | `runtime-<key>.json`; `sync-<key>-record-sync.json` |
| security | `static`, `plsql`, `secrets`, `runtime` | `security-<alias>-<scope>.json`; `security-<key>-runtime.json` |
| ui | `static`; `runtime-<page>` for every page declared with `--page` and every `ui-<key>-runtime-<page>.json` found | `ui-<alias>-static.json`; `ui-<key>-runtime-<page>.json` |

Written `--exit security/runtime:2`, `--exit runtime/record-sync:1`, `--exit ui/runtime-orders:3`; the key
after `/` is the one in the table, resolved with the app and environment already selected (`--app`, `--env`),
so it names that app's file and the destination checks (misfiled, appId, environment) still run.
A declared page is a recognized producer **even when its file is missing**: a producer that died without
leaving a file is the case this exists for, so it must not turn into `BAD_EXIT`. A key not in the table for
that gate is BLOCKED `BAD_EXIT`, naming the keys the gate has.

### Combining forms

- Global (`--exit security:2`) applies to every producer of the gate; a specific one adds a restriction for its
  producer. **A specific exit 0 never neutralizes a global non-zero.**
- The same key, or the same gate in its global form, given twice with the same code is accepted; with different
  codes, in either order, it is BLOCKED `BAD_EXIT` (review 11, M38-02: the last argument must not erase a failure).
- `runtime` today: the global exit speaks for the walkthrough alone, not for `record-sync`. That stays;
  `runtime/record-sync:<code>` is the only way to report record-sync's exit, and it affects the order rule
  (`after_record_sync`) only as its own result's status does: a record-sync that exited non-zero is UNKNOWN or
  BLOCKED, never attributed to the walkthrough.

### Result × exit, per producer

| The producer's result | exit 0 | exit that matches its status | any other non-zero exit |
|---|---|---|---|
| PASS | PASS | n/a | UNKNOWN: it ran and failed, the file is not its output |
| FAIL / CONFLICT / BLOCKED / UNKNOWN | UNKNOWN (disagrees) | keeps its status | UNKNOWN (disagrees) |
| missing, stale or misfiled | UNKNOWN: it ran and left nothing fresh | n/a | BLOCKED when the exit is 2, UNKNOWN otherwise (`ran_without`) |
| invalid | UNKNOWN | UNKNOWN | UNKNOWN |

The gate's status stays the worst of its producers' statuses; severity (a FAIL stays FAIL) and the existing
aggregation are unchanged, and each note names its producer (`security/runtime: ran (exit 2) but ...`).
The gate-level backstop (all results PASS and the gate's exit non-zero → UNKNOWN) stays for the global form.

## B. A result is invalidated before the work, and published as one unit

Goal: for **every** producer, a run that dies after it started cannot leave the previous attempt's file readable
as current. Delivered in stages (Security and UI first, since they have several producers), but GAP-14 is not
closed until all producers are covered.

1. **Where.** After the destination is resolved and validated (task id, app, key, path) and **before** the work
   that can fail, the producer claims it: it moves the current file to `<name>.prev` (replace). If the move
   fails the producer stops (BLOCKED `STATE_UNWRITABLE`, exit 2) and says so; it never continues as if the old
   file had been invalidated. A producer that never starts leaves the old file: that case is for an external
   exit (A) or a new run id (built), not for the producer.
2. **Claim.** The claim is an exclusive create of `<name>.lock` (`O_EXCL`) holding the pid and the run id. A
   second producer for the same destination finds it and refuses (BLOCKED, exit 2), naming the lock. A lock whose
   pid no longer exists is replaced with a note, but only under `<lock>.recover`, created exclusively: a second
   contender is refused, and under it the lock is read again, so nobody removes the lock of a producer that took it
   meanwhile (review 11, M38-01). The lock carries a token; it is removed only while it still carries the remover's
   token. A lock that cannot be judged, or a `.recover` left by a producer that died inside the recovery, is left and
   reported (remove it by hand when no producer runs). The lock is
   removed on every exit path of the producer. This is local, one machine; two machines on one shared task dir
   are out of scope and stated as such.
3. **One unit.** A producer that writes a file plus metadata (`evidence.py capture`: the output and its
   `.exit.json`) publishes the **metadata last**, and the metadata carries the output's sha256. A reader accepts
   the pair only if the hash matches; output without metadata, or metadata whose hash differs, is not a result
   (UNKNOWN, never PASS). Single-file results are written to a temporary file and renamed.
4. **`.prev`.** One file, replaced by the next attempt: a temporary backup for diagnosis, **not** an audit
   archive. References by path and hash to an overwritten `.prev` break. An archive, if wanted, is the evidence
   dir's job (a timestamped copy by the orchestrator), not the producer's.
5. **Sync.** The task-dir copies (`sync-<key>-<op>.json`) are evidence and are claimed like any result. The
   guard's `.git/apex-sync/<alias>/last-<op>.json`, the `check-ok.*` markers and the `refs/apex-sync/` refs are
   **not** touched: rotating evidence does not revoke a marker, and a marker's authority keeps coming from its own
   TTL and the existing invariants. This section must be re-audited against `apex-sync-check.sh` before building.

Expected outcomes, not promises of NOT_RUN everywhere: no file and no reported exit → NOT_RUN; a reported exit 2
→ BLOCKED, and any other non-zero exit → UNKNOWN (A); a claim that failed → the producer's own BLOCKED.

## Compatibility and schemas

- **One schema change, an enum value:** `sync-result.schema.json` gains the reason `CLAIM_HELD` (a validator
  holding the 0.7.x schema rejects a sync-result with it; update schemas and scripts together, hence 0.8.0).
  Otherwise **no schema change is needed or made.** The manifest keeps `results[]` references as `kind`, `path`, `sha256`
  (`additionalProperties: false`), and no field is added to the results. The first draft's per-result timestamps
  were dropped for that reason.
- If a later revision wants a new manifest field, it is a schema evolution to be defined and tested: a validator
  holding the old schema rejects it, so it needs the minor version and a migration note, not "additive".
- New surface: the `<gate>/<producer>` syntax, `BAD_EXIT` messages, the `.prev` and `.lock` files, and the
  metadata hash. Existing `negatives.json` rules (cited by index) are untouched.
- Version: the interface change calls for **0.8.0** (`CONTRACTS.md`), with migration notes: producers now claim
  their destination; a dead producer reads NOT_RUN instead of reusing a previous file.

## Tests (negatives first)

- A: scopes independent (`security/runtime:2` with every scope PASS → only runtime UNKNOWN); two UI pages; a
  declared page with no file; invalid keys; wrong app or environment; global and specific together (specific 0
  vs global non-zero; duplicate contradictory); `runtime/record-sync` apart from the walkthrough; every row of
  the matrix.
- B: producer killed after the claim → no current file → NOT_RUN; failure to move the old file → BLOCKED and the
  old file untouched; interruption between output and metadata, and between metadata and rename → never PASS;
  output with a mismatched hash; existing `.prev`; a reader while writing; a second producer for one destination
  (refused, then recoverable after the first ends or its pid is gone); read-only task dir.
- Existing suites unchanged; a producer run with no claim support (old script version) still reads as today.

## Decisions needed

1. Accept the table and precedence of A as written, or change them.
2. B for all producers in stages (proposed), with the lock and the hash as specified, or a smaller first step.
3. Version 0.8.0 and the migration notes (recommended).

## Out of scope (stays open in GAP-14)

- **Detecting that one run id served two attempts.** Aggregation must stay idempotent: the skill asks for
  `delivery.py` after every gate, so reading the same run again is normal and must give the same answer. Any
  "consumed" state needs an explicit open/close of a run (who closes it, what happens after) and persistent
  state with atomic writes; neither exists and a timestamp comparison (1-second resolution; Validation captures
  have none) is not uniqueness. If wanted, it is its own design.
- An identity per producer *instance* (two concurrent runs of one producer) beyond the local lock; cross-machine
  runs.
