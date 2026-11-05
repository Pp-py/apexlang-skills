# Changelog

## Unreleased

The changes of an external audit of 0.7.1, on branch `fix/audit-2026-11-04`: the aggregator reads
less than it used to trust, a seventh gate (Package) exists, and a set of recipes, criteria and
documents were corrected. Several behaviors change for the same inputs (below). Nothing here is
live-verified: every new script was tested with SQLcl and the browser stubbed, and the live
protocols (`tests/live/README.md` L6 and L7) are written, not run.

**Version classification is the owner's call.** `framework/CONTRACTS.md` says a change to the frozen
interface is a minor release (0.8.0); 0.7.1 shipped a `delivery.py` behavior change as a patch under
"Behavior changes". This section adds interface (new flag, script, config key, result path) and changes
what the same inputs produce, so it reads as a minor. No version was bumped and no tag made.

### Behavior changes — read before upgrading

**apexlang-delivery (`delivery.py`)**
- **`jsonschema` is required.** Without it, or without `framework/schemas/`, `delivery.py` stops
  `BLOCKED (NO_JSONSCHEMA)` / `BLOCKED (NO_SCHEMAS)`, exit 2, and writes no manifest. It no longer
  falls back to its own structural check, so the 0.7.1 sentence "Without `jsonschema`, nothing changes:
  the structural check runs" is no longer true. Who notices: a skill copied without `jsonschema` or
  without `framework/schemas/`, and any pipeline that ran `delivery.py` on a bare interpreter. Install
  with `apt install python3-jsonschema` or `python -m pip install jsonschema`. The manifest always
  writes `schemaCheck: "jsonschema"`; the stable schema's enum still lists `"structural"` so manifests
  written by 0.7.1 and earlier validate.
