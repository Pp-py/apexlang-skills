# Gates

A gate is a check a change must pass, with one owner and one producer. Each states what
its PASS establishes **and what it does not** — reading more into a PASS than its gate
establishes is how "validate passed" turns into "it works" (P5).

## The gates

| | Architecture | Validation | Package | Sync | Runtime | Security | UI |
|---|---|---|---|---|---|---|---|
| **Owner** | apexlang-architecture | Oracle (`apexlang-compile`) — consumed, not reimplemented | apex-sentinel | apex-sync-guard | apex-sentinel | apex-security | apex-ux |
| **Producer** | the agent, through `evidence.py`; `arch-scan.py` for four red flags | `validate-apex-app.sh` | `pkg-check.py`: read-only `SELECT`s through the app's saved SQLcl connection | `apex-sync-check.sh` | the agent, through `pw.sh` and `evidence.py` | `sec-scan.py` (`.apx`), `plsql-scan.py` (packages), `secrets-scan.py` (tracked files), `sec-probe.py` (runtime, through `pw.sh`) | `ux-scan.py` (static) and `ux-check.py` (runtime, through `pw.sh`) |
| **Checks** | every write has one owning package; every rule sits where procedures A/B put it; the source carries no red flag | the `.apx` compiles for that APEXlang version | the packages and procedures the `.apx` names (an `invokeApi` process or workflow activity, a named-notation call in its sql/plsql blocks) exist in the app's parsing schema, are `VALID` with no compile error, and declare the procedure called | `check-import`: the Builder holds no work the import would destroy · `check-export`: LOCAL holds no uncommitted work the export would destroy | the archetype's pass criteria, on the running page, as the verified test user, with the data side read back through SQLcl | apex-security's `FAIL` criteria: authorization, public pages, checksums, escaping, safe URLs, bound SQL, no secrets; at runtime anonymous access, tampering, role refusal, escaped payloads | apex-ux's `FAIL` criteria: statically over the `.apx`, and at runtime on each page the task declares as touched (`delivery.py --page`), with axe-core and, for a page declared `:dialog`, its dialog's focus |
| **PASS establishes** | the design of this change, each decision tied to the code that implements it | grammar and component properties are valid for that SQLcl + APEXlang pair | when the database was read, in that database and the app's parsing schema: each package found has a specification and, if it declares subprograms, a body, both `VALID`, `ALL_ERRORS` holds nothing for them, and each procedure the files call is declared in a specification | for this app, through this connection, the operation destroys nothing — for 5 minutes, and only while the source it checked is unchanged | the change does what its recipe promises, for every required criterion exercised | every `FAIL` criterion the four scopes exercised held, on the source and the URLs probed | every `FAIL` criterion the runs exercised held: the static scan over those files, and each page declared as touched, whose result names that page (and each dialog declared, with its focus exercised) |
| **PASS does NOT establish** | that anything compiles, renders or is synchronized | that the PL/SQL compiles or the packages it calls exist (the Package gate looks that up); anything at runtime; anything the 26.1 lint says | that the PL/SQL does what it must (Runtime); that the database holds the repo's source (nothing is compared); calls the scan cannot see (dynamic SQL, inline values, positional calls, validations and authorization schemes, `owner.pkg.proc`, standalone procedures, workflows and `appProcess` outside code blocks); parameter names or types, which overload, procedure or function; another environment or edition; that it stays true (`context.timestamp` says when the database was read: compiling in the database changes no file); that the files passed are this app's or all of them (`files` lists them); anything about the import or the rendered page | that the import's payload is right (it is reported, not judged); other apps; other environments; that the Builder stays untouched afterwards | criteria not exercised; other pages; security; performance | resistance to an attacker (not a pentest); git history; database grants; what an authorization scheme's PL/SQL decides; pages, URLs or roles not probed; the instance's settings | WCAG conformance; the `ADVISE` and `manual` criteria; pages nobody declared as touched (the diff cannot say which a change touches), dialogs not declared `:dialog`, states not checked; that the declaration is complete or that the page belongs to this app's host (identity is not signed); that the page works (Runtime) |
| **Evidence** | `architecture-result`: decisions with evidence, the red-flag scan's command | the script's command, exit code and output (`Validation successful`) | `package-result`: criteria `PKG-EXISTS`, `PKG-COMPILED`, `PKG-PROC-EXISTS`; the `SELECT`s that ran, with exit codes; findings by package, procedure, file and line, never code | `sync-result`: the export, the comparison, changes, payload; the marker | `runtime-result`: per criterion, evidence files (sha256) and SQL | `security-result` per scope: findings by file and line, never a value; probes by URL without session or checksum | `ui-result` per scope: findings with file and line, or axe rule and selectors, never node HTML; axe's raw output (sha256) |
| **Statuses** | PASS · FAIL · BLOCKED · UNKNOWN | PASS · FAIL · BLOCKED · UNKNOWN | PASS · FAIL · BLOCKED · UNKNOWN | PASS · FAIL · CONFLICT · BLOCKED · UNKNOWN | PASS · FAIL · BLOCKED · UNKNOWN | PASS · FAIL · BLOCKED · UNKNOWN | PASS · FAIL · BLOCKED · UNKNOWN |
| **Holds back** | calling the build done — decided before it, passed on the built code | the import | the Sync check and the import: a page that calls code the database lacks | `apex import`/`export`, the deploy script, `apexctl` roundtrip | any "it works" claim | calling a change safe to deploy | calling the UI done |
| **Enforced by** | discipline | `apexlang-delivery`'s import lane and manifest (Validation before the import, required); nothing on Oracle's deploy script, which does not validate (GAP-3) | discipline; opt-in per app (`packageGate`) until 1.0.0 | the `PreToolUse` hook (Claude Code); discipline elsewhere | discipline | discipline; opt-in per app (`securityGate`) until 1.0.0 | discipline; opt-in per app (`uiGate`) until 1.0.0 |

