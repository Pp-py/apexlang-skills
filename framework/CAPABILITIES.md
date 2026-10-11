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
| Architecture: single write path, package boundaries, recipes | yes, with KC-4, KC-5 | not recorded | the skill; §Known conflicts |
| UI rules the recipes state (report links, markup in SQL, Cards classes, declarative targets) under Oracle's lint and the compiler | yes — measured on probe pages | not recorded | §Recorded runs; [probe-ui-rules](../tests/upstream/probe-ui-rules.sh) |
| Architecture: red-flag tokens exist in Oracle's inventory | yes | yes | [citations](../tests/upstream/citations.md) (the 3 auto-row-processing process types, both versions) |
| Examples under Oracle's local lint | yes — only the documented diagnostics | n/a | §Recorded runs; [expected-diagnostics](../tests/upstream/expected-diagnostics.txt) |
| Examples under the compiler | no — KC-7 | no — UP-2 | §Recorded runs |
| Sync gate: check-import / check-export / record-sync, markers, sync-result | yes (version-independent) | yes (version-independent) | [e2e](../tests/integration/sync-guard-e2e.sh) and [contract](../tests/contract/run.sh) in CI, SQLcl stubbed |
| Sync gate against a live Builder | not recorded | not recorded | — |
| Hook lanes: `apex import`/`export` and short forms, deploy script, `apexctl` roundtrip | yes | yes (deploy lane; 26.2 has no `apexctl`) | [e2e](../tests/integration/sync-guard-e2e.sh) |
| Several apps per repo (`apps[]`) | yes | yes | [e2e](../tests/integration/sync-guard-e2e.sh), [config-parity](../tests/integration/config-parity.sh), [smoke](../tests/integration/pw-wrapper-smoke.sh) |
| Runtime gate: `pw.sh` (verified login, per-app workspaces, TLS, exit 3) | yes (version-independent) | yes (version-independent) | [smoke](../tests/integration/pw-wrapper-smoke.sh) in CI, Playwright CLI stubbed |
| Runtime walkthroughs against a live app | not recorded | not recorded | — |
| runtime-result / architecture-result / verification-manifest | experimental — fixtures and negatives only | same | [contract](../tests/contract/run.sh) |
| UX criteria catalog (`apex-ux`): IDs, severity, method, source | yes — version-independent; Oracle sources cited at 26.1 | same | [contract](../tests/contract/run.sh) (format), [citations](../tests/upstream/citations.md) (Oracle anchors) |
| UI static scan (`ux-scan.py`): the five static FAIL criteria | yes (version-independent) | same | [ux-scan](../tests/integration/ux-scan.sh) in CI, over fixtures and the examples |
| Runtime UI checks, UI gate | not built (Phase 3, UX-4, UX-5) | same | — |
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

## Known conflicts

Where this repo's guidance and Oracle's disagree — or this repo disagrees with itself.
P6 decides which wins for grammar and components; a conflict the recipes have not been
rewritten for is recorded here instead of silently kept; once fixed, it moves to §Resolved
conflicts and its ID is not reused. Owner of the open ones: Phase 3, as noted.