- **A result of another destination reads NOT_RUN, "misfiled".** A valid, fresh result whose
  `operation` (sync), `scope` (security, ui), `app.appAlias`, or, for sync, runtime, package and the
  runtime scopes of security and ui, `app.environment` (absent only without `--env`) or `app.appId`
  (compared only when both the result and `apex-sync.json` carry one) belongs to another destination
  used to be read as this destination's PASS. It is now NOT_RUN (exit 4; BLOCKED or UNKNOWN with
  `--exit`). Not compared: the architecture decision (it is the task's), static security and ui scopes
  (shared between environments), and the `runtimeUrl` host. This checks consistency, not authenticity:
  results are not signed.
- **`--page` is required under `uiGate`.** With `"uiGate": true`, `delivery.py --page <page>[:dialog]`
  (repeatable, once each) declares every page the change touched; `<page>` is the part of
  `ui-<key>-runtime-<page>.json`. With no `--page` the UI gate is NOT_RUN, naming how to declare pages,
  where one runtime ui-result PASS used to be enough whichever page it covered. The gate reads exactly
  that file, valid and fresh, and the result's own `runtimeUrl` must name that page, else NOT_RUN
  "misfiled". `:dialog` also needs `UX-DIALOG-FOCUS` PASS in it. Other `ui-<key>-runtime-*.json` files
  still count in the worst status. `--skip ui:<reason>` still skips the whole gate and wins over
  `--page`; there is no per-page skip and no manifest `scope`. A repeated or malformed `--page` stops
  `BLOCKED (BAD_PAGE)`.
- **`record-sync` is required by the Runtime gate.** Runtime now also reads
  `sync-<key>-record-sync.json` and cites both results in the manifest. A task that passed with
  `check-import` and a runtime result but no `record-sync` reads NOT_RUN (exit 4) on Runtime; so does one
  whose runtime verdict's `context.timestamp` is earlier than the `record-sync`'s (equal is in order, 1 s
  resolution; absent or unparseable is UNKNOWN), and one whose `record-sync` is of another operation,
  app, environment, task or tree. A `record-sync` run again after the walkthrough was written makes that
  verdict NOT_RUN: write it again. A task with no import needs `--skip runtime:<reason>` or a no-op
  `record-sync` (basis `builder-unchanged`). The Sync gate is unchanged (`check-import` alone), and
  `--exit runtime:<code>` and the single-result contrast now speak for `runtime-<key>.json` only. A
  `record-sync` PASS does not prove the import ran, nor tell it from an export.
- **Every manifest now lists the `package` gate**, between `validation` and `sync`: `required: false`,
  `excludedBy: "config"` with a reason, unless the app sets `packageGate`. A validator that uses a 0.7.x
  copy of `verification-manifest.schema.json` **rejects** these manifests (the `gate` enum gains
  `package`, `results[].kind` gains `package-result`, and `gate.excludedBy` is a new property under
  `additionalProperties: false`). Additive for the schema, not for a strict reader: update the copy with
  the plugin.
- **stderr.** `delivery: not evaluated: <gate> (<config|skip>), … - not a statement about them` is
  printed on every outcome and now names `package (config)` for each app without `packageGate`; a script
  that greps the old line must be updated. With no `apex-sync.json`, one more line says so
  (`apex-sync.json not found: Sync, Validation and Runtime cannot PASS; run apex-sync-check.sh apps`);
  status and exit code (4) are unchanged. The full opt-in profile is `packageGate`, `securityGate` and
  `uiGate` all `true` at the top of `apex-sync.json`.

**Other scripts and criteria**
- **`evidence.py write` refuses a contradictory `appId`.** A draft whose `app.appId` contradicts the one
  in `apex-sync.json` (the environment's over the app's) exits 2 and writes nothing; before, the draft's
  value overrode the config's and the result was written with a PASS that contradicted it. A draft
  `appId` is still kept when the config has none.
- **OO-2 is retired from `skills/apex-ux/oracle-owned.json`.** A dialog that fails only `focusReturns` on
  APEX 26.2 now gives `UX-DIALOG-FOCUS` FAIL; it was an advisory (`UX-ORACLE-OWNED`) and PASS. The
  version comparison stays exact (`26.2.0` does not match `26.2`). Who notices: the absences example and
  any app with the refresh-on-close dialog pattern (`apexafterclosedialog` refreshing the opener's region)
  can now FAIL intermittently on 26.2. A new entry in that list must cite a minimal reproduction with a
  negative control and the version measured. Not re-measured here.
- **`sec-probe.py --anon` reads APEX's error page as UNKNOWN.** The page that keeps the requested page id
  (class `a-Error-back` or `t-Alert-errorTitle`, a dialog URL with no session) used to read as FAIL (served);
  it is UNKNOWN until its HTML is measured. A served page with a hidden `#APEX_ERROR_MESSAGE` is still FAIL.
  Whether stock APEX serves that page for a dialog URL with no session is unmeasured.
- **`FORM-SOFT-DELETE` applies only to soft retention.** Retention is a decision declared in the
  `architecture-result` (a `rule` decision whose subject begins `retention:`); none means soft, as before.
  With a declared hard retention `FORM-SOFT-DELETE` is NOT_RUN and the new `FORM-HARD-DELETE` applies.
  `FORM-REFUSED-SUBMIT` and `MODAL-REFUSED-SUBMIT` now also require that the same form or dialog accepts
  the corrected values exactly once, and a submit control left disabled after a server error is a FAIL of
  `MODAL-REFUSED-SUBMIT`.
- **`BROWSE-FACET-COUNT` is redefined.** It compares the region's **total** (its own count text) with the
  SQL count of the predicate, for a facet value strictly between 0 and the baseline total and for an AND
  across two groups; rendered rows alone never satisfy it, and a page with no count text and more than one
  page of data is NOT_RUN. Before, "the count dropped" was enough.

### Added

- **The Package gate** (seventh gate; result kind `package-result`; owner apex-sentinel; opt-in per app
  with `packageGate`, top-level or per app, until 1.0.0). Order: Architecture → build → Validation →
  **Package** → Sync → import → `record-sync` → Runtime → Security → UI.
  `skills/apex-sentinel/scripts/pkg-check.py` (269 lines) reads the app's saved SQLcl connection with
  read-only `SELECT`s (`apex_applications`, `ALL_OBJECTS`, `ALL_ERRORS`, `ALL_PROCEDURES`,
  `ALL_SYNONYMS`) and looks up the packages and procedures an `.apx` names: `invokeApi` processes,
  workflow activities and named-notation calls inside sql/plsql code blocks. It never runs DDL or a
  recompile, and may read a `protected` environment. Criteria `PKG-EXISTS`, `PKG-COMPILED`,
  `PKG-PROC-EXISTS`; a PASS needs all three. Absent object or non-empty `ALL_ERRORS` is FAIL; INVALID
  with no visible error, a package not visible to the session user, a synonym (DB link included), an
  unresolved code-block call, a set `invoke.owner`, a remote `source.location`, an unknown `invoke.type`
  and a parsing schema the source changes are UNKNOWN; zero pairs is `BLOCKED (NO_PAIRS)`, an app not
  visible to the connection (a first import) `BLOCKED (APP_NOT_VISIBLE)`. Synonyms are not followed: a
  call to a shared or Oracle package by public synonym is UNKNOWN until `--skip package:<reason>`.
  `delivery.py` integrates it with the same identity table, `--skip package:<reason>` and
  `--exit package:<code>`. Docs: GATES.md (column, order, section), `checks/package.md`, the
  apex-sentinel and apexlang-delivery skills, setup.md. GAP-4 is **mitigated, not closed**: the SQL has
  never met an Oracle database (live L7 is written, not run).
- `framework/schemas/package-result.schema.json` (experimental, 105 lines). `apx.code_blocks()` (extracted
  from `plsql-scan.py`, same behavior) and `result.RE_CONN` in the core.
- **Recipe** `apexlang-architecture/recipes/attachments-to-package.md` (upload, replace, preview,
  download through the owning package; keep, replace, remove, cancel). Its two thin `executeCode`
  wrappers are **NOT VALIDATED** and recorded as KC-9 in `CAPABILITIES.md`. `back-end-conventions.md`
  §4 defines "Unit of work" once and the nine recipes that write state it in one line; §6 makes
  retention a declared decision. Two recipes gain one sentence each (`dashboard-kpis-charts`: a time
  series orders by the date key; `modal-crud-to-package`: re-enable a disabled submit on server errors).
  The recipes are now 14.
- **Criteria.** apex-sentinel: `MODAL-NO-SESSION` (a second, login-less `pw.sh` session),
  `DASH-CHART-ORDER` (a label that repeats or is not drawn is UNKNOWN), `FORM-HARD-DELETE`,
  `BROWSE-SEARCH-STATES`, `SPLIT-EMPTY-RETURN`, `SPLIT-PAGE-RECONCILES`, and the `PKG-*` ones. Each
  criterion about a feature the page lacks is recorded `required: false`, NOT_RUN, with a
  `notApplicableReason`. apex-ux, all ADVISE, no existing severity changed: `UX-NAME-LANGUAGE`,
  `UXDASH-CHART-SERIES`, `UXBRW-SEARCH-STATES`; `UX-FOCUS-VISIBLE` adds 3:1 (WCAG 1.4.11);
  `UX-REFLOW` and `UX-TARGET-SIZE` are clarified; three data-entry rows are marked "card text only".
  apex-security, ADVISE: `SEC-UPLOAD-SERVER-RULES`, and `SEC-DOWNLOAD-AUTHZ` extended to a stored file
  served per record.
- **Manual procedure** `skills/apex-ux/references/by-hand.md`: three read-only DOM snippets (reflow,
  accessible names, live regions) for `pw.sh eval`, plus a `run-code` wrapper for a dialog's iframe. The
  snippets ran once in a real Chrome through playwright-core against a local fixture; not through
  `pw.sh`, not on an APEX app. Reflow, focus contrast and accessible-name language remain unbuilt in
  `ux-check.py` (GAP-13).
- **Activation, documented.** apexlang-delivery has a step 0 "Preflight" (`apex-sync-check.sh apps`, then
  `doctor`; with no `apex-sync.json`, stop and ask for the values, never invent them); apex-sync-guard has
  a red flag for importing or exporting in a repo with no `apex-sync.json`. `setup.md` documents a
  permission `ask` rule on `delivery.py * --skip` as the authority for skipping a gate (P9). Live
  protocol L6 (activation, bounded to L6a/b/c, n = 3) and L7 (Package gate) in `tests/live/README.md`:
  written, not run.
- `framework/CAPABILITIES.md`: §Updating Oracle's skills (a six-step procedure that compares git trees
  with `git rev-parse <commit>:apex`), KC-9, GAP-11 to GAP-13, and Recorded runs rows. One of them records
  a read-only check made with network access on 2026-11-04: `apex/` is the same tree (`860fd38c`) at the
  lock `014cdb2` and at oracle/skills `0779f03`, 93/93 anchors at each, and the 12 newer commits touch only
  `oci/`. It is not the owner's verification of the lock: `oracle-skills.lock.json` is unchanged.

### Frozen interface: additions only

- `delivery.py --page <page>[:dialog]` (repeatable); new stop reasons `NO_JSONSCHEMA` and `BAD_PAGE`.
- New script `skills/apex-sentinel/scripts/pkg-check.py [--app <alias>] [--env <name>] [--task <id>]
  <file-or-dir>…`, exit 0 PASS · 1 FAIL · 2 BLOCKED · 3 UNKNOWN; environment variables `SQLCL_BIN` and
  `PKG_CHECK_TIMEOUT`.
- New config key `packageGate` (boolean, top-level default or per app), accepted by the readers of
  `apex-sync.json` that list keys (`sync-config.sh`, with a boolean check, and `pw.sh`); `result.py` needed no change.
- New result path `<evidenceDir>/<task>/package-<alias>[.<env>].json`, kind `package-result`.
- `verification-manifest` (stable): `gate` enum `package`, `results[].kind` `package-result`, the optional
  property `gate.excludedBy` (`config` | `skip`), and two rules appended at the end of `$defs/gate/allOf`
  (one for `excludedBy`, one for a Package PASS citing only a `package-result`), so the rule indexes the
  negatives cite did not move. The rule "a gate with its own producer PASSes on that producer's result
  file" now covers `package`. Optional properties and new rules only; see the first Behavior change for
  what a strict reader sees. `STATUSES` and `structural()` are gone from `delivery.py` (not interface).
- `CONTRACTS.md` also records `[.<env>]` in the result paths of sync and runtime, `evidence.py write`'s
  refusal, and `delivery.py`'s full usage line.

### Fixed

- **Documentary drift.** `PRINCIPLES.md` P8 says five minutes for the sync marker (the guard's TTL), and
  `surface.py` now fails a document that gives the marker another figure; P2 says `result.py` is the third
  reader that `config-parity.sh` holds equal (it still said "does not cover yet", which 0.7.1 had made false); `CONTRACTS.md` and `setup.md` carry `[.<env>]` in result
  paths and `_<ENV>` in the test-user variables; `README.md` and `setup.md` no longer say the hook "polices
  nothing" without `apex-sync.json` (it polices no import there, and can still refuse a `cd` to a path
  computed at run time); `tests/live/README.md` L2 says five rows, as `setup.md` §4 does; `README.md` says
  14 recipes.
- **The structural fallback passed 55 of 74 results (as measured in the audit) that the schemas reject** (a PASS manifest, exit 0),
  across all five result kinds, and rejected valid documents (a PASS with an optional criterion in FAIL, a
  criterion in BLOCKED or UNKNOWN). It is gone with the fallback.
- `delivery.py`'s Runtime hint names `apex-sync-check.sh record-sync` and says the walkthrough comes after it.
- Criteria text: `UXENT-BULK-SCOPE` cites WCAG 3.3.4 for the confirmation and keeps the count
  as a repo convention; `UXENT-WIZARD` also cites `recipes/wizard-multi-step.md`; `criteria/README.md` and the
  skill say `('x')` without a suffix is an implemented region.

### Tests and CI

- New suite `tests/integration/pkg-check.sh` (101 assertions) in the CI integration job, Ubuntu and
  Windows. The CI integration job installs `jsonschema` on both legs (apt on Ubuntu; pip into the
  interpreter the suites pick on Windows). `delivery.sh` replaces its structural-path cases with
  `NO_JSONSCHEMA` ones (a stub `jsonschema.py` next to the copied `delivery.py`) and exits 2 itself when
  `jsonschema` is missing.
- Measured on the working tree with `bash tests/contract/run.sh` and the integration suites that run
  outside it, all rc 0, 0 failed: sync-guard-e2e 343 (0.7.1: 325), pw-wrapper-smoke 67, config-parity 68
  (63), evidence 51 (45), arch-scan 11, ux-scan 9, ux-check 41 (30), sec-scan 15, plsql-scan 13, sec-probe 34
  (30), secrets-scan 8, pkg-check 101 (new), delivery 325 (64), ci-example 13; the contract tier's schemas,
  fixtures, negatives and emitted results 153 and `surface.py` 31. The 0.7.1 figures are the baseline
  recorded before the changes. `tests/contract/surface.py` gains checks for the marker minutes, the
  unit-of-work sentence, `page_name` parity between `ux-check.py` and `delivery.py`, `result.py`'s
  connection-name pattern, `delivery.py`'s and `pkg-check.py`'s usage in `CONTRACTS.md`, and recipes
  referenced by the skills.
- Fixtures and negatives: `package-result` (3 fixtures, 22 negatives), `partial.json`, `pass-package.json`
  and `pass-record-sync.json` for the manifest, `valid-package-gate` for config parity, an own-dialog
  fixture for `ux-check`, and `pkg-check/` canned rows. `sync-guard-e2e` gains cases for `packageGate` in the
  config readers; `evidence.sh` for the `appId` refusal; `sec-probe.sh` for the error page; `ux-check.sh` for OO-2.
- `tests/upstream/citations.md` gains 7 anchors (now 100); `verify-citations.sh` at the installed lock
  passes 100/100 (offline, 2026-11-05).

### Not verified

- Nothing in this section ran against a real SQLcl, APEX instance or Oracle database. The Package gate's
  SQL (L7), the activation of the gates by an agent (L6), the two attachments wrappers (KC-9), the
  `by-hand.md` snippets through `pw.sh`, and OO-2's cause on APEX 26.2 are unmeasured.
- GAP-11 (the UI gate trusts the caller's list of pages), GAP-12 (record-sync order is a timestamp, not an
  observation) and GAP-13 (no automatic reflow, focus-contrast or name-language probe) are declared, not closed.

## 0.7.1 — 2026-10-14

A documentary audit of 0.7.0, and the decisions it forced. No gate changes its rules; one
behavior changes (see below). Nothing here moves a schema from experimental to stable.

### Behavior changes — read before upgrading

- **apexlang-delivery: missing schemas BLOCK instead of crashing.** With `jsonschema` installed,
  a missing `framework/schemas/` made `delivery.py` raise `KeyError` and exit 1 (FAIL). It now
  stops with `BLOCKED (NO_SCHEMAS)` and exit 2; a missing schema for one result kind is
  `BLOCKED (NO_SCHEMA)`. Without `jsonschema`, nothing changes: the structural check runs.

### Dependencies, declared

- **The framework core is a declared dependency.** apex-ux, apex-security, apexlang-architecture
  and apexlang-delivery import `framework/lib/`; apex-sentinel saves its results through
  `framework/scripts/evidence.py`; apexlang-delivery reads `framework/schemas/` when `jsonschema`
  is installed. Only apex-sync-guard runs alone.
- **Install units** (`framework/README.md` §Dependencies): the whole repo; or a skill plus the core
  in the same layout (`skills/` and `framework/` as siblings); or a symlink with the repo in place.
  A skill copied out without the core fails on import. The dependency itself is kept: copying
  `lib/` into each skill would duplicate what P2 keeps single.
- `README.md`: "installs the three skills", "three capabilities" and "each skill works on its own"
  were out of date or wrong; they now say six skills, and which skills need the core.

### The framework's third reader of `apex-sync.json` is tested

- `framework/lib/result.py` reads `apex-sync.json` for `evidenceDir`, the alias and environments.
  `tests/integration/config-parity.sh` held only the guard and `pw.sh` equal; it now also holds
  `result.py` equal on alias, environment, testUser and runtimeUrl, over the valid fixtures. A
  control with `result.py` broken fails it.

### Frozen interface: what 0.7.0 added

- The frozen interface (`framework/CONTRACTS.md`, now headed 0.7.x) gained, in 0.7.0 and without
  a line in its CHANGELOG: `ux-scan.py`, `ux-check.py`, `sec-scan.py`, `plsql-scan.py`,
  `secrets-scan.py`, `sec-probe.py`, `delivery.py`, `evidence.py capture --gate validation`.
  Additions only; nothing was removed or renamed.

### Documentation corrected

- `framework/CONTRACTS.md`: the capability contract table covers all six skills; "Phase 3" removed
  from the present tense; `environments` added to the configuration keys.
- **Stable and experimental, stated once.** `CONTRACTS.md` said an experimental schema stays so
  "until its producer is a script", while `ui-result` and `security-result` already have scripts as
  producers. The rule now says a schema becomes stable when its gate is required by default (1.0.0).
  The four experimental results keep that status.
- `framework/CAPABILITIES.md`: no open conflicts, and the KC rows read 0.7.0 (not "unreleased").
- `framework/GATES.md`: the UI opt-in sentence no longer waits for a delivery change that exists.
- `AGENTS.md`: the UI gate runs after Security, as the order in GATES says.
- `framework/PRINCIPLES.md`: P2 names `result.py` as the third reader; P7 says that
  `FLOW_WRAPS_ONE_ENTITY` is judged by the agent, not scanned by `arch-scan.py`.
- `framework/schemas/security-result.schema.json`: the description called the scans "later"; the
  scopes are named as they are.
- Requirements: Python 3 for the scripts of the four skills, and the browser for `ux-check.py` and
  `sec-probe.py`.

### Not in this release

- `docs/examples/ci/apexlang-static-gates.yml` still pins `ref: v0.7.0`: it moves to the v0.7.1 tag
  once that tag exists.
- `arch-scan.py` still has no `--help`: it reads `--help` as a path.
- The fixtures under `tests/contract/fixtures/` keep their historical `frameworkVersion` (0.6.x) on
  purpose: they are recorded results, not current ones.

## 0.7.0 — 2026-10-13

Closes Phase 3. Six skills now: `apex-security` and `apexlang-delivery` join the four, and every
gate of the loop writes a JSON result the orchestrator reads. UX-5: the UI gate. apex-ux's two scripts now write a `ui-result`, and the gate takes its
place after Runtime, opt-in per app. SEC-1 to SEC-6 build the Security block: a fifth skill,
`apex-security`, with its criteria; scans of the `.apx`, the packages and the tracked files, and
runtime probes, each writing a `security-result`; and the Security gate between Runtime and UI.
R-2 closes the last three known conflicts (KC-4, KC-5, KC-7): the examples compile. R-3 turns
four of Architecture's red flags into a script. R-4 writes the two results an agent judged by
hand until now. R-7 closes GAP-7 (worktrees) and GAP-8 (stale results). R-6 binds
the sync marker to the source it checked (GAP-9) and halves its TTL. R-1 models environments per
app (GAP-6). R-8 runs all of it against a live APEX 26.2 and fixes what that found. D-1 adds the
sixth skill, `apexlang-delivery`, the orchestrator the Phase 2 contracts were written for.

### Behavior changes — read before upgrading

**apexlang-delivery (new skill) — D-1**
- `skills/apexlang-delivery/`: the loop for one task — each gate run by the agent with its own
  skill, in `GATES.md`'s order, the import lane (Validation → `check-import` → import → `record-sync`,
  each step only on the previous one's exit 0) — and `scripts/delivery.py`, which reads what the
  task holds and writes `<evidenceDir>/<task>/manifest.json`. Each result is validated (jsonschema
  when installed, else its own checks — the manifest's new `schemaCheck` says which) and must be
  fresh; invalid → UNKNOWN, missing or stale → NOT_RUN; Security and UI are required only on
  opt-in; `--skip <gate>:<reason>`; stderr names the next gate or where to stop. Exit 0 PASS ·
  1 FAIL/CONFLICT · 2 BLOCKED · 3 UNKNOWN · 4 NOT_RUN.
- D-4: a pipeline example, `docs/examples/ci/apexlang-static-gates.yml` — copy it into a
  project: on each pull request it runs the five static scans at a pinned release and uploads
  their results; the gates that need SQLcl, the Builder or a browser stay in the agent's loop.
  Not active in this repository.
- D-3: `delivery.py --exit <gate>:<code>` — a gate that just ran and left no fresh result is
  `BLOCKED` (exit 2) or `UNKNOWN`, and a single producer whose exit disagrees with its result is
  `UNKNOWN` (GATES.md's MUST). **`verification-manifest` is stable** (its producer is a script);
  the other results stay experimental. Conformance tests of the orchestration contract, rule by rule.
- D-2: who runs each gate, with which command and what it leaves in the task dir, in the skill.
  GAP-3 (no Validation before Oracle's deploy script) is **mitigated, not closed** — by the
  documented lane and the manifest's required Validation gate; an import outside the lane still
  goes unvalidated (the user chose documentation over a script).
- `evidence.py capture --gate validation`: the compiler's output, and beside every capture a
  `<name>.exit.json` with the command (redacted), its exit code, the task and the working tree.

**R-8: what a live APEX 26.2 found** (recorded in `CAPABILITIES.md`, 2026-10-13)
- **apexlang-architecture — page processes run at `processing`, not `afterSubmit` (KC-8).** In
  APEXlang `afterSubmit` is the Builder's *After Submit* point, before computations and
  validations: the examples' and recipes' package calls ran before the page's validations. The
  editable-IG recipe claimed its per-row binds exist only at `afterSubmit`; measured, they work at
  `processing`, PK and version write-back included. **If you copied a recipe, move its processes.**
- **apexlang-architecture — examples:** the sectors IG declares `htmlDomId: sectors` (what
  `apex.region('sectors')` finds); the absences IR declares its primary saved report, which APEX
  otherwise creates on first render — the guard then saw a Builder change nobody made (UP-7).
- **apex-sync-guard:** the hook blocked an import naming an app with environments by its id
  (`-id`) as "not declared exactly once" — an R-1 bug, fixed. `doctor` asks SQLcl to validate
  the source and fails when it cannot read its APEXlang version (SQLcl 26.2.0 cannot read what
  APEX 26.2 exports: UP-2). `SKILL.md`: export into an empty dir — SQLcl writes `_1` copies
  beside existing files, and `-overwrite-files` keeps files the Builder dropped (UP-5).
- **apex-sentinel:** `pw.sh login` asks the server before trusting the page it holds: an app
  import ends every session, and it handed back a dead one (UP-8).
- **apex-security:** `sec-scan.py` reads `pageAccessProtection` and Session State Protection by the
  app's `mmdVersion`: a page that leaves the first out is checksummed from 26.2 and unrestricted
  in 26.1 (unknown version → 26.1); an app with no `sessionStateProtection` block has it enabled.
  Only `enabled: false` fails `SEC-APP-SSP` now — a 26.2 export read as 7 FAILs before.
  `sec-probe.py` gives its control the held session, reads APEX's error page under the requested
  page id as a refusal (UP-6) and a control on one as UNKNOWN, decodes modal links for `--tamper`,
  keeps a cookie jar for `--anon`, and reads the low-privilege password from the `.env` too.
- **apex-ux:** `UX-ORACLE-OWNED`, an advisory: a finding in markup APEX itself renders, listed per
  APEX version in `oracle-owned.json` (OO-1: the IG grid view's `aria-required-children` on 26.2;
  OO-2: focus return after Tab cycles in APEX's modal on 26.2). Anything else still FAILs.
  `ux-scan.py` no longer reads a report's print formatting (`page`, `pageHeader`, … groups) as an
  inline colour.
- **`--env` everywhere R-1 missed it:** `ux-check.py` and `sec-probe.py` take `--env` (required for
  an app with environments); results are keyed `<alias>.<env>`; the low user's password
  `APEX_TEST_PASSWORD_LOW_<ALIAS>_<ENV>` comes first.
- **framework:** `evidence.py` also strips the session id from `p_context=`, `p_instance=`,
  `session%3D` and APEX's `pageSubmissionId`. `result.runtime_target()` is the one rule for
  "an app with environments names one". Docs: the marker's TTL is 5 minutes (GATES, CONTRACTS
  and `setup.md` still said 10).

**apex-ux**
- `ux-scan.py` and `ux-check.py` print a **`ui-result`** (`framework/schemas/ui-result.schema.json`,
  experimental) instead of the provisional JSON. `reason` is now `reasons[{code, message}]`;
  findings cite `path` (repo-relative) instead of `file`; `--raw` is cited in `evidence[]` with its
  sha256 instead of `raw`. The exit codes are unchanged.
- Both take `--app <alias>` and `--task <id>`. With `--task` the result lands in
  `<evidenceDir>/<task>/ui-<alias>-static.json` or `ui-<alias>-runtime-<page>.json`, and axe's raw
  output in `raw/ui-<alias>/`. `--task` with several apps and no `--app` is BLOCKED.
- `ux-scan.py` on a file outside the repository is BLOCKED: a result cites repo-relative paths only.
- `ux-check.py` drops the session from the page URL instead of masking it, so the URL validates as
  `runtimeUrl`. An opener not found while another criterion FAILs is reported as FAIL with both.
  A message passed on from `pw.sh` has the repo root shortened to `<repo>` and the home dir to `~`.

**apex-sync-guard**
- **Environments per app (GAP-6, R-1).** An app may declare `environments` — as many as the
  project uses, each with its own `sqlclConnection` and optionally `appId`, `runtimeUrl`,
  `testUser` and `protected`. Gates then need `--env` (BLOCKED without it); each environment has
  its own syncpoint, markers and results, keyed `<alias>.<env>` (`refs/apex-sync/rrhh.dev`); the
  hook reads the environment from the saved connection a command names and blocks one naming
  none. `protected: true` blocks every agent import or export into that environment. An app
  without `environments` works as before. `sync-result` carries `app.environment`, and its
  `syncpoint.ref` pattern admits `<alias>.<env>`.
- **Fixed: the tree hash (R-6, R-7) could name a file's old content.** It copied the index with a
  fresh mtime, and git judges an entry "racily clean" by the index's mtime: a file rewritten, same
  size, in the second the index was written was hashed from its stale stat data. Reproduced and
  now a regression test; the copy keeps the index's mtime (`cp -p`, `shutil.copy2`). The likely
  cause of an intermittent e2e failure (a check whose end hash differed from its start hash
  withheld its marker), seen about once in six runs on `main` after R-6.
- **The marker is bound to the LOCAL its check compared (GAP-9, R-6), and lapses in 5 minutes
  instead of 10.** A check hashes the app's source dir (tracked and untracked files, through a
  copy of the index) when it starts and again when it writes the marker — a LOCAL edited while
  the Builder exported gets no marker (UNKNOWN). The hook hashes it once more before an import
  or an export and blocks on any difference: an edit, a new file, a capture undone. Markers
  written by an earlier version carry no hash and block: run the check again. The hand-made
  marker in `setup.md` §4's sandbox now names the empty tree.
- **Linked worktrees work (GAP-7, R-7).** The syncpoint (`state.json`) moves to the shared git dir,
  next to the shared ref; the markers and last results stay per worktree, under
  `.git/worktrees/<name>/apex-sync/`. A check authorizes an import only from the worktree whose
  LOCAL it compared, and the hook refuses hand-written state there too. In a plain clone every
  path is the same `.git/apex-sync/` as before: nothing to migrate.
- `sync-result` records `context.repo.tree` (below); `marker.path` names the worktree's marker.

**apex-sentinel**
- `pw.sh --env <name>`: an environment's own runtime, test user, browser workspace and
  `APEX_TEST_PASSWORD_<ALIAS>_<ENV>`.

**framework**
- `evidence.py --env <name>`: required for a runtime result on an app with environments; files
  keyed `<alias>.<env>`, `app.environment` in the result. `result.target(..., env)` merges an
  environment's settings.
- **Every result records the working tree it judged (GAP-8, R-7):** `context.repo.tree`, a git
  tree hash of tracked and untracked files (ignored ones left out), hashed through a copy of the
  index. Optional in the schema, so older results still validate — and read as stale.
  `evidence.py fresh --task <id> <result>…` says whether a result still speaks for now (another
  task, a changed file, no tree → stale). Nothing expires on a clock.
- **`framework/scripts/evidence.py` (R-4): the runtime and architecture results are no longer
  hand-written.** `capture` runs a step and saves its output under `raw/<gate>-<alias>/`,
  redacted, printing the evidence entry with its sha256. `write` takes the agent's draft (what it
  observed, no status), adds the envelope, re-hashes every cited file, derives the status by the
  schema's rules and writes `runtime-<alias>.json` or `architecture.json`. It refuses a draft with
  a status, a PASS without evidence, a changed or outside file, or a field holding a password or a
  connect string (naming the field, never the value). Standard library only: the schemas are
  checked in CI, not on the user's machine.
- `framework/lib/` holds what the scans share: `apx.py`, the `.apx` reader, now with quoted
  component names (`file "icons/x.png" (`) and one `is_destructive` for UX and Security; and
  `result.py`, the result envelope, was `skills/apex-ux/scripts/ui_result.py`. The capture variable
  of the contract tier is `RESULT_CAPTURE_DIR`. `plsql.py`, the PL/SQL lexer, moved out of
  `plsql-scan.py` for `arch-scan.py` to share.
- **The UI gate** (`GATES.md`): owner apex-ux, after Runtime. It passes on the static result PASS
  and a runtime result PASS for each page the change touched. It is required for an app whose
  `apex-sync.json` sets `"uiGate": true` (top-level default or per app), opt-in until 1.0.0.
- `verification-manifest`: gate `ui` and result kind `ui-result`; a `ui` PASS cites at least two
  `ui-result` files.
- `apex-sync.json` takes `uiGate` (a boolean; anything else is BLOCKED). The guard and `pw.sh`
  accept it per app; neither acts on it.

**apex-security (new skill) — Phase 3, SEC-1 to SEC-6**
- A fifth skill, `skills/apex-security/`: a threat model, what a Security PASS does not establish
  (it is not a pentest), and 22 criteria with IDs in `criteria.md` — `FAIL` only for what a
  machine can establish (authorization on every page and destructive action, public pages
  declared, page and item checksums, escaping, safe URLs, bound SQL, no secrets; four runtime
  probes), `ADVISE` for the rest. Sources: Oracle's 26.1 security policies (14 new anchors in
  `citations.md`) and OWASP ASVS 5.0. Scans, probes and the `security-result` gate: SEC-2 to SEC-6.
- `apex-sync.json` takes `publicPages` (an array of page numbers) and `lowPrivUser` (a string),
  read by apex-security; the guard and `pw.sh` accept them per app and check their types.

- **Static scan (SEC-2):** `skills/apex-security/scripts/sec-scan.py [--app] [--task] <app-dir>`
  checks nine static `FAIL` criteria over the `.apx`. They are page authorization, public pages
  declared in both places, page checksums, application SSP, item SSP, column escaping, escaped
  substitutions, safe URLs, and destructive actions under a role scheme. It also reports the
  session advisories. Its output is a **`security-result`** (`framework/schemas/`, experimental),
  brought forward from SEC-6 so the format never changes later.
- **Package scan (SEC-3):** `plsql-scan.py [--app] [--task] <dir>` covers the packages and the
  `.apx` SQL blocks. `SEC-SQL-BIND` FAILs on a value concatenated into dynamic SQL, even under a
  review comment. It also FAILs on a dynamic text it cannot trace to literals or `DBMS_ASSERT`,
  unless a `-- dynamic sql review: <reason>` comment approves it, which is Oracle's "unless
  explicitly approved". `SEC-AUTHID` is an advisory. The output is a `security-result` with
  `scope: plsql`.
- **Runtime probes (SEC-4):** `sec-probe.py [--anon <url>]… [--tamper] [--role <url>]…
  [--xss <token>]`, run through `pw.sh` and written as a `security-result` with `scope: runtime`.
  A refusal is read from `#pFlowStepId` against a control: the test user loading the same URL. A
  broken control is UNKNOWN. Each probe:
  - **anonymous:** a plain HTTP fetch with no cookie;
  - **tamper:** the first `cs=` link, in a new tab;
  - **role:** the app's `lowPrivUser` in its own session, password only through the environment;
  - **XSS:** the agent stores a payload, and the probe checks how it renders.
  `pw.sh` is unchanged, and its runner now lives in `framework/lib/pw.py`, shared with `ux-check.py`.
- **Secrets scan (SEC-5):** `secrets-scan.py [<path>…]` runs over git's tracked files by default
  and writes a `security-result` with `scope: secrets`.
  - It finds a tracked `.env`, wallets and key stores, private keys, passwords or tokens
    assigned a literal, connect strings with credentials, and GitHub/AWS/Slack tokens.
  - A finding gives the file, line and kind, never the value.
  - Placeholders pass. An exception needs `secrets-scan: allow <reason>`; a bare `allow` excuses
    nothing.
  - This repository passes; the two fake passwords in `pw-wrapper-smoke.sh` are marked.
- **The Security gate (SEC-6):** in `GATES.md`, owner apex-security, after Runtime and before UI
  (`… → Runtime → Security → UI`). It passes on four `security-result` PASSes (static, plsql,
  secrets, runtime) and is required for an app with `"securityGate": true` (opt-in until 1.0.0).
  `verification-manifest`: gate `security`, kind `security-result`, a `security` PASS cites at
  least four. `apex-sync.json` takes `securityGate` (a boolean).
- `SEC-ACTION-AUTHZ` now needs a role scheme (`@<static-id>`) on the action or its page:
  `mustNotBePublicUser` does not count, because every page already requires it.
- Run over Oracle's own 26.1 scaffold, the scan finds its Home page without an
  `authorizationScheme` (recorded in `CAPABILITIES.md`).

**apexlang-architecture**
- **`scripts/arch-scan.py`: the red-flag scan (R-3).** It finds `AUTOMATIC_ROW_PROCESSING`,
  `DML_IN_PAGE_PROCESS`, `FLOW_ISSUES_DML` and `NO_VERSION_TOKEN` in `.apx` pages and PL/SQL
  packages, with comments and literals masked, and prints JSON with each flag's path and line
  (exit 0/1/2/3). An `executeCode` page process without `-- thin wrapper:` is an advisory
  (`THIN_WRAPPER_UNMARKED`), never a flag. `RULE_OUTSIDE_PACKAGE`, `FOREIGN_TABLE_WRITE` and
  `FLOW_WRAPS_ONE_ENTITY` stay the agent's review (`references/decision-record.md`).
- **An `UPDATE` with no version token says why:** `-- lost update review: <reason>` on its line
  or the line above (`back-end-conventions.md` §7); the three `pkg_absences` transitions carry it.
- **Page processes call packages through `invokeApi` (KC-4, resolved).** The rule is now the
  majority of Oracle's policies, not "either": `invokeApi` by default; a thin `executeCode` wrapper
  only for an Interactive Grid save, a loader that assigns page items, or a branch-gated flow, with
  its first line `-- thin wrapper: <reason>` and no business logic. The examples' seven package
  calls and the recipes' snippets are rewritten (`save-sector` in the modal recipe is now
  `create-sector` + `update-sector`); `SKILL.md`, `PRINCIPLES.md` P1 and `official-standard.md` say so.