## Order

```text
Architecture → build (.apx + package) → Validation → Package → Sync → import → record-sync → Runtime → Security → UI
```

Architecture is decided before the build and passed after it: the decisions are made first (a
missing input BLOCKS right there), but the evidence they rest on and the red-flag scan need the
built `.apx` and package, so its result is written once they exist. Package follows Validation: it
looks up, in the database, the names the compiler has just accepted, and it needs no Builder. Sync goes last before the
import because it is the perishable one: its PASS lapses in 5 minutes, and it speaks only for
the LOCAL it compared. `record-sync` right after the import
is part of the import, not an optional step — skipping it poisons the next comparison.
Runtime comes after the import because it measures what the Builder now serves. Security
comes after Runtime — its probes need the app imported and working — and before UI, the graver
of the two: a consumer stops at the first that does not PASS. UI comes last: a page's UI is
judged once it works and is safe. Its static scan can run any time after the
build as feedback; the gate's results are the ones written in the task after Runtime.

**The Runtime gate and `record-sync`.** Runtime cites two results: its own
(`runtime-<alias>[.<env>].json`) and the `sync-result` that `record-sync` leaves
(`sync-<alias>[.<env>]-record-sync.json`), so the import has to have been recorded for it to PASS. It is
`NOT_RUN` when the `record-sync` result is missing, stale, or not `operation: record-sync` ("misfiled"), and when
the runtime verdict's `context.timestamp` is earlier than the `record-sync`'s (the same second is in order); a
timestamp that is absent or not a real UTC instant is `UNKNOWN`. Only the runtime result is read as stale; a
`record-sync` that did not PASS keeps its own status in the gate. The Sync gate does not read it: its PASS
(`check-import`) is what authorizes the import, so a Sync gate that waited for `record-sync` could not PASS
until after the import it must precede. What this does **not** establish:
- that the import ran: a `record-sync` PASS records a syncpoint after a fresh check, and passes after an omitted
  import too; `export` followed by `record-sync` writes the same file, so it satisfies the requirement as well;
- that the page was observed after the import: `context.timestamp` is when the verdict was written
  (`evidence.py write`), with a resolution of one second, not when it was seen (the import ending every session,
  UP-8, is what mitigates this);
- anything about a `record-sync` run again later in the task: it overwrites the file with a newer timestamp and
  makes the runtime verdict already written `NOT_RUN` — write the walkthrough's verdict again;
- a task with no import, which has no `record-sync`: it needs `--skip runtime:<reason>`, or a no-op `record-sync`
  (basis `builder-unchanged`) before the walkthrough.

