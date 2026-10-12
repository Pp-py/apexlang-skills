# Contracts

## Who owns what

| Oracle's skills provide (`apex@oracle-skills`) | apexlang-skills provides |
|---|---|
| the APEXlang language, its grammar and component inventory (`apexlang-inventory`) | **where logic goes**: the single write path, package ownership, the data contracts behind cards, badges and links (`apexlang-architecture`) |
| generation with policies and a local lint — 26.1 only (`apexlang-generation`) | **whether an import/export is safe now**: Builder↔git divergence against a syncpoint (`apex-sync-guard`) |
| compilation: `apex validate` through SQLcl (`apexlang-compile`) | **whether the change works**: the running page in a real browser, with a verified test user (`apex-sentinel`) |
| a UX pattern catalog (an example, never an authority) | **whether the UI holds**: criteria with IDs, a static scan and runtime checks (`apex-ux`) |
| security policies and a lint — 26.1 only, advisory | **whether the app refuses what it must**: security criteria with IDs (`apex-security`; scans and gate in Phase 3) |
| import / deploy (`apexlang-deploy`) and export (SQLcl) | the gates, their statuses and the evidence they leave (this directory) |

Precedence where they overlap: [PRINCIPLES.md](PRINCIPLES.md) P6.

## Statuses

| Status | Means | Exit | Emitted by |
|---|---|---|---|
| `PASS` | ran to the end, the condition holds, and evidence shows it | 0 | a producer |
| `FAIL` | ran to the end, the condition does not hold | 1 | a producer |
| `CONFLICT` | **Sync only**: the other replica holds work the operation would overwrite | 1 | apex-sync-guard |
| `BLOCKED` | a precondition is missing; stopped **before** any effect (includes an unverified login) | 2 | a producer |
| `UNKNOWN` | started, and the outcome cannot be determined — or an effect may have happened | 3 | a producer |
| `NOT_RUN` | not invoked, not required (with a reason), or stale | — | **never a producer's verdict** — a consumer assigns it to a gate; inside a runtime-result or a ui-result, a criterion not exercised is NOT_RUN |

The JSON result is the verdict; the exit code mirrors it. A run that stopped before it
could write a result (no repo, no SQLcl, an invalid config, bad arguments) leaves none — and a
file left there by an *earlier* run of the same task is not this run's: a consumer that finds
no result, or one whose `context.timestamp` is earlier than the moment it started the command,
reads exit 2 as BLOCKED and any other exit as UNKNOWN.

## Oracle's signals, mapped

Oracle's tools report in their own words. They map onto the statuses above — this
repo never redefines them, and never promotes an advisory signal to a verdict.

| Oracle signal | Maps to |
|---|---|
| `apexlang-compile/scripts/validate-apex-app.sh`: exit 0 **and** `Validation successful` | Validation `PASS` |
| the same script reporting compile errors — `apex validate` itself returns 0 with errors, so the text decides, never the exit code alone | Validation `FAIL` |
| SQLcl: `… is not supported by this SQLcl version` (still exit 0) | Validation `BLOCKED` — an unqualified SQLcl/APEXlang pair (UP-2) |
| the 26.1 local lint (`apexctl apexlang validate`: `APEXLANG_LOCAL_CHECK_OK` / `_FAILED`) | **advisory** — Oracle calls it "syntax hygiene"; evidence at most, never a Validation status |
| `deploy-apex-app.sh` / `apexctl runtime roundtrip` exit or `import_status` | the import's own outcome — not a gate; the Sync gate comes before it |
| `apexctl runtime verify-ui` (26.1, opt-in, HTML fetch through the CLI) | supporting evidence at most; never a Runtime `PASS` |
| Oracle's lower-case vocabulary (`pass`, `fail`, `blocked`, `skipped`) | the same word upper-cased, only for the signals above; `skipped` → `NOT_RUN` (by the consumer) |

## Terms

| Term | Meaning |
|---|---|
| BASE / syncpoint | the app's tree at the last synchronization: a git commit at `refs/apex-sync/<alias>`, snapshotted from a Builder export |
| LOCAL | the app's source dir in the working tree: `<apexlangDir>/<appAlias>` |
| BUILDER (REMOTE) | the app as the target workspace holds it, exported through the saved SQLcl connection |
| marker | `.git/apex-sync/<alias>/check-ok.<direction>`: the hook's authorization, written only by a check PASS, trusted for 10 minutes |
| app alias | how every script, ref, directory and result names an app (`^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$`) |
| task | one unit of work an orchestrator verifies; its id names a directory under the evidence dir |
| result | a producer's JSON verdict, validated by its schema in `schemas/` |
| gate | a check a change must pass, with an owner and a producer ([GATES.md](GATES.md)) |
| criterion | one pass condition of a runtime check, with an ID (`IG-RENDER`) |

## Each capability's contract

| | apexlang-architecture | apex-sync-guard | apex-sentinel |
|---|---|---|---|
| **Input** | the requirement, the app context, the schema (tables, constraints) | BASE, LOCAL, BUILDER; `--app`, `--task` | the running app (`runtimeUrl`), a test user, the archetype's check, SQLcl for the data side |
| **Output** | `architecture-result`: each rule's place, each operation's owner (branch, layer, package), the red-flag scan, the rationale | `sync-result`; for a check PASS, the marker | `runtime-result`: per criterion, the status, what was observed and the evidence |
| **Statuses** | PASS · FAIL · BLOCKED (missing input) · UNKNOWN | PASS · FAIL · CONFLICT · BLOCKED · UNKNOWN | PASS · FAIL · BLOCKED (no browser, unverified login) · UNKNOWN |
| **Producer** | the agent (`method: agent`) | the script (`method: tool`) | the agent through `pw.sh` (`method: agent`) |
| **Schema** | `architecture-result` (experimental) | `sync-result` (**stable**) | `runtime-result` (experimental) |