- **The example packages carry the version token (KC-5, resolved)** — signatures changed:
  `pkg_employees.update_row(…, p_row_version, p_hired_on)`, `pkg_employees.delete_row(p_employee_id,
  p_row_version)`, `pkg_sectors.update_row(…, p_row_version IN OUT)`, `pkg_sectors.delete_row(p_sector_id,
  p_row_version)`, `pkg_sectors.save_row(…, p_row_version IN OUT)`. A stale save raises
  `pkg_errors.k_row_changed` with §7's one sentence. The pages carry `row_version` back (`P41_/P42_ROW_VERSION`,
  the IG's hidden `ROW_VERSION`). `pkg_absences` needs none, and the README says why.
- **The examples compile (KC-7, resolved).** The 7 errors were ours: breadcrumb regions now use the
  theme's `@/title-bar` template and are named after the page (Oracle's lint asks it, and so does
  `UX-TITLEBAR-NAME`); the drawer's Cancel (`definedByDynamicAction`) drops `warnOnUnsavedChanges`.
  SQLcl 26.2.0 `apex validate`: `Validation successful`. New upstream issue UP-4: Oracle's
  `invokeApi` template omits `value.type`, which an IN parameter needs to compile.
- **The example packages state `AUTHID DEFINER`** (`pkg_errors`, `pkg_sectors`, `pkg_employees`,
  `pkg_absences`), as do the snippets in `back-end-conventions.md` and `package-boundaries.md`.
