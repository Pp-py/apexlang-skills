# Changelog

## Unreleased

Phase 3, UX-1: the UI known conflicts with Oracle's 26.1 policies are resolved. The recipes,
`ui-contracts.md` and the examples follow Oracle's rules, and the report rules were measured
against both Oracle tools instead of being assumed.

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

### Tests
- `tests/upstream/probe-ui-rules.sh [--lint|--compiler]` runs probe pages through Oracle's lint
  and SQLcl. Probe 706 is a negative control the compiler must reject.
- Under the compiler the examples go from 9 errors to 7 (KC-7: the scaffold's breadcrumb
  template and `warnOnUnsavedChanges`).

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
