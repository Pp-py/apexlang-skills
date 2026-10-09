# Gates

A gate is a check a change must pass, with one owner and one producer. Each states what
its PASS establishes **and what it does not** — reading more into a PASS than its gate
establishes is how "validate passed" turns into "it works" (P5).

## The four gates

| | Architecture | Validation | Sync | Runtime |
|---|---|---|---|---|
| **Owner** | apexlang-architecture | Oracle (`apexlang-compile`) — consumed, not reimplemented | apex-sync-guard | apex-sentinel |
| **Producer** | the agent | `validate-apex-app.sh` | `apex-sync-check.sh` | the agent, through `pw.sh` |
| **Checks** | every write has one owning package; every rule sits where procedures A/B put it; the source carries no red flag | the `.apx` compiles for that APEXlang version | `check-import`: the Builder holds no work the import would destroy · `check-export`: LOCAL holds no uncommitted work the export would destroy | the archetype's pass criteria, on the running page, as the verified test user, with the data side read back through SQLcl |
| **PASS establishes** | the design of this change, each decision tied to the code that implements it | grammar and component properties are valid for that SQLcl + APEXlang pair | for this app, through this connection, the operation destroys nothing — for 10 minutes | the change does what its recipe promises, for every required criterion exercised |
| **PASS does NOT establish** | that anything compiles, renders or is synchronized | that the PL/SQL compiles or the packages it calls exist; anything at runtime; anything the 26.1 lint says | that the import's payload is right (it is reported, not judged); other apps; other environments; that the Builder stays untouched afterwards | criteria not exercised; other pages; security; performance |
| **Evidence** | `architecture-result`: decisions with evidence, the red-flag scan's command | the script's command, exit code and output (`Validation successful`) | `sync-result`: the export, the comparison, changes, payload; the marker | `runtime-result`: per criterion, evidence files (sha256) and SQL |
| **Statuses** | PASS · FAIL · BLOCKED · UNKNOWN | PASS · FAIL · BLOCKED | PASS · FAIL · CONFLICT · BLOCKED · UNKNOWN | PASS · FAIL · BLOCKED · UNKNOWN |
| **Holds back** | building the change | the import | `apex import`/`export`, the deploy script, `apexctl` roundtrip | any "it works" claim |
| **Enforced by** | discipline | nothing on the deploy lane — Oracle's deploy script does not validate (GAP-3) | the `PreToolUse` hook (Claude Code); discipline elsewhere | discipline |

## Order

```text
Architecture → build (.apx + package) → Validation → Sync → import → record-sync → Runtime
```

Sync goes last before the import because it is the perishable one: its PASS lapses in 10
minutes and is void the moment LOCAL changes again. `record-sync` right after the import
is part of the import, not an optional step — skipping it poisons the next comparison.
Runtime comes after the import because it measures what the Builder now serves.

## Aggregation

A task's status is the worst status among its **required** gates:
`FAIL > CONFLICT > UNKNOWN > BLOCKED > NOT_RUN > PASS`. No required gate at all is
`NOT_RUN`, never `PASS`. A gate is skipped only by recording it `required: false` with a
`notApplicableReason`; it is then `NOT_RUN`. The `verification-manifest` schema encodes this
rule both ways, so a manifest that claims a better or a worse status than its gates is
invalid.

## Freshness

- A sync **marker** authorizes for 10 minutes, and is withdrawn when the next check of that
  direction starts — a FAIL never leaves an earlier PASS standing.
- A **result** is fresh for the task named in its `context.task`, at the revision in its
  `context.repo`. Read for another task, or after the inputs it judged changed, it is stale:
  the consumer records `NOT_RUN`, not the old status.

## The orchestration contract

What a consumer — the future `apexlang-delivery`, a CI pipeline, an agent loop — may and
may not do. It orchestrates the gates; it adds no rule of its own (P2, P6).

**MUST**
- pass `--app <alias>` and `--task <id>` to every gate command, and read results only from
  that task's directory;
- validate each result against its schema before reading it — an invalid result is `UNKNOWN`;
- read a missing result as `BLOCKED` when the command exited 2, `UNKNOWN` otherwise;
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
- import or export without the Sync gate's `PASS` for that app and direction in the last
  10 minutes;
- deploy to an environment the user did not name.

## Adding a gate

Phase 3 brings Security and UI/UX as gates. A new gate needs, and changes nothing else:

1. an owning skill and a producer — a script where possible, the agent where not;
2. a result schema in `schemas/` (experimental first), fixtures, and negatives that encode
   what its PASS requires;
3. its column in the table above, including what its PASS does **not** establish;
4. its place in the order, and whether it is required by default;
5. its name in the `verification-manifest` gate enum.