- **The examples' destructive actions are under a role scheme.** Delete employee and Reject
  absence, button and process, carry `authorizationScheme: @administration-rights`, the scheme
  Oracle's scaffold ships; your app supplies it or names its own (examples README §Security).
- **The examples now meet Oracle's security baseline.** Every example page declares
  `security { authorizationScheme: mustNotBePublicUser, pageAccessProtection:
  argumentsMustHaveChecksum }`. The hidden and key items (`P41_/P42_SECTOR_ID`,
  `P62_ABSENCE_ID`) carry `sessionStateProtection: checksumRequiredSessionLevel`. Oracle's
  security lint had never run on them: `validate-examples.sh` staged the app outside an
  `applications/` directory, and Oracle's validator applies its business-app rules only under one.
  It now does, and reported the 8 gaps this fixes.

### Tests
- D-4: `tests/integration/ci-example.sh` (13) in CI — the example's scan step, read from the
  file and run as written over the examples; a planted defect fails it.
- D-3: `delivery.sh` (+23): the orchestration contract rule by rule; 11 fail without `--exit`.
- D-1: `tests/integration/delivery.sh` (40) in CI; the contract tier validates every manifest it
  makes `delivery.py` write (jsonschema there, its own checks on the integration runners).
- R-8: e2e (+5: an app with environments named by id, `doctor`'s SQLcl check), `sec-probe.sh`
  (+10: APEX's error page, a control on one, the cookie loop, the `.env` and per-environment low
  password, `--env`), `ux-check.sh` (+8: `oracle-owned.json`, `--env`), `sec-scan.sh` (+3: 26.1 and
  26.2 defaults), `ux-scan.sh` (print formatting near-miss, a chart's colour), `evidence.sh` (+2:
  the session forms of a submit). Each new case fails without its fix.
- R-1: e2e (+21), config-parity (+16: one valid fixture with environments, three both readers
  refuse), the `pw.sh` smoke (+8), `evidence.sh` (+7).
- e2e (+15): GAP-9 — edit after the PASS, undo, a new file, an edit outside the source, export,
  an older marker, an edit during the check, setup.md §4's five rows and its sandbox marker.
- e2e (+11): a check and the hook in a real linked worktree; the guard's `tree` equals the one
  `git add -A` gives through a copy of the index. `evidence.sh` (+9): freshness.
- `tests/integration/evidence.sh` (27) in CI; the contract tier validates every result it makes
  the script write, and `surface.py` freezes both usages.
- `tests/integration/arch-scan.sh` (11) in CI: near-misses, `fail.expected`, unparsed files, the
  examples. `surface.py` freezes its usage. Recorded runs over the examples and Oracle's three
  example apps in `CAPABILITIES.md`.
- Citations: 5 new anchors for KC-4, KC-7 and UP-4 (93/93). The lint and the compiler runs on the
  examples are recorded in `CAPABILITIES.md`; CI has no SQLcl.
- Contract: the manifest's Security gate in the PASS fixture, 2 negatives (three scopes, another
  gate's result); the e2e covers `securityGate` (+2).
- `tests/integration/secrets-scan.sh` (8) in CI. Its secrets are assembled at run time, so the
  test file holds none. Contract: 2 secrets fixtures, 2 negatives.
- `tests/integration/sec-probe.sh` (20) in CI: each probe's mapping, a failing control, the low
  password kept out of argv and output, redaction. Contract: 2 runtime fixtures, 1 negative.
- `tests/integration/plsql-scan.sh` (13) in CI; contract: 2 `plsql` fixtures, 3 negatives, and
  every result it emits.
- `tests/integration/sec-scan.sh` (12): fixtures with near-misses, `fail.expected`, `publicPages`
  per app, `--task`, the examples. Contract: the `security-result` schema, 2 fixtures, 8 negatives,
  and every result `sec-scan.sh` makes the script emit.
- `validate-examples.sh` stages under `applications/`, so Oracle's security rules run on the
  examples. `surface.py` checks the apex-security criteria with the same rules as apex-ux's. The
  e2e covers `publicPages` and `lowPrivUser` (+3).
- Contract: the `ui-result` schema, two fixtures and twelve negatives. It also runs `ux-scan.sh` and
  `ux-check.sh` with `RESULT_CAPTURE_DIR` and validates every `ui-result` they make the scripts
  emit; that check caught a home path in a BLOCKED message, now fixed.
- `surface.py`: the keys an app takes are the same in the guard and in `pw.sh`; `framework/lib/result.py`
  reports the release's version; the frozen interface lists the apex-ux scripts.
- `ux-scan.sh` (+2) and `ux-check.sh` (+3) cover `--task` and path scrubbing; the e2e covers
  `uiGate` (+3). A real-browser run with `--task` is recorded in `CAPABILITIES.md`.

### Upgrading from 0.6.1
1. Update the plugin (`claude plugin marketplace update apexlang-toolkit-marketplace`, then
   `claude plugin update apexlang-toolkit@apexlang-toolkit-marketplace`, per scope), and Oracle's
   skills to the revision in `framework/oracle-skills.lock.json` (014cdb2).
2. Run `apex-sync-check.sh doctor` in each project. On APEX 26.2 it now asks SQLcl to read the
   source's APEXlang version: SQLcl 26.2.0 cannot (UP-2), 26.3.0 can.
3. Markers written by 0.6.1 carry no tree hash and block: run the checks again. Nothing in the
   syncpoints or `apex-sync.json` needs migrating; an app that adopts `environments` starts each
   one from its first `check-import` (or keeps its syncpoint by the user's own `git update-ref`,
   `setup.md` §1).
4. If you copied a recipe, move its page processes from `afterSubmit` to `processing` (KC-8).
5. On Windows, Git Bash needs a `python3` that runs (the Microsoft Store stub does not) for the
   apex-ux, apex-security, evidence and delivery scripts.

### Rollback
Reinstall 0.6.1 (`5d0382b`) or disable the plugin. Results written by 0.7.0 (`context.repo.tree`,
`app.environment`, `<alias>.<env>` file names) are not read back by 0.6.1; drop the task dirs.
An app with `environments` must go back to one connection per app. The tag `v0.7.0` marks this
release.

## 0.6.1 — 2026-10-11

Phase 3, UI/UX points 1 to 4. The UI known conflicts with Oracle's 26.1 policies are resolved:
the recipes, `ui-contracts.md` and the examples follow Oracle's rules, and the report rules were
measured against both Oracle tools instead of being assumed. A fourth skill, `apex-ux`, judges a
page's UI against criteria with IDs, with a static scan over `.apx` and runtime checks in the
browser. The UI gate (`ui-result`, UX-5) is not in this release.

### Behavior changes — read before upgrading

**apexlang-architecture**
- **Row-dependent styling comes from a closed set** (`ui-contracts.md` §2, was KC-1). A Cards
  region's `card.cssClasses` and a report badge take one of Oracle's six classes (`u-normal`,
  `u-hot`, `u-info`, `u-success`, `u-warning`, `u-danger`) or `NULL`, returned whole by a `CASE`
  with an `ELSE`. Template-component badges take `success|warning|danger|info`. A class is never
  composed (`u-&STATE.`, `'u-color-' || …`, `u-color-#X#-text`). Avatar colours come from the
  component (`applyThemeColors`).
- **Navigation is a declarative target** (§3, was KC-3). `behavior.target` / `link.target` name
  the page and the items; the query projects only the key. No `apex_page.get_url(...)` column
  mapped into a target.
- **Metric Card drill-down** (`recipes/dashboard-kpis-charts.md`, was KC-2). The card's own
  `position: link` action applies only when every card opens the same page with its own key.
  Otherwise the drill-down is a header action or a neighbouring report.
- **Report links go on a column of `type: link`**, on Interactive Reports too (was KC-6). SQLcl's
  compiler requires that form and rejects `plainText` + `link {}`, which the recipes used before.
  Oracle's lint forbids it on an IR (`INTERACTIVE_REPORT_LINK_COLUMN_TYPE_FORBIDDEN_001`, now a
  documented diagnostic), and the compiler wins (P6). The compiler enforces neither
  `REPORT_SQL_HTML_LITERAL_FORBIDDEN_001` nor `REPORT_REGION_LINK_BLOCK_UNSUPPORTED_001`. This
  skill keeps both as its own rules.
