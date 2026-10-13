# Changelog

## Unreleased

Phase 3, UX-5: the UI gate. apex-ux's two scripts now write a `ui-result`, and the gate takes its
place after Runtime, opt-in per app. SEC-1 to SEC-6 build the Security block: a fifth skill,
`apex-security`, with its criteria; scans of the `.apx`, the packages and the tracked files, and
runtime probes, each writing a `security-result`; and the Security gate between Runtime and UI.
R-2 closes the last three known conflicts (KC-4, KC-5, KC-7): the examples compile. R-3 turns
four of Architecture's red flags into a script. R-4 writes the two results an agent judged by
hand until now. R-7 closes GAP-7 (worktrees) and GAP-8 (stale results). R-6 binds
the sync marker to the source it checked (GAP-9) and halves its TTL. R-1 models environments per
app (GAP-6). R-8 runs all of it against a live APEX 26.2 and fixes what that found.

### Behavior changes — read before upgrading

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