A **stable** schema changes only additively within `schemaVersion` 1. An **experimental**
one may change in any minor release, until its producer is a script rather than an agent
following prose.

## Where results land

Paths are repo-relative. `<evidenceDir>` defaults to `.apex-evidence` (`apex-sync.json`
`evidenceDir`), with a `.gitignore` of `*`: whoever writes there first creates it, and the guard
puts it back whenever it is missing.

| Result | Path | Written by |
|---|---|---|
| sync-result (every run) | `.git/apex-sync/<alias>/last-<operation>.json` | `apex-sync-check.sh` |
| sync-result (with `--task`) | `<evidenceDir>/<task>/sync-<alias>-<operation>.json` | `apex-sync-check.sh` |
| runtime-result | `<evidenceDir>/<task>/runtime-<alias>.json` | the agent (apex-sentinel) |
| architecture-result | `<evidenceDir>/<task>/architecture.json` | the agent (apexlang-architecture) |
| ui-result, static (with `--task`) | `<evidenceDir>/<task>/ui-<alias>-static.json` | `ux-scan.py` (apex-ux) |
| security-result, static (with `--task`) | `<evidenceDir>/<task>/security-<alias>-static.json` | `sec-scan.py` (apex-security) |
| security-result, plsql (with `--task`) | `<evidenceDir>/<task>/security-<alias>-plsql.json` | `plsql-scan.py` (apex-security) |
| security-result, runtime (with `--task`) | `<evidenceDir>/<task>/security-<alias>-runtime.json` | `sec-probe.py` (apex-security) |
| security-result, secrets (with `--task`) | `<evidenceDir>/<task>/security-<alias>-secrets.json` | `secrets-scan.py` (apex-security) |
| ui-result, runtime (with `--task`) | `<evidenceDir>/<task>/ui-<alias>-runtime-<page>.json`, axe's output in `raw/ui-<alias>/` | `ux-check.py` (apex-ux) |
| raw evidence (snapshots, eval output, logs) | `<evidenceDir>/<task>/raw/<gate>-<alias>/` | whoever produced the result citing it |
| verification-manifest | `<evidenceDir>/<task>/manifest.json` | the orchestrator (future `apexlang-delivery`) |

## The frozen interface (0.6.x)

What a consumer may rely on. Changing any of it is a minor release with a `CHANGELOG.md`
entry; removing any of it, a major one.

- **Scripts.** `skills/apex-sync-guard/scripts/apex-sync-check.sh
  check-import|check-export|record-sync|status|doctor|apps [--app <alias>] [--task <id>] [--force]`
  (exit 0 PASS · 1 FAIL/CONFLICT · 2 BLOCKED · 3 UNKNOWN).
  `skills/apex-sync-guard/scripts/apex-sync-hook.sh` — Claude Code `PreToolUse`, matcher
  `Bash|PowerShell`, exit 0 allow · 2 block. `skills/apex-sentinel/scripts/pw.sh [--app <alias>]
  <subcommand>` (exit 0 · 2 refused or login unverified · 3 recovered on a logged-out page ·
  otherwise the Playwright CLI's own). `skills/apex-ux/scripts/ux-scan.py [--app <alias>]
  [--task <id>] <file-or-dir>…` and `skills/apex-ux/scripts/ux-check.py [--app <alias>]
  [--task <id>] [--dialog <selector>]… [--raw <file>]`, `skills/apex-security/scripts/sec-scan.py
  [--app <alias>] [--task <id>] <file-or-dir>…` and `plsql-scan.py` with the same arguments,
  `sec-probe.py [--app <alias>] [--task <id>] [--anon <url>]… [--tamper] [--role <url>]…
  [--xss <token>]`, `secrets-scan.py [--app <alias>] [--task <id>] [<path>…]` (python3; exit 0 PASS · 1 FAIL · 2 BLOCKED ·
  3 UNKNOWN). `skills/apexlang-architecture/scripts/arch-scan.py <file-or-dir>…` (python3; JSON on
  stdout, no result file; exit 0 no red flag · 1 red flags · 2 BLOCKED · 3 UNKNOWN). They share
  `framework/lib/` (the `.apx` reader, the PL/SQL lexer and the result envelope).
- **State.** `refs/apex-sync/<alias>`; `.git/apex-sync/<alias>/` holding `state.json`,
  `check-ok.import`, `check-ok.export`, `last-<operation>.json`.
- **Results.** The paths above; schema `$id`s
  `https://pp-py.github.io/apexlang-skills/schemas/1/<kind>.schema.json` (identifiers, not yet
  published URLs).
- **Configuration.** `apex-sync.json` keys `appId`, `appAlias`, `apexlangDir`,
  `sqlclConnection`, `ignorePaths`, `testUser`, `runtimeUrl`, `uiGate`, `securityGate`, `publicPages`, `lowPrivUser`, `evidenceDir`, `apps` — the
  canonical specification is `skills/apex-sync-guard/setup.md` §1. Environment:
  `APEX_TEST_USER[_<ALIAS>]`, `APEX_TEST_PASSWORD[_<ALIAS>]`, `APEX_TEST_PASSWORD_LOW[_<ALIAS>]`, `APEX_TEST_FILE`, `APEX_TEST_ENV`,
  `PW_WORKSPACE`, `PW_SESSION`, `PW_INSECURE_TLS`.

`tests/contract/surface.py` asserts the parts of this list a test can see.