- The absences example renders its status as `t-Badge` plus a semantic class, so the sentinel
  walkthrough and `checks/workflow-state.md` read `td span.t-Badge`.

**Boundary between apexlang-architecture and apex-ux**
- `apexlang-architecture` states what the data layer projects, the write path and the link's form;
  `apex-ux` judges the UI and cites those rules instead of restating them. Presentation moved to
  `apex-ux`: `ui-contracts.md` §6 (custom CSS) and §7 (contextual detail actions) are now pointers
  (numbering kept), and the formatting, colour-alone, help-text and delete-confirmation prose in the
  recipes points to the criterion IDs.
- The UX Pattern Catalog is an example, not an authority, in `SKILL.md` and
  `references/official-standard.md` too (version aligned to 26.1.6).
- `recipes/analytical-report.md`: the boolean icons are named by visually hidden text; the old text
  claimed a `title` on an `aria-hidden` glyph names it, which it does not.
- `UXBRW-LINK-COLUMN` keeps only the link text; `UXDET-READ-ONLY-RAIL` no longer restates the write
  path.

**apex-ux (new skill)**
- Runtime checks (Phase 3, UX-4): `skills/apex-ux/scripts/ux-check.py` runs on the page `pw.sh`
  holds. It uses axe-core 4.13.0, vendored unchanged under MPL-2.0 in `skills/apex-ux/vendor/` and
  pinned by sha256 in `axe-core.lock.json`; a missing or altered engine is BLOCKED. Covers
  `UX-AXE-SERIOUS`, the runtime half of `UX-ITEM-NAME` and `UX-CONTROL-NAME`, and `UX-DIALOG-FOCUS`
  per `--dialog` opener. Stdout never carries node HTML or a session id. Covered by
  `tests/integration/ux-check.sh` in CI.
