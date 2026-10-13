# apexlang-skills

[![CI](https://github.com/Pp-py/apexlang-skills/actions/workflows/ci.yml/badge.svg)](https://github.com/Pp-py/apexlang-skills/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](./LICENSE)
[![Agent Skills](https://img.shields.io/badge/agent--skills-SKILL.md-6e56cf)](https://agentskills.io)

An engineering framework for building **Oracle APEX** apps as **APEXlang** declarative source
(`.apx`) with coding agents — on top of Oracle's official APEXlang skills. Three capabilities
(architecture, sync safety, runtime proof) behind **fail-closed gates** that leave
**machine-readable evidence**, so "it works" is something a result file shows, not something an
agent says.

## What problem does this solve?

APEXlang turns an APEX app into source a coding agent can work on. Generating, compiling and
importing that source is solved — by **Oracle's official APEXlang skills**. Valid `.apx` is not
a sound application, though. Three failure modes survive a clean `validate`:

- **Logic scatters.** Left alone, an agent bolts region-bound Automatic DML onto every grid and
  calls it simple — leaving no single place where a business rule holds.
- **A sync erases work.** `apex import` replaces the whole app in the Builder; `apex export`
  replaces the whole working tree. Whichever replica held unsynchronized changes loses them,
  irreversibly and without a prompt.
- **"It works" gets claimed from a green import.** `validate` proves grammar and `import` loads
  metadata; neither renders the page — a process can call a package procedure that doesn't exist
  and still validate.

## How it fits

```text
Oracle Official Skills    apex@oracle-skills — the language, inventory, generation (26.1),
        │                 compile, import/export        (verified revision: framework/oracle-skills.lock.json)
        ▼
apexlang-skills           apexlang-architecture · apex-sync-guard · apex-sentinel · apex-ux
        │                 · apex-security · apexlang-delivery
        │                 + framework/: principles, contracts, gates, evidence, capability matrix
        ▼
Engineering guardrails    single write path · fail-closed gates · evidence, not claims
```

| Oracle's skills provide | apexlang-skills provides |
|---|---|
| the APEXlang language, its grammar and component inventory | **where logic goes** — [`apexlang-architecture`](skills/apexlang-architecture/SKILL.md): every write through a PL/SQL package, one owner per table and per rule; 13 screen-archetype recipes and the data contracts behind cards, badges and links |
| generation with policies and a local lint (26.1) | **whether an import/export is safe now** — [`apex-sync-guard`](skills/apex-sync-guard/SKILL.md): Builder↔git divergence against a recorded syncpoint, both directions, several apps per repo; a wrapper script and a blocking `PreToolUse` hook |
| compilation (`apex validate` through SQLcl) | **whether the change works** — [`apex-sentinel`](skills/apex-sentinel/SKILL.md): the running page in a real browser, as a verified test user, criterion by criterion, with the data read back through SQLcl |
| import / deploy and export | **the gates, their statuses and their evidence** — [`framework/`](framework/README.md) |
| Universal Theme, and a UX Pattern Catalog app as an example | **whether the UI is usable and accessible** — [`apex-ux`](skills/apex-ux/SKILL.md): criteria with IDs from WCAG 2.2 AA and Oracle's policies, per archetype; a static scan of the `.apx` and runtime checks in the browser (axe-core, dialog focus) for the FAIL criteria, as the UI gate (opt-in per app, `uiGate`) |
| security policies and a lint (26.1, advisory) | **whether the app refuses what it must** — [`apex-security`](skills/apex-security/SKILL.md): a threat model and security criteria with IDs from Oracle's policies and OWASP ASVS 5.0; scans of the `.apx`, the packages and the tracked files, and runtime probes, as the Security gate (opt-in per app, `securityGate`) |
| a deploy script that imports without validating (GAP-3) | **whether a task is verified** — [`apexlang-delivery`](skills/apexlang-delivery/SKILL.md): the gates in order for one task, the import lane with Validation before it, and `delivery.py`, which writes the task's `verification-manifest` from the results and adds no rule |

This repo never duplicates what Oracle's skills do. Where its guidance and Oracle's meet, the
precedence is explicit — SQLcl `apex validate` > Oracle's 26.1 lint > Oracle's inventory, policies
and templates > this repo, for grammar and components ([P6](framework/PRINCIPLES.md)) — and every
disagreement is recorded as a known conflict
([`CAPABILITIES.md`](framework/CAPABILITIES.md)), not silently kept.

## The loop, as gates

```text
Architecture → build (.apx + package) → Validation → Sync → import → record-sync → Runtime → Security → UI
```

Each gate has one owner and states what its PASS does **not** establish
([`GATES.md`](framework/GATES.md)). Every verdict is one of `PASS · FAIL · CONFLICT (sync only) ·
BLOCKED · UNKNOWN`, with exit codes 0 · 1 · 1 · 2 · 3 — and `NOT_RUN`, which is never a
producer's verdict: a consumer assigns it to a gate that did not run (a runtime check marks a
criterion it did not exercise the same way). **PASS ≠ NOT_RUN ≠ UNKNOWN ≠ "the agent says it worked."** Results are JSON validated by
[`framework/schemas/`](framework/schemas/) — `sync-result` is stable and written by the guard on
every run; `runtime-result`, `architecture-result`, `ui-result` and the task-level
`verification-manifest` are experimental, and so is `security-result`. The Security and UI gates are opt-in per app (`securityGate`, `uiGate`) until 1.0.0. [`apexlang-delivery`](skills/apexlang-delivery/SKILL.md) orchestrates the gates for one task and `delivery.py` writes its manifest from those files, under
a contract that lets it add no rule of its own ([`GATES.md` §The orchestration contract](framework/GATES.md#the-orchestration-contract)).

## Install

**Claude Code (plugin)** — Oracle's skills first, then these:

```text
/plugin marketplace add oracle/skills
/plugin install apex@oracle-skills
/plugin marketplace add Pp-py/apexlang-skills
/plugin install apexlang-toolkit
```

Installs the three skills and auto-registers the sync-guard hook (it no-ops in projects without
an `apex-sync.json` — per-project wiring in [`setup.md`](skills/apex-sync-guard/setup.md)).

**Any other agent** (Codex, opencode, Cursor, …): plain-Markdown [Agent Skills](https://agentskills.io)
— symlink `skills/*` into your tool's skill directory, or point the agent at [`AGENTS.md`](./AGENTS.md).
Each skill also works on its own.

## Requirements

| Oracle APEXlang version (`mmdVersion`) | Oracle's skills you get | Notes |
|---|---|---|
| 26.1 | generation (policies, local lint, `apexctl`), compile, deploy, inventory | the version Oracle's router defaults to |
| 26.2 | compile, deploy, inventory | SQLcl 26.2.0 refuses 26.2 apps (UP-2); SQLcl 26.3.0 reads them (measured on APEX 26.2, R-8) — `doctor` says which you have |

- **SQLcl** for compile, import/export and the data-side reads.
- **apex-sync-guard:** `git`, `jq` *or* `python3`. Check a machine with
  `skills/apex-sync-guard/scripts/apex-sync-check.sh doctor`.
- **apex-sentinel:** a browser — the Playwright CLI through `skills/apex-sentinel/scripts/pw.sh`
  (it falls back to `npx`), or any browser-MCP. No browser → it stops and reports; it never fakes
  verification. A **test user** for the app's login ([`setup.md` §2](skills/apex-sentinel/setup.md)).
- **Platform:** the scripts are bash — Linux and macOS natively, Windows through **Git Bash or WSL**
  (Claude Code's Bash tool on Windows already uses Git Bash). The hook watches both shell tools
  (`Bash|PowerShell`) and is registered as `bash "<path>"`.

## Configuration

One file at the project root, committed — `apex-sync.json`. One app:

```json
{ "appId": 100, "appAlias": "hr", "apexlangDir": "apex/apexlang", "sqlclConnection": "dev_hr",
  "testUser": "QA_HR", "runtimeUrl": "https://<host>/ords/r/<workspace>/hr/" }
```

Several live apps in one workspace and one repo: list them in `apps[]`, with top-level defaults;
every gate command then names its app (`--app hr`). Passwords never go in this file. The
canonical specification is [`apex-sync-guard/setup.md` §1](skills/apex-sync-guard/setup.md).

## Examples

Three runnable vertical slices (DDL + write-path package + `.apx`; the first two also with a
browser-verification walkthrough): an editable Interactive Grid, an approval state machine, and
a single-entity form (full page + drawer). Start at
[`examples/README.md`](skills/apexlang-architecture/examples/README.md).

Grammar status, measured rather than claimed: Oracle's 26.1 local lint passes the five `.apx`
with only the diagnostics documented where they occur, and the compiler — SQLcl 26.2.0
`apex validate` on Oracle's 26.1 scaffold — accepts them. Lint-clean is still not
"compiles": [`examples/README.md`](skills/apexlang-architecture/examples/README.md#grammar-status--gotchas).

## Roadmap

| Phase | Scope | Status |
|---|---|---|
| 1 — Capabilities | architecture, sync safety, runtime verification | done |
| 2 — Engineering framework | principles, contracts, gates, evidence, capability matrix, testing model; contracts ready for an `apexlang-delivery` that orchestrates the gates and adds no rules | done — 0.6.0 |
| 3 — Application quality | **UI/UX**, then **Security**, as new gates; the known conflicts, environments per app and the remaining gaps; last, `apexlang-delivery` — the orchestrator the Phase 2 contracts were written for | in progress — 0.6.1 released; on `main`: UI/UX, Security, the known conflicts, environments, the live run, and `apexlang-delivery` |
| 4 — Benchmark & continuous verification | showing that the framework makes an agent better, measured | later |

## Development

```bash
git ls-files -z -- '*.sh' | xargs -0 shellcheck -x   # lint
tests/contract/run.sh                                # schemas, negatives, every emitted result, docs surface
tests/integration/sync-guard-e2e.sh                  # sync guard + hook, SQLcl stubbed
tests/integration/pw-wrapper-smoke.sh                # pw.sh, Playwright CLI stubbed
tests/integration/config-parity.sh                   # apex-sync.json read alike by the guard and pw.sh
tests/upstream/verify-citations.sh                   # quotes from Oracle's skills still say what we claim
tests/upstream/validate-examples.sh [--compiler]     # the examples under Oracle's 26.1 lint, or SQLcl apex validate
tests/upstream/probe-ui-rules.sh [--compiler]        # which UI rules the lint and the compiler each enforce
```

What each tier establishes — and what it does not — is in [`tests/README.md`](tests/README.md).
Lint, contract and integration run in CI (integration on Ubuntu and Windows). The `upstream/`
scripts need Oracle's APEXlang skills installed — resolved from the revision pinned in
[`framework/oracle-skills.lock.json`](framework/oracle-skills.lock.json), or
`APEXLANG_ROOT=<path>/apex/apexlang` — and their runs are recorded in
[`framework/CAPABILITIES.md`](framework/CAPABILITIES.md). Exit codes: 0 PASS, 1 FAIL, 2 BLOCKED —
a missing prerequisite never reads as a pass.

## License

[MIT](./LICENSE) © 2026 Pablo Portillo
