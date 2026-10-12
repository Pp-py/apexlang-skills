# Gates

A gate is a check a change must pass, with one owner and one producer. Each states what
its PASS establishes **and what it does not** — reading more into a PASS than its gate
establishes is how "validate passed" turns into "it works" (P5).

## The gates

| | Architecture | Validation | Sync | Runtime | Security | UI |
|---|---|---|---|---|---|---|
| **Owner** | apexlang-architecture | Oracle (`apexlang-compile`) — consumed, not reimplemented | apex-sync-guard | apex-sentinel | apex-security | apex-ux |
| **Producer** | the agent, through `evidence.py`; `arch-scan.py` for four red flags | `validate-apex-app.sh` | `apex-sync-check.sh` | the agent, through `pw.sh` and `evidence.py` | `sec-scan.py` (`.apx`), `plsql-scan.py` (packages), `secrets-scan.py` (tracked files), `sec-probe.py` (runtime, through `pw.sh`) | `ux-scan.py` (static) and `ux-check.py` (runtime, through `pw.sh`) |
| **Checks** | every write has one owning package; every rule sits where procedures A/B put it; the source carries no red flag | the `.apx` compiles for that APEXlang version | `check-import`: the Builder holds no work the import would destroy · `check-export`: LOCAL holds no uncommitted work the export would destroy | the archetype's pass criteria, on the running page, as the verified test user, with the data side read back through SQLcl | apex-security's `FAIL` criteria: authorization, public pages, checksums, escaping, safe URLs, bound SQL, no secrets; at runtime anonymous access, tampering, role refusal, escaped payloads | apex-ux's `FAIL` criteria: statically over the `.apx`, and at runtime on each page the change touched, with axe-core and each dialog's focus |
| **PASS establishes** | the design of this change, each decision tied to the code that implements it | grammar and component properties are valid for that SQLcl + APEXlang pair | for this app, through this connection, the operation destroys nothing — for 10 minutes | the change does what its recipe promises, for every required criterion exercised | every `FAIL` criterion the four scopes exercised held, on the source and the URLs probed | every `FAIL` criterion the runs exercised held: the static scan over those files, and each page and dialog checked |
| **PASS does NOT establish** | that anything compiles, renders or is synchronized | that the PL/SQL compiles or the packages it calls exist; anything at runtime; anything the 26.1 lint says | that the import's payload is right (it is reported, not judged); other apps; other environments; that the Builder stays untouched afterwards | criteria not exercised; other pages; security; performance | resistance to an attacker (not a pentest); git history; database grants; what an authorization scheme's PL/SQL decides; pages, URLs or roles not probed; the instance's settings | WCAG conformance; the `ADVISE` and `manual` criteria; pages, dialogs or states not checked; that the page works (Runtime) |
| **Evidence** | `architecture-result`: decisions with evidence, the red-flag scan's command | the script's command, exit code and output (`Validation successful`) | `sync-result`: the export, the comparison, changes, payload; the marker | `runtime-result`: per criterion, evidence files (sha256) and SQL | `security-result` per scope: findings by file and line, never a value; probes by URL without session or checksum | `ui-result` per scope: findings with file and line, or axe rule and selectors, never node HTML; axe's raw output (sha256) |
| **Statuses** | PASS · FAIL · BLOCKED · UNKNOWN | PASS · FAIL · BLOCKED | PASS · FAIL · CONFLICT · BLOCKED · UNKNOWN | PASS · FAIL · BLOCKED · UNKNOWN | PASS · FAIL · BLOCKED · UNKNOWN | PASS · FAIL · BLOCKED · UNKNOWN |
| **Holds back** | calling the build done — decided before it, passed on the built code | the import | `apex import`/`export`, the deploy script, `apexctl` roundtrip | any "it works" claim | calling a change safe to deploy | calling the UI done |
| **Enforced by** | discipline | nothing on the deploy lane — Oracle's deploy script does not validate (GAP-3) | the `PreToolUse` hook (Claude Code); discipline elsewhere | discipline | discipline; opt-in per app (`securityGate`) until 1.0.0 | discipline; opt-in per app (`uiGate`) until 1.0.0 |

## Order

```text
Architecture → build (.apx + package) → Validation → Sync → import → record-sync → Runtime → Security → UI
```

Architecture is decided before the build and passed after it: the decisions are made first (a
missing input BLOCKS right there), but the evidence they rest on and the red-flag scan need the
built `.apx` and package, so its result is written once they exist. Sync goes last before the
import because it is the perishable one: its PASS lapses in 5 minutes, and it speaks only for
the LOCAL it compared. `record-sync` right after the import
is part of the import, not an optional step — skipping it poisons the next comparison.
Runtime comes after the import because it measures what the Builder now serves. Security
comes after Runtime — its probes need the app imported and working — and before UI, the graver
of the two: a consumer stops at the first that does not PASS. UI comes last: a page's UI is
judged once it works and is safe. Its static scan can run any time after the
build as feedback; the gate's results are the ones written in the task after Runtime.

**The Security gate.** Required for an app whose `apex-sync.json` sets `"securityGate": true` (a
top-level default, or the app's own); otherwise `required: false` with a `notApplicableReason`.
It passes on four scopes, each a `security-result` PASS: `static` (`sec-scan.py`), `plsql`
(`plsql-scan.py`), `secrets` (`secrets-scan.py`) and `runtime` (`sec-probe.py`, at least one probe
exercised). Its status is the worst of those results. Its three scans can run any time after the
build as feedback. Opt-in until 1.0.0.

**The UI gate.** Required for an app whose `apex-sync.json` sets `"uiGate": true` (a top-level
default, or the app's own); otherwise the consumer records it `required: false` with a
`notApplicableReason`. It passes on two scopes: the static scan's `ui-result` PASS, and a runtime
`ui-result` PASS for each page the change touched (at least one). Its status is the worst of
those results. Opt-in until 1.0.0, when `apexlang-delivery` defines the required gates.

## Aggregation

A task's status is the worst status among its **required** gates:
`FAIL > CONFLICT > UNKNOWN > BLOCKED > NOT_RUN > PASS`. No required gate at all is
`NOT_RUN`, never `PASS`. A gate is skipped only by recording it `required: false` with a
`notApplicableReason`; it is then `NOT_RUN`. The `verification-manifest` schema encodes this
rule both ways, so a manifest that claims a better or a worse status than its gates is
invalid.

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
  Nothing expires on a clock; the marker's 5 minutes are the hook's, not a result's.

## The orchestration contract

What a consumer — the future `apexlang-delivery`, a CI pipeline, an agent loop — may and
may not do. It orchestrates the gates; it adds no rule of its own (P2, P6).

**MUST**
- pass `--app <alias>` and `--task <id>` to every gate command, and read results only from
  that task's directory;
- validate each result against its schema before reading it — an invalid result is `UNKNOWN`;
- read a missing result — or one whose `context.timestamp` predates the command it just ran,
  left by an earlier run — as `BLOCKED` when the command exited 2, `UNKNOWN` otherwise;
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

Phase 3 brought UI/UX and Security as gates (both above). A new gate needs the
following — and changes none of the existing gates:

1. an owning skill and a producer — a script where possible, the agent where not;
2. a result schema in `schemas/` (experimental first), fixtures, and negatives that encode
   what its PASS requires;
3. its column in the table above, including what its PASS does **not** establish;
4. its place in the order, and whether it is required by default;
5. its name in the `verification-manifest` gate enum, and its result kind in that schema's
   `results[].kind` enum.