- Static scan (Phase 3, UX-3): `skills/apex-ux/scripts/ux-scan.py`, python3 stdlib only. It checks
  the five static `FAIL` criteria over `.apx` files and prints JSON per criterion with file and line
  (provisional format until UX-5); exit 0/1/2/3. A file it cannot parse is UNKNOWN, never PASS.
  Covered by `tests/integration/ux-scan.sh` in CI (fixtures plus the examples, which pass).
- A fourth skill for UI quality and accessibility (Phase 3, UX-2): 71 criteria with IDs in
  `skills/apex-ux/criteria/`. They cover every page (`UX-*`) plus the archetypes: dashboards,
  browse and search, item details, data entry and workflow. Each criterion has a severity
  (`FAIL` only for what a machine can establish), how it is verified (static, runtime, manual)
  and its source: WCAG 2.2 AA, Oracle's 26.1 policies (anchored in `citations.md`), Universal
  Theme.
- Oracle's UX Pattern Catalog is cited as an example only; the skill never needs a catalog
  instance. A UI PASS is never "WCAG compliant".
- Measured against its own `FAIL` criteria, the repo had two defects. The icon-only report links in
  the recipes and the absences example had no accessible name; they now carry visually hidden text
  (`u-VisuallyHidden`). The absences example's Reject button had no confirmation; it now asks.