**The Package gate.** Required for an app whose `apex-sync.json` sets `"packageGate": true` (a
top-level default, or the app's own); otherwise `required: false` with a `notApplicableReason`.
`pkg-check.py` reads the `.apx` files it is given and looks up, with read-only `SELECT`s through the app's saved
SQLcl connection (the environment's, with `--env`; a `protected` environment may be read: nothing is written), the
packages and procedures they name in the app's parsing schema. It never runs DDL and never recompiles. A missing
package or procedure, or a compile error in `ALL_ERRORS`, is `FAIL`; a package that is `INVALID` with no error to
read, one the session's user cannot see, a synonym or a name the reader cannot follow (an `invoke.owner`, a remote
database, a parsing schema the source changes) is `UNKNOWN`, never `PASS`; nothing to look up, no SQLcl or connection,
an app not visible to the connection (a first import) is `BLOCKED`. The gate has one result,
`package-<alias>[.<env>].json`. It is `NOT_RUN` when the result is missing or stale; a change that touches no
page has nothing to look up and a first import has no app yet: record `--skip package:<reason>`. Synonyms are not followed,
so a call to a package reached by synonym (Oracle's `APEX_UTIL` among them) is `UNKNOWN` until the gate is skipped. Opt-in until 1.0.0.
Criteria, reasons and limits: [`checks/package.md`](../skills/apex-sentinel/checks/package.md).

**The Security gate.** Required for an app whose `apex-sync.json` sets `"securityGate": true` (a
top-level default, or the app's own); otherwise `required: false` with a `notApplicableReason`.
It passes on four scopes, each a `security-result` PASS: `static` (`sec-scan.py`), `plsql`
(`plsql-scan.py`), `secrets` (`secrets-scan.py`) and `runtime` (`sec-probe.py`, at least one probe
exercised). Its status is the worst of those results. Its three scans can run any time after the
build as feedback. Opt-in until 1.0.0.

**The UI gate.** Required for an app whose `apex-sync.json` sets `"uiGate": true` (a top-level
default, or the app's own); otherwise the consumer records it `required: false` with a
`notApplicableReason`. It passes on two scopes: the static scan's `ui-result` PASS, and a runtime
`ui-result` PASS for each page the task declares as touched. *Touched* is the caller's statement,
not something a consumer can derive (after `record-sync` the diff is empty, and a file does not
name the pages that use a shared component); *checked* is what a result proves. A consumer closes
the gap by taking the declaration as input: `delivery.py` takes `--page <page>[:dialog]`, once per
page, where `<page>` is the part of `ui-<alias>[.<env>]-runtime-<page>.json` that
[CONTRACTS.md](CONTRACTS.md) defines. It reads exactly that file, valid and fresh, and the
result's own `runtimeUrl` must name that page (a copy of another page's result, or of another
URL's, is `NOT_RUN` misfiled); `:dialog` also needs `UX-DIALOG-FOCUS` PASS, since `ux-check.py`
reports PASS when no `--dialog` opener was given. With no page declared the gate is `NOT_RUN`
(at least one is required), and any other runtime `ui-result` in the task still counts, so a FAIL
on a page nobody declared is still FAIL. Its status is the worst of those results. A whole gate
is skipped with `--skip ui:<reason>`, which wins over `--page`; a page is never skipped. A
consumer without that input has no way to tell a verified page from an untouched one. Opt-in until 1.0.0; `apexlang-delivery` already requires it only where the app opts in.

## Aggregation

A task's status is the worst status among its **required** gates:
`FAIL > CONFLICT > UNKNOWN > BLOCKED > NOT_RUN > PASS`. No required gate at all is
`NOT_RUN`, never `PASS`. A gate is skipped only by recording it `required: false` with a
`notApplicableReason`; it is then `NOT_RUN`. The `verification-manifest` schema encodes this
rule both ways, so a manifest that claims a better or a worse status than its gates is
invalid. A gate left out may also say why with `excludedBy` — `config` (the app did not opt in
to `packageGate` / `securityGate` / `uiGate`) or `skip` (the caller's `--skip`) — so a PASS can be told from one
that never evaluated a gate; `delivery.py` lists those gates on stderr, and the PASS is no
statement about them.

## Freshness

- A sync **marker** authorizes for 5 minutes, and is withdrawn whenever a check of that
  direction does not PASS — even one stopped before it began — so a FAIL or a BLOCKED never
  leaves an earlier PASS standing. It is bound to the LOCAL it checked (GAP-9): the app's
  source dir, hashed when the check starts, again when it writes the marker, and by the hook
  before the import or export runs. A change there since the check — an edit, a new file, a
  capture undone — and the hook blocks until the check runs again.
- A **result** is fresh for the task named in its `context.task`, while the working tree still
  hashes to its `context.repo.tree` — tracked and untracked files, ignored ones left out, so
  results in the evidence dir never change it. Read for another task, after a file changed, or
  with no `tree` recorded, it is stale: the consumer records `NOT_RUN`, not the old status.
  `framework/scripts/evidence.py fresh --task <id> <result>…` says which (exit 0 fresh · 1 stale).
  Nothing expires on a clock; the marker's 5 minutes are the hook's, not a result's. The one clock a consumer
  reads is a sequence, not an age: within a task, the Runtime verdict's `context.timestamp` must not be earlier
  than the `record-sync`'s (see The Runtime gate and `record-sync`, and the orchestration contract below).

## The orchestration contract

What a consumer — `apexlang-delivery` (`delivery.py`), a CI pipeline, an agent loop — may and
may not do. It orchestrates the gates; the rules below apply the gates' own to what it reads (P2, P6).

**MUST**
- pass `--app <alias>` and `--task <id>` to every gate command, and read results only from
  that task's directory;
- validate each result before reading it: against its schema — an invalid result is `UNKNOWN` — and
  as the result *of that destination*: the `operation` (sync) or `scope` (security, ui) its name
  says, the app's `appAlias`, and, for a result tied to a Builder (package, sync, runtime, the runtime
  scopes of security and ui), the `environment` (absent only without `--env`) and the `appId`
  (when both the result and `apex-sync.json` carry one). A valid, fresh result of another
  destination is `NOT_RUN` ("misfiled", P8), never that destination's `PASS`. The architecture
  decision is the task's, not an app's: it is read for any app. This checks consistency, not
  authenticity — results are not signed (`delivery.py`);
- read a missing result — or one whose `context.timestamp` predates the command it just ran,
  left by an earlier run — as `BLOCKED` when the command exited 2, `UNKNOWN` otherwise
  (`delivery.py --exit <gate>:<code>`: it sees files, the agent tells it the exit);
- read the Runtime gate's two results, `runtime-<key>.json` and `sync-<key>-record-sync.json`, in order: `NOT_RUN`
  when `record-sync` is missing, is not `operation: record-sync`, or when the runtime verdict's `context.timestamp`
  (parsed as a UTC time; absent or unreadable is `UNKNOWN`) is earlier than the `record-sync`'s. The Sync gate stays
  `check-import` alone, and `--exit runtime:<code>` speaks for the runtime result only (`delivery.py`);
- write the manifest with the aggregation rule above, citing each result by path and sha256;
- stop at the first required gate that is not `PASS`, and report it — the user decides what
  happens next (P9).

**MAY**
- skip a gate, only as `required: false` with a `notApplicableReason`;
- re-run a gate: the new result replaces the old, and both runs are real runs;
- verify several apps in one task.

**MUST NOT**
- add a rule, reinterpret a status, or promote an advisory signal (the 26.1 lint, `verify-ui`)
  to a verdict;
- turn `UNKNOWN` into `PASS` by retrying until it passes without recording the attempts;
- write markers, refs or guard state, or run `record-sync --force`;
- import or export without the Sync gate's `PASS` for that app, environment and direction in
  the last 5 minutes, for the LOCAL it checked;
- deploy to an environment the user did not name (`--env`; the guard BLOCKS a gate without
  it for an app with environments), or import or export at all into a `protected` one.

## Adding a gate

Phase 3 brought UI/UX and Security as gates, and Package followed (all above). A new gate needs the
following — and changes none of the existing gates:

1. an owning skill and a producer — a script where possible, the agent where not;
2. a result schema in `schemas/` (experimental first), fixtures, and negatives that encode
   what its PASS requires;
3. its column in the table above, including what its PASS does **not** establish;
4. its place in the order, and whether it is required by default;
5. its name in the `verification-manifest` gate enum, and its result kind in that schema's
   `results[].kind` enum.
