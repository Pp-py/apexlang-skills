# Changelog

## Unreleased

Phase 3, UX-5: the UI gate. apex-ux's two scripts now write a `ui-result`, and the gate takes its
place after Runtime, opt-in per app. SEC-1 and SEC-2 open the Security block: a fifth skill,
`apex-security`, with its criteria and a static scan that writes a `security-result`.

### Behavior changes — read before upgrading

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

**framework**
- `framework/lib/` holds what the scans share: `apx.py`, the `.apx` reader, now with quoted
  component names (`file "icons/x.png" (`) and one `is_destructive` for UX and Security; and
  `result.py`, the result envelope, was `skills/apex-ux/scripts/ui_result.py`. The capture variable
  of the contract tier is `RESULT_CAPTURE_DIR`.
- **The UI gate** (`GATES.md`): owner apex-ux, after Runtime. It passes on the static result PASS
  and a runtime result PASS for each page the change touched. It is required for an app whose
  `apex-sync.json` sets `"uiGate": true` (top-level default or per app), opt-in until 1.0.0.
- `verification-manifest`: gate `ui` and result kind `ui-result`; a `ui` PASS cites at least two
  `ui-result` files.
- `apex-sync.json` takes `uiGate` (a boolean; anything else is BLOCKED). The guard and `pw.sh`
  accept it per app; neither acts on it.

**apex-security (new skill) — Phase 3, SEC-1 and SEC-2**
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
- `SEC-ACTION-AUTHZ` now needs a role scheme (`@<static-id>`) on the action or its page:
  `mustNotBePublicUser` does not count, because every page already requires it.
- Run over Oracle's own 26.1 scaffold, the scan finds its Home page without an
  `authorizationScheme` (recorded in `CAPABILITIES.md`).

**apexlang-architecture**
- **The examples' destructive actions are under a role scheme.** Delete employee and Reject
  absence, button and process, carry `authorizationScheme: @administration-rights`, the scheme
  Oracle's scaffold ships; your app supplies it or names its own (examples README §Security).
- **The examples now meet Oracle's security baseline.** Every example page declares
  `security { authorizationScheme: mustNotBePublicUser, pageAccessProtection:
  argumentsMustHaveChecksum }`. The hidden and key items (`P41_/P42_SECTOR_ID`,
  `P62_ABSENCE_ID`) carry `sessionStateProtection: checksumRequiredSessionLevel`. Oracle's
  security lint had never run on them: `validate-examples.sh` staged the app outside an
  `applications/` directory, and Oracle's validator applies its business-app rules only under one.
  It now does, and reported the 8 gaps this fixes. The compiler still reports the same 7 errors
  (KC-7).

### Tests
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
