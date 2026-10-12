# Capabilities

What is verified, on which Oracle APEXlang version, and where the proof is. A cell says
`yes` only with a link to evidence; `not recorded` means no run is on file — not that it
fails; `KC-n`, `UP-n` and `GAP-n` point to the tables below.

Verified against Oracle's skills at the revision in [`oracle-skills.lock.json`](oracle-skills.lock.json).

## Matrix

| Capability | APEXlang 26.1 | APEXlang 26.2 | Proof |
|---|---|---|---|
| **Oracle** generation, policies, local lint (`apexlang-generation`) | yes | no — not shipped for 26.2 | upstream router ([citations](../tests/upstream/citations.md)) |
| **Oracle** compile (`validate-apex-app.sh`) and deploy (`deploy-apex-app.sh`) | yes | yes | [citations](../tests/upstream/citations.md) (both scripts, both versions) |
| **Oracle** `apexctl runtime verify-ui` | opt-in, HTML fetch only | no | [citations](../tests/upstream/citations.md) |
| Architecture: single write path, package boundaries, recipes | yes | not recorded | the skill; §Known conflicts |
| UI rules the recipes state (report links, markup in SQL, Cards classes, declarative targets) under Oracle's lint and the compiler | yes — measured on probe pages | not recorded | §Recorded runs; [probe-ui-rules](../tests/upstream/probe-ui-rules.sh) |
| Architecture: red-flag tokens exist in Oracle's inventory | yes | yes | [citations](../tests/upstream/citations.md) (the 3 auto-row-processing process types, both versions) |
| Examples under Oracle's local lint | yes — only the documented diagnostics | n/a | §Recorded runs; [expected-diagnostics](../tests/upstream/expected-diagnostics.txt) |
| Examples under the compiler | yes — `Validation successful` | no — UP-2 | §Recorded runs |
| Sync gate: check-import / check-export / record-sync, markers, sync-result | yes (version-independent) | yes (version-independent) | [e2e](../tests/integration/sync-guard-e2e.sh) and [contract](../tests/contract/run.sh) in CI, SQLcl stubbed |
| Sync gate against a live Builder | not recorded | not recorded | — |
| Hook lanes: `apex import`/`export` and short forms, deploy script, `apexctl` roundtrip | yes | yes (deploy lane; 26.2 has no `apexctl`) | [e2e](../tests/integration/sync-guard-e2e.sh) |
| Several apps per repo (`apps[]`) | yes | yes | [e2e](../tests/integration/sync-guard-e2e.sh), [config-parity](../tests/integration/config-parity.sh), [smoke](../tests/integration/pw-wrapper-smoke.sh) |
| Runtime gate: `pw.sh` (verified login, per-app workspaces, TLS, exit 3) | yes (version-independent) | yes (version-independent) | [smoke](../tests/integration/pw-wrapper-smoke.sh) in CI, Playwright CLI stubbed |
| Runtime walkthroughs against a live app | not recorded | not recorded | — |
| runtime-result / architecture-result / verification-manifest | experimental — fixtures and negatives only | same | [contract](../tests/contract/run.sh) |
| Environments per app (`environments`, `--env`, `protected`) in the guard, the hook, `pw.sh` and `evidence.py` | yes (version-independent) | same | [e2e](../tests/integration/sync-guard-e2e.sh), [config-parity](../tests/integration/config-parity.sh), [smoke](../tests/integration/pw-wrapper-smoke.sh), [evidence](../tests/integration/evidence.sh) in CI |
| Sync marker bound to the source it checked (GAP-9), TTL 5 min | yes (version-independent) | same | [e2e](../tests/integration/sync-guard-e2e.sh) in CI; cost on Git for Windows recorded below |
| Worktrees: the guard's state split between the shared git dir (syncpoint) and each worktree's (markers, results) | yes (version-independent) | same | [e2e](../tests/integration/sync-guard-e2e.sh) in CI, a real `git worktree` |
| Result freshness: `context.repo.tree` in every result, `evidence.py fresh` | yes (version-independent) | same | [evidence](../tests/integration/evidence.sh) and the e2e: the guard and `result.py` record the same tree |
| Runtime and architecture results written by `evidence.py` (derived status, re-hashed evidence, redaction) | yes (version-independent) | same | [evidence](../tests/integration/evidence.sh) in CI; every result it writes validated in the [contract tier](../tests/contract/run.sh) |
| Architecture red-flag scan (`arch-scan.py`): Automatic Row Processing, DML in a page process, DML in a `_flow`, an `UPDATE` with no version token | yes (version-independent) | same | [arch-scan](../tests/integration/arch-scan.sh) in CI: near-misses, `fail.expected`, the examples; the other three red flags stay the agent's review |
| UX criteria catalog (`apex-ux`): IDs, severity, method, source | yes — version-independent; Oracle sources cited at 26.1 | same | [contract](../tests/contract/run.sh) (format), [citations](../tests/upstream/citations.md) (Oracle anchors) |
| UI static scan (`ux-scan.py`): the five static FAIL criteria | yes (version-independent) | same | [ux-scan](../tests/integration/ux-scan.sh) in CI, over fixtures and the examples |
| UI runtime checks (`ux-check.py`): axe-core 4.13.0 pinned, dialog focus | yes (version-independent) | same | [ux-check](../tests/integration/ux-check.sh) in CI, Playwright CLI stubbed; real browser: §Recorded runs |
| UI gate (`ui-result`, `uiGate` opt-in) | yes (version-independent) | same | schema, fixtures and negatives in the [contract tier](../tests/contract/run.sh); every `ui-result` the ux suites emit validated there |
| Security criteria (`apex-security/criteria.md`), threat model | yes (version-independent; Oracle's security lint is 26.1 only) | same | `surface.py` checks every criterion row; the examples pass Oracle's security lint (below) |
| Security static scan (`sec-scan.py`, `security-result`) | yes (version-independent) | same | [sec-scan](../tests/integration/sec-scan.sh) in CI: fixtures, near-misses and the examples; schema, fixtures and negatives in the contract tier |
| Security package scan (`plsql-scan.py`): dynamic SQL, `AUTHID` | yes (version-independent) | same | [plsql-scan](../tests/integration/plsql-scan.sh) in CI: near-misses, `fail.expected`, `.apx` blocks, the examples |
| Security runtime probes (`sec-probe.py`): anonymous, checksum, role, XSS | yes (version-independent) | same | [sec-probe](../tests/integration/sec-probe.sh) in CI: Playwright CLI stubbed, a local HTTP server for the anonymous fetch |
| Security secrets scan (`secrets-scan.py`) over tracked files | yes (version-independent) | same | [secrets-scan](../tests/integration/secrets-scan.sh) in CI: planted secrets in a scratch repo, and this repository itself |
| Security gate (`security-result`, `securityGate` opt-in) | yes (version-independent) | same | schema, fixtures and negatives in the [contract tier](../tests/contract/run.sh), the manifest's four-scope rule included; every `security-result` the suites emit validated there |
| Windows (Git Bash) | yes — integration on `windows-latest` in CI | same | [ci.yml](../.github/workflows/ci.yml); first green 0.6.0 run: [38059670802](https://github.com/Pp-py/apexlang-skills/actions/runs/38059670802) |

## Recorded runs

What CI does not run, recorded when it was run. Re-run after updating Oracle's skills.

| Date | Command | Environment | Outcome |
|---|---|---|---|
| 2026-10-10 | `tests/upstream/verify-citations.sh` | oracle/skills `014cdb2` (the lock) | PASS — 41/41 anchors current |
| 2026-10-10 | `tests/upstream/validate-examples.sh --lint` | `apexlang-generation` 26.1, release 2026.09.21, at `014cdb2` | PASS — only the four documented diagnostics |
| 2026-10-10 | `SQLCL_BIN=… tests/upstream/validate-examples.sh --compiler` | SQLcl 26.2.0.181.2110 (Windows, from WSL), Oracle's 26.1 scaffold | FAIL — 9 compile errors (KC-7) |
| 2026-10-10 | `tests/upstream/verify-citations.sh`, after the UI conflicts were fixed | oracle/skills `014cdb2` (the lock) | PASS — 48/48 anchors current |
| 2026-10-10 | `tests/upstream/validate-examples.sh --lint`, same | same | PASS — the five documented diagnostics (the IR column `type: link` added) |
| 2026-10-10 | `SQLCL_BIN=… tests/upstream/validate-examples.sh --compiler`, same | SQLcl 26.2.0.181.2110 (Windows, from WSL), Oracle's 26.1 scaffold | FAIL — 7 compile errors (KC-7); the page-60 IR link errors are gone |
| 2026-10-10 | `tests/upstream/probe-ui-rules.sh --lint` | `apexlang-generation` 26.1 at `014cdb2` | PASS — the lint rejects the region-level IR link, `type: link` on an IR column and HTML in report SQL |
| 2026-10-10 | `SQLCL_BIN=… tests/upstream/probe-ui-rules.sh --compiler` | SQLcl 26.2.0.181.2110 (Windows, from WSL), Oracle's 26.1 scaffold | PASS — the compiler accepts all three and the Cards/Metric Card shapes, and rejects only the negative control (IR `plainText` column with `link {}`) |
| 2026-10-10 | `tests/upstream/verify-citations.sh`, with the apex-ux criteria's anchors | oracle/skills `014cdb2` (the lock) | PASS — 75/75 anchors current |
| 2026-10-10 | the three `tests/integration/` suites | bash 3.2.57 — macOS's bash, not in CI (docker `bash:3.2` with git, jq, python3) | PASS — e2e 262, smoke 59, config-parity 44 |
| 2026-10-11 | `ux-check.py --dialog '#open-good' --dialog '#open-bad'` on `tests/integration/fixtures/ux-check/page.html`, served on 127.0.0.1 | `@playwright/cli` 0.1.17, bundled Chromium (`PLAYWRIGHT_MCP_BROWSER=chromium`, WSL), axe-core 4.13.0 | FAIL as built — `label` and `button-name` (critical) on the page; the good dialog holds focus, the bad one fails all five steps |
| 2026-10-11 | `ux-check.py` on Oracle's UX Pattern Catalog (an example app, public, read only): home, dashboards, browse-search, item-details, data-entry-simple-form; data-entry with `--dialog 'text=Data Entry - Drawer Form'` | same, the catalog 26.1.6 on the user's lab instance | PASS on every page and the drawer, three runs alike. A first version reported the drawer's focus as escaping: it compared against the last `role=dialog` node, which APEX adds more of while tabbing — fixed by marking the dialog that opened |
| 2026-10-11 | `ux-check.py --task T-smoke` on the catalog's data-entry-simple-form, from a scratch repo with `apex-sync.json` (one app) | `@playwright/cli` 0.1.17, bundled Chromium (WSL), axe-core 4.13.0 | PASS — `ui-catalog-runtime-data-entry-simple-form.json` and the raw axe output (cited by sha256) in the task dir, `.gitignore` created; the URL without its session; the result validates against `ui-result` |
| 2026-10-11 | `tests/upstream/validate-examples.sh --lint`, the app staged under `applications/` so Oracle's business-app rules run | `apexlang-generation` 26.1 at `014cdb2` | before the examples' fix: FAIL — 8 security diagnostics (`SECURITY_BASELINE_REQUIRED_001` ×5, `HIDDEN_ITEM_SSP_REQUIRED_001` ×3) the old staging path never let run; after it: PASS, only the five documented diagnostics |
| 2026-10-11 | `SQLCL_BIN=… tests/upstream/validate-examples.sh --compiler`, the examples with their `security` blocks | SQLcl 26.2.0.181.2110 (Windows, from WSL) | FAIL as before — the same 7 errors (KC-7), none from the security properties |
| 2026-10-11 | `sec-scan.py` over Oracle's 26.1 scaffold (`templates/base-app-structure/scaffold-example`, copied into a scratch repo) | `apexlang-generation` 26.1 at `014cdb2` | FAIL, as found — `SEC-PAGE-AUTHZ` on `p00001-home.apx`: the scaffold's Home page has no `authorizationScheme`, which Oracle's own baseline requires of every non-login page. Every other criterion PASS (`SEC-APP-SSP` included); the parser first could not read `file "…" (` in `static-files.apx`, now fixed |
| 2026-10-11 | `sec-scan.py` over `skills/apexlang-architecture/examples` | — | FAIL at first: four destructive actions (Delete employee, Reject absence: button and process) under no role scheme. Fixed with `@administration-rights` (the scaffold's scheme); PASS, `SEC-APP-SSP` NOT_RUN (no `application.apx`); lint PASS, compiler the same 7 errors (KC-7) |
| 2026-10-11 | `plsql-scan.py` over `skills/apexlang-architecture/examples` | — | PASS on `SEC-SQL-BIND` (no dynamic SQL); four packages without `AUTHID` (advisory) — now `AUTHID DEFINER`, stated |
| 2026-10-11 | `sec-probe.py --anon <home> --tamper` on Oracle's UX Pattern Catalog (lab, public by design, read only) | `@playwright/cli` 0.1.17, bundled Chromium (WSL) | FAIL, as it must on a public app — `SEC-ANON-REDIRECT`: page 1 served with no login; `SEC-CHECKSUM-TAMPER` NOT_RUN on four pages (no `cs=` link) |
| 2026-10-11 | `sec-probe.py --tamper` and `--xss` on a local page that imitates APEX's checksum check (127.0.0.1) | same | tamper PASS when the target checks `cs`, FAIL (both variants) when it does not; XSS PASS on escaped text, FAIL on markup. The first run found that `run-code`'s sandbox has no global `URL` — the stubbed suite could not; the URLs are now built in the page. `--role` not exercised against a real login (no app with a second user in the lab) |
| 2026-10-11 | `secrets-scan.py` over this repository | — | FAIL at first, 16 findings: 14 were the scan's own false positives (`actions/checkout@v5`, `@playwright/mcp@latest`, code such as `pwd = os.environ.get(…)`, prose, Oracle's `scott/tiger` in fixtures) — the rules were tightened; 2 were fake passwords in `pw-wrapper-smoke.sh`, now marked `secrets-scan: allow <reason>`; the scan's own two patterns are marked too. PASS, 205 files |
| 2026-10-12 | `validate-examples.sh --lint` and `SQLCL_BIN=… validate-examples.sh --compiler`, after KC-4/5/7 (breadcrumb regions on `@/title-bar` named after the page, no `warnOnUnsavedChanges` on a `definedByDynamicAction` button, `invokeApi` processes, the version token) | SQLcl 26.2.0.181.2110 (Windows, from WSL), `apexlang-generation` 26.1 at `014cdb2`, Oracle's 26.1 scaffold | PASS both — the compiler's first PASS (`Validation successful`); the lint only the five documented diagnostics. Found on the way: an `invokeApi` IN parameter without `value.type` does not compile (UP-4) |
| 2026-10-12 | `arch-scan.py` over `skills/apexlang-architecture/examples` | — | FAIL at first: `NO_VERSION_TOKEN` on the three `pkg_absences` transitions, by design (KC-5: locked `FOR UPDATE`, from-state checked) — now marked `-- lost update review: <reason>`; PASS, no advisory |
| 2026-10-12 | `arch-scan.py` over Oracle's 26.1 example applications (`apexlang-example-applications/assets/example-{0,1,2}`, copied into the repo for the run) | `apexlang-generation` 26.1 at `014cdb2` | example-0 PASS (1 advisory); example-1 and example-2 FAIL, 11 `AUTOMATIC_ROW_PROCESSING` each — Oracle's examples use it, our rule forbids it; `grep` finds the same 11. 14 and 9 `THIN_WRAPPER_UNMARKED` advisories; one page in each the `.apx` reader cannot follow (an IG saved-report sort key `"COL": "COL" asc`), reported as unparsed |
| 2026-10-12 | the source-dir hash the hook computes before an import (index copy, `git add -A -- <dir>`, `write-tree`), in Git Bash on a copy of Oracle's 26.1 example-1 ×5 (645 files) under `%TEMP%` | Git for Windows (`C:\Program Files\Git`), from WSL | about 0.2 s per hash, warm; only an `apex import`/`export` command pays it |

## Known conflicts

Where this repo's guidance and Oracle's disagree — or this repo disagrees with itself.
P6 decides which wins for grammar and components; a conflict the recipes have not been
rewritten for is recorded here instead of silently kept; once fixed, it moves to §Resolved
conflicts and its ID is not reused. Owner of the open ones: Phase 3, as noted.

| ID | Topic | Oracle (26.1, release 2026.09.21) | This repo | Until fixed |
|---|---|---|---|---|
| — | none open | | | |

### Resolved conflicts

| ID | Topic | Resolution | Where |
|---|---|---|---|
| KC-1 | conditional card styling | Oracle's rule, generalised. A row-dependent class comes from a closed set of literals and is mapped whole: the six `u-*` classes on Cards and on report badges, `success\|warning\|danger\|info` on template-component badges, never a composed class. Avatar colours come from `applyThemeColors`. | `ui-contracts.md` §2; recipes, the absences example (0.7.0, unreleased) |
| KC-2 | Metric Card drill-down | Oracle's rule: the card's `position: link` action only when every card opens the same page with its own key; otherwise a header action or a nearby report | `recipes/dashboard-kpis-charts.md` (0.7.0, unreleased) |
| KC-3 | navigation targets | Oracle's rule: a declarative `behavior.target` / `link.target`; the query projects the key, never a URL | `ui-contracts.md` §3 (0.7.0, unreleased) |
| KC-4 | calling a package from a page process | The majority of Oracle's policies (`apex.global.md`, `apex.logic.md`, the guard, `rules.catalog.json`): `invokeApi` by default; a thin `executeCode` wrapper only where it orchestrates a named-notation call plus direct page-item assignment — an Interactive Grid save, a loader, a branch-gated flow — marked `-- thin wrapper: <reason>`, with no business logic. `apex.sql.md` alone forbids the wrapper outright; the lint enforces neither. `appProcess` stays `executeCode`-only | `SKILL.md`, `PRINCIPLES.md` P1; the examples' and recipes' processes (0.7.0, unreleased) |
| KC-5 | lost-update guard in the examples | `pkg_sectors` and `pkg_employees` update and inactivate at the loaded `row_version`, bump it in the same statement and raise `k_row_changed`; the IG adapter hands the new version back (IN OUT). `hr_absences` needs none: transitions lock the row and check the from-state, no screen edits its other columns | `examples/` (0.7.0, unreleased) |
| KC-6 | report rules (`REPORT_*`) | measured: SQLcl 26.2.0 enforces none of them. Data-only SQL and no region-level link stay this skill's own rules. Report links go on a `type: link` column, which the compiler requires even though the lint forbids it on an IR | `references/oracle-26.1-lint.md`; [probe-ui-rules](../tests/upstream/probe-ui-rules.sh) (0.7.0, unreleased) |
| KC-7 | examples vs the compiler | Ours, not the scaffold's: a breadcrumb region takes the theme's `@/title-bar` template (`@/breadcrumb` is the breadcrumb's own), named after the page; a `definedByDynamicAction` button carries no `warnOnUnsavedChanges`. SQLcl 26.2.0 now validates the examples | `examples/` (0.7.0, unreleased); §Recorded runs |

## Upstream issues

Behaviors of Oracle's tooling that affect a gate.

| ID | Issue | Effect | Mitigation |
|---|---|---|---|
| UP-1 | SQLcl prints its verdict in the JVM's language ("Validación correcta." on a Spanish Windows); the compile script greps the English `Validation successful` | a valid app reads as not validated | pin the JVM: `JAVA_TOOL_OPTIONS='-Duser.language=en -Duser.country=US'` (`validate-examples.sh` does) |
| UP-2 | SQLcl 26.2.0 refuses an app at `mmdVersion` 26.2.0+3479 — "not supported by this SQLcl version" — and still exits 0 | Validation is `BLOCKED` for 26.2 apps on that SQLcl | a newer SQLcl; never read exit 0 as PASS |
| UP-3 | `deploy-apex-app.sh` imports without validating, and passes `SQLCL_CONNECTION_STRING` as a SQLcl argument | Validation is not enforced on the deploy lane (GAP-3); the connect string is visible in the process list | run Validation first; on shared machines, a connect string without an inline password |
| UP-4 | Oracle's `processes.invoke-api.md` template maps parameters as `value { item: … }` with no `type`; SQLcl 26.2.0 accepts that only on an OUT parameter (with `ignoreOutput: false`) and requires `type: item` on an IN one | a generated `invokeApi` process fails to compile | IN: `value { type: item  item: … }`; OUT: `parameter { direction: out  ignoreOutput: false }` + `value { item: … }` — as the examples do |

## Declared gaps

What no gate enforces. Listed so nothing here reads as more than it is.

| ID | Gap | Consequence |
|---|---|---|
| GAP-1 | the hook sees only commands of Claude Code's `Bash`/`PowerShell` tools, and only what their text shows — not an import inside `sql @script.sql`, a wrapper under another name, an MCP tool, a path held in a variable; other agents have no hook | outside it, the check script is the whole protocol |
| GAP-2 | the hook refuses writes to markers and refs only in Claude Code; deleting a marker is allowed by design (it only withdraws) | an agent with a plain shell elsewhere can bypass the guard |
| GAP-3 | nothing enforces Validation before an import on Oracle's deploy lane | the orchestrator must run it |
| GAP-4 | no PL/SQL compile gate: a process can name a package procedure that does not exist and still validate | caught at runtime, or not at all |
| GAP-5 | agent-produced results (architecture, runtime) can be false; hashes make them auditable, not true | review the raw evidence |
| GAP-6 | **closed (R-1):** environments per app were not modeled — one connection per app. Now an app declares `environments` (as many as the project uses, each its own Builder, runtime and test user, optionally `protected`); gates, `pw.sh` and `evidence.py` take `--env`, state is keyed `<alias>.<env>`, and the hook reads the environment from the saved connection a command names, blocking one that names none — a connect string, as Oracle's deploy script takes, still cannot be compared, so for an app with environments it blocks | — (the e2e, config-parity, the `pw.sh` smoke and `evidence.sh` cover it) |
| GAP-7 | **closed (R-7):** the guard kept its state under `.git/apex-sync/`, which assumed `.git` is a directory. Now the syncpoint is in the shared git dir, next to the shared ref, and each worktree keeps its own markers and results under its git dir; the hook reads the marker of the worktree it runs in | — (the e2e runs a check and the hook in a real linked worktree) |
| GAP-8 | **closed (R-7):** nothing told a stale result from a fresh one. Every result now records the working tree it judged (`context.repo.tree`), and `evidence.py fresh --task <id>` says whether it still speaks for now; reading it is still the consumer's job ([GATES.md](GATES.md) §Freshness) | a consumer that skips `fresh` can still read a stale PASS |
| GAP-9 | **closed (R-6):** a check's marker was tied to a time only — undo a capture within the 10 minutes and the old PASS still authorized the import. Now it records the app's source dir as a git tree, hashed when the check starts and when it writes the marker (a LOCAL edited during the check gets no marker); the hook hashes it again before an import or an export (about 0.2 s on Git for Windows, 645 files) and blocks on any difference. The TTL is now 5 minutes | — (the e2e: edit, revert, new file, edit outside the source, export, an older marker, an edit during the check) |