| ID | Topic | Oracle (26.1, release 2026.09.21) | This repo | Until fixed |
|---|---|---|---|---|
| KC-4 | calling a package from a page process | `apex.sql.md` requires `invokeApi` and forbids calling packages from `executeCode`; `apex.global.md` allows a thin `executeCode` wrapper with named notation — and says "Prefer ARP for simple CRUD" | recipes use thin `executeCode` wrappers; never ARP (P1) | interim rule: `invokeApi` and a logic-free `executeCode` wrapper both satisfy P1 (Oracle's own policies disagree) |
| KC-5 | lost-update guard in the examples | — (internal) | `back-end-conventions.md` §7 requires a version token; the example packages update by primary key alone | copy the guard from §7, not from the examples (owner: apexlang-architecture) |
| KC-7 | examples vs the compiler | SQLcl 26.2.0 `apex validate`, Oracle's 26.1 scaffold: unresolved `@/breadcrumb` template references and `templateOptions` after them (pages 30, 41, 60), `warnOnUnsavedChanges` (page 42) | the same pages pass the 26.1 lint, with the documented diagnostics | the template errors also hit Oracle's own example pages on that scaffold (theme); the rest is unresolved — validate against your own app before importing (owner: apexlang-architecture) |

### Resolved conflicts

| ID | Topic | Resolution | Where |
|---|---|---|---|
| KC-1 | conditional card styling | Oracle's rule, generalised. A row-dependent class comes from a closed set of literals and is mapped whole: the six `u-*` classes on Cards and on report badges, `success\|warning\|danger\|info` on template-component badges, never a composed class. Avatar colours come from `applyThemeColors`. | `ui-contracts.md` §2; recipes, the absences example (0.7.0, unreleased) |
| KC-2 | Metric Card drill-down | Oracle's rule: the card's `position: link` action only when every card opens the same page with its own key; otherwise a header action or a nearby report | `recipes/dashboard-kpis-charts.md` (0.7.0, unreleased) |
| KC-3 | navigation targets | Oracle's rule: a declarative `behavior.target` / `link.target`; the query projects the key, never a URL | `ui-contracts.md` §3 (0.7.0, unreleased) |
| KC-6 | report rules (`REPORT_*`) | measured: SQLcl 26.2.0 enforces none of them. Data-only SQL and no region-level link stay this skill's own rules. Report links go on a `type: link` column, which the compiler requires even though the lint forbids it on an IR | `references/oracle-26.1-lint.md`; [probe-ui-rules](../tests/upstream/probe-ui-rules.sh) (0.7.0, unreleased) |

## Upstream issues

Behaviors of Oracle's tooling that affect a gate.

| ID | Issue | Effect | Mitigation |
|---|---|---|---|
| UP-1 | SQLcl prints its verdict in the JVM's language ("Validación correcta." on a Spanish Windows); the compile script greps the English `Validation successful` | a valid app reads as not validated | pin the JVM: `JAVA_TOOL_OPTIONS='-Duser.language=en -Duser.country=US'` (`validate-examples.sh` does) |
| UP-2 | SQLcl 26.2.0 refuses an app at `mmdVersion` 26.2.0+3479 — "not supported by this SQLcl version" — and still exits 0 | Validation is `BLOCKED` for 26.2 apps on that SQLcl | a newer SQLcl; never read exit 0 as PASS |
| UP-3 | `deploy-apex-app.sh` imports without validating, and passes `SQLCL_CONNECTION_STRING` as a SQLcl argument | Validation is not enforced on the deploy lane (GAP-3); the connect string is visible in the process list | run Validation first; on shared machines, a connect string without an inline password |

## Declared gaps

What no gate enforces. Listed so nothing here reads as more than it is.

| ID | Gap | Consequence |
|---|---|---|
| GAP-1 | the hook sees only commands of Claude Code's `Bash`/`PowerShell` tools, and only what their text shows — not an import inside `sql @script.sql`, a wrapper under another name, an MCP tool, a path held in a variable; other agents have no hook | outside it, the check script is the whole protocol |
| GAP-2 | the hook refuses writes to markers and refs only in Claude Code; deleting a marker is allowed by design (it only withdraws) | an agent with a plain shell elsewhere can bypass the guard |
| GAP-3 | nothing enforces Validation before an import on Oracle's deploy lane | the orchestrator must run it |
| GAP-4 | no PL/SQL compile gate: a process can name a package procedure that does not exist and still validate | caught at runtime, or not at all |
| GAP-5 | agent-produced results (architecture, runtime) can be false; hashes make them auditable, not true | review the raw evidence |
| GAP-6 | environments per app (DEV / TEST / PROD of one app) are not modeled: one connection per app. The hook refuses a SQLcl launcher named to another saved connection, but cannot compare a connect string — Oracle's deploy script takes one | Phase 3 |
| GAP-7 | guard state lives under `.git/apex-sync/`, which assumes `.git` is a directory (not a worktree) | worktrees unsupported |
| GAP-8 | nothing expires a result file; freshness beyond the marker's TTL is the consumer's job ([GATES.md](GATES.md) §Freshness) | a careless consumer can read a stale PASS |
| GAP-9 | a check's marker is tied to a time, not to the LOCAL content it compared: undo a capture within the 10 minutes and the old PASS still authorizes the import | re-run `check-import` after any change to LOCAL; binding the marker to the source tree's hash is a Phase 3 candidate |