- Not built yet: the `ui-result` gate (UX-5). Until then the scripts' JSON is a provisional
  format, and no gate or manifest reads it.

### Tests
- `tests/contract/surface.py` checks every apex-ux criterion row: a unique, prefixed ID, a
  severity, a method (a FAIL is never manual) and a source.
- `tests/upstream/probe-ui-rules.sh [--lint|--compiler]` runs probe pages through Oracle's lint
  and SQLcl. Probe 706 is a negative control the compiler must reject.
- Under the compiler the examples go from 9 errors to 7 (KC-7: the scaffold's breadcrumb
  template and `warnOnUnsavedChanges`).

### Rollback
Reinstall 0.6.0 (`3e77cbf`) or disable the plugin. Nothing in `apex-sync.json`, the syncpoints,
the markers or the result schemas changed; the frozen interface (`framework/CONTRACTS.md`) is
untouched. Rolling back drops `apex-ux` and the recipe changes above, nothing else.

## 0.6.0 — 2026-10-09

The three skills become one system: an **engineering framework** (`framework/`) on top of
Oracle's official APEXlang skills — principles, contracts, gates, evidence and a capability
matrix — with fail-closed gates that leave JSON results. Oracle restructured its skills into
a version router (`apex@oracle-skills`: 26.1 and 26.2); this release follows it and pins the
verified revision (`framework/oracle-skills.lock.json`).

### Behavior changes — read before upgrading

**apex-sync-guard**
- `apex-sync-check.sh` exits **3 (UNKNOWN)** when a run starts and cannot reach a verdict — an
  export or snapshot that fails part-way, an interrupt, a crash after the PASS line. Nothing is
  authorized; re-run. (Before, some of these exited 0.)
