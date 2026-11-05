# GAP-14 — identity of the attempt and the producer (proposed design, 2026-11-05)

Status: **proposal, not built.** It needs the owner's decision on the points in "Decisions needed". The
frozen interface (`framework/CONTRACTS.md`) allows additions only; everything below is additive.

## What is built, what is left

Built (PR #38): an optional `context.runId` written by every producer from `APEX_RUN_ID` (and into
Validation's `.exit.json`), and `delivery.py --run <id>`: a result of another run, or none, is `NOT_RUN`
(stale). Fail-closed backstop: a gate whose command exited non-zero is never PASS.

Left, from the 2026-11-05 reviews (reports 08 and 09):

1. **Exit codes speak for the whole gate.** `--exit security:2` cannot say which of the four scopes (or which
   UI page) failed. The aggregator can only turn an all-PASS gate into UNKNOWN.
2. **A retry that dies before writing leaves the earlier result of the same run.** A producer that crashes or
   times out leaves its previous file in the task dir. With the same `runId` it still reads as fresh.
3. **A reused id is not detected.** Two attempts under one id are indistinguishable.

## Design

### A. A producer key (answers 1)

The producer of a result is already named by its file: `security-<alias or key>-<scope>.json`
(`scope` ∈ static, plsql, secrets, runtime), `ui-<alias>-static.json`, `ui-<key>-runtime-<page>.json`,
`package-<key>.json`, `sync-<key>-<op>.json`. Define the **producer key** as the part after the gate:
`security/runtime`, `ui/runtime-orders`. No new field in the results.

`delivery.py --exit <gate>[/<producer>]:<code>` (additive; the gate-only form keeps today's meaning):

- `security/runtime:2` with that scope's result PASS → that result reads UNKNOWN, naming the producer; the
  other scopes keep their own verdicts.
- The same producer FAIL keeps FAIL; a producer with no result and a non-zero exit reads UNKNOWN (BLOCKED for 2),
  as the gate-level form does today.
- An unknown producer key → BLOCKED `BAD_EXIT`, naming the producers that gate has.

### B. A result is claimed before it is made (answers 2)

At start, a producer that writes into a task dir moves its own destination file to `<name>.prev` and writes
the new one atomically at the end. A producer that dies leaves no current file, so the gate reads `NOT_RUN`
("not in the task"), never the previous attempt. `.prev` is evidence, never read by `delivery.py`.

Cost: every producer touches its output path twice, and `evidence.py capture` must do the same for the
capture and its `.exit.json`. Behavior changes only for a producer that did not finish.

### C. An id used once (answers 3)

`delivery.py` records in the manifest the `runId` and, per cited result, its `timestamp`. A second
`delivery.py --run R` whose results are older than the first manifest of `R` for that task reads `UNKNOWN`
("run R was already aggregated; start a new run"). This detects reuse after aggregation, not before it.
Detection before aggregation would need a run registry; not proposed.

## Compatibility

- No schema change: `--exit` and the manifest gain nothing the schemas forbid (the manifest's `gates[].results[]`
  already cite each file). The only new surface is the `<gate>/<producer>` syntax, the `.prev` file and the
  `BAD_EXIT` message.
- Without `--run` and without a producer-qualified `--exit`, behavior is unchanged except B.
- `negatives.json` rules are cited by index: no new `allOf` rule is needed.

## Tests (negatives first)

- `--exit security/runtime:2`: runtime PASS → UNKNOWN naming `security/runtime`; static PASS stays PASS.
- `--exit ui/runtime-billing:1`: only billing's page reads UNKNOWN.
- A bad producer key → BLOCKED `BAD_EXIT`.
- B: a producer killed after start leaves no current result; `delivery.py` reads NOT_RUN, not the old PASS.
- C: a second aggregation of the same run id over older results → UNKNOWN; a new id → normal.

## Decisions needed

1. Producer key syntax: `gate/producer` (proposed), or a separate flag.
2. B changes every producer's write path: accept it, or limit it to the Security and UI producers (the
   multi-producer gates) first.
3. C: detect reuse after aggregation only (proposed), or build a run registry.
4. Version: this and #38 change flags under 0.7.1 Unreleased; 0.8.0 per `CONTRACTS.md`, or a patch.

## Not covered

An identity per producer *instance* (two concurrent runs of one producer) and cross-machine runs.