- New **BLOCKED** cases (exit 2), each naming its fix: an invalid `apex-sync.json` (validated as a
  whole, every error listed — `doctor` shows them); `deployments/default.json` naming another app
  id; an app invisible through the connection while a syncpoint exists (a first publication is
  only taken without one — the message names the escape, which is the user's); `record-sync`
  without a basis (a fresh `check-import` PASS, an unchanged Builder, or LOCAL equal to the
  Builder) — `--force` is the user's override; a missing source dir for `check-export`.
- With several apps in `apps[]`, every gate command needs `--app <alias>`.
- A check that does not PASS withdraws the marker of its direction — also when it stops before
  it begins (a bad option, no SQLcl, an invalid config; with `--app` missing, for every app).
- `check-export` sees untracked files even under `status.showUntrackedFiles=no`.
- A CONFLICT prints `CONFLICT:` instead of `FAIL:`.
- **Hook:** it now also gates Oracle's `deploy-apex-app.sh`, `apexctl` validate-and-import, SQLcl's
  short forms (`apex imp -i …`, `apex exap -api …`) and any `apex import` with a SQLcl launcher in
  the command; it refuses `record-sync --force` and writes to the guard's markers, refs and state
  even with a fresh marker; any failure after it sees a relevant command blocks; with several apps
  it requires the check of the app each invocation acts on — one that names its app no longer
  vouches for another in the same command. It refuses a command that reaches another onboarded
  repo than the session's (a `cd` into it, a path into it: from a session outside any onboarded
  repo these passed unchecked), a `cd` to a directory computed at run time, and a `sql -name`
  that is not the connection the app was checked through. A mention without an option
  (`grep -i "apex import"`) still passes.

**apex-sentinel**
- `pw.sh` keeps its browser in a **new workspace**, private and per project and app
  (`${TMPDIR:-/tmp}/apex-sentinel-<uid>/<repo>-<app>-<crc>`) — **log in once again** after upgrading.
- `pw.sh login` succeeds only when APEX reports the test user as `APP_USER`. A landing page, an
  anonymous session, another user's session — and SSO, social or custom schemes, which cannot be
  verified this way — are refused (exit 2) instead of assumed.
- A call that had to reopen a dead browser exits **3**: what it printed describes a logged-out page.
- With several apps, browser calls take `pw.sh --app <alias> …`; passwords may be per app
  (`APEX_TEST_PASSWORD_<ALIAS>`).
- Changing `PW_INSECURE_TLS` now rewrites the TLS config — refused while a browser launched with the
  old setting is open (`pw.sh close-all` first). `last-url` no longer keeps the session token;
  `close-all` deletes the session's snapshots.
- A leaked `ORA-` prefix is a FAIL of the friendliness criterion, never a pass with a note.

**Tests and tooling**
- `PKG=…` is gone: point the upstream tier at Oracle's skills with `APEXLANG_ROOT=<path>/apex/apexlang`
  (or install `apex@oracle-skills`). Tests live in tiers: `tests/{contract,integration,upstream,live}`.

### Added
- `framework/`: PRINCIPLES (P1–P10), CONTRACTS (statuses, Oracle's signals mapped, results, the
  frozen interface), GATES (four gates, aggregation, freshness, the orchestration contract a future
  `apexlang-delivery` follows), EVIDENCE, CAPABILITIES (matrix by APEXlang version, KC/UP/GAP).
- JSON Schemas: `sync-result` (stable) — written by the guard on every run, `--task <id>` for an
  evidence copy under `evidenceDir` (`.apex-evidence/`, ignored by default); `runtime-result`,
  `architecture-result`, `verification-manifest` (experimental); criterion IDs in every check.
- Several apps per repo (`apps[]` with top-level defaults); `apex-sync-check.sh apps` and
  `pw.sh apps` print what they resolved; one config reader shared by the check and the hook.
- `references/` in each skill (progressive disclosure) and a Contract block atop each `SKILL.md`.
- Tests: the contract tier (schemas; 65 negatives, each proven to be rejected by the one rule it
  names; every emitted result; the docs surface), the config-parity test, the hook's python
  lane, Windows (Git Bash) in CI.

### Fixed
- A type error in `apex-sync.json` (a non-string `testUser`) was silently ignored.
- A PASS whose marker could not be written still exited 0; it is UNKNOWN (exit 3) now.
- Result redaction could rewrite a relative path holding the repo root's letters, and missed
  the `C:/…` form of a Windows home; it now rewrites only where a path begins, in both forms.
- Multi-app tracing compared the session's logical cwd with git's physical root, so it blocked
  legitimate commands under a symlinked dir (macOS `/var`) or Git Bash (`/tmp` vs `C:/…`).
- Slow on Windows. Under Git Bash every process costs tens of milliseconds, and the scripts
  spawned them by the dozen — a grep per pattern, an awk per config key, a `cmp` per file. The
  hook clears a command that mentions apex in 0.14 s (0.43 s in 0.5.0) and decides an `apex
  import` in 0.35 s (0.71 s); a check compares the files both replicas hold in one `git hash-object` call,
  so check-import on a 200-file app in sync takes 2.8 s, not 43 s (SQLcl stubbed: a real
  export adds its own time); `pw.sh` reads `apex-sync.json` without an awk per key.
- The upstream tier no longer reports a pass for a run that did not happen; the lint and the
  compiler are separate lanes, and the lint is advisory.
- Docs no longer claim what was not true: "the official `apex` skill", "apex validate-green
  examples" (they pass Oracle's lint; the compiler rejects them — KC-7), "drives a 3-way merge".

### Known conflicts with Oracle 26.1 (2026.09.21)
KC-1 card state classes · KC-2 Metric Card drill-down · KC-3 declarative navigation targets ·
KC-4 `invokeApi` vs a thin `executeCode` wrapper (interim: both satisfy the single write path) ·
KC-5 the examples' version token · KC-6 report rules are lint-level · KC-7 the examples vs the
compiler. Upstream: UP-1 locale-dependent compile verdict · UP-2 SQLcl 26.2.0 refuses 26.2 apps ·
UP-3 the deploy script does not validate. Details and workarounds: `framework/CAPABILITIES.md`.

### Upgrading from 0.3.0
1. Install Oracle's skills (`/plugin marketplace add oracle/skills`, `/plugin install apex@oracle-skills`),
   then update this plugin.
2. Run `skills/apex-sync-guard/scripts/apex-sync-check.sh doctor` in each project: a config the old
   version tolerated may now be BLOCKED, and the output says how to fix it.
3. Log in again with `pw.sh login` (new workspace); if the app uses SSO or a custom scheme, verify
   by hand — `pw.sh` now refuses what it cannot verify.
4. Read the new BLOCKED cases above before the first import: each is a situation in which the old
   version would have let an import through.
5. In between, 0.3.1–0.5.0 added the PowerShell matcher, the parameterised test user, the read-side
   recipes and checks, the package-boundaries procedure and the version-token convention (below).

### Rollback
Reinstall 0.5.0 (`7376825`, tag `v0.5.0`) or 0.3.0 (`5560aef`), or disable the plugin. Syncpoints
and markers keep their format, and what 0.6.0 adds (`.git/apex-sync/<alias>/last-*.json`,
`.apex-evidence/`, new keys in `state.json`) is ignored by older versions. **One exception:** an
`apex-sync.json` that uses `apps[]` is not understood before 0.6.0 — keep the one-app shape in any
project that may roll back.

## 0.5.0 — 2026-09-03
Three read-side recipes (item detail, browse on an interactive report, multi-step wizard; 13 in
all); item defaults declared once in shared components. After it, unreleased until 0.6.0: the
package-boundaries procedure (which package owns an operation), the version token on every write
path, four PL/SQL defects fixed in recipes and examples, and the sync guard's first-publication
path and option-requiring hook.

## 0.4.0 — 2026-09-03
The read-side contract (`ui-contracts.md`), form-page and split-view recipes grounded in Oracle's UX
catalog, sentinel checks for forms, split views and browse pages, the `employees-form` slice.

## 0.3.1 — 2026-08-10
The hook's matcher covers the PowerShell tool; apex-sentinel's login takes a parameterised test user.

## 0.3.0 — 2026-08-06
First versioned release: the three skills aligned with Oracle's official APEXlang skill.
