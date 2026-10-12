# Agent instructions — apexlang-skills

This repository is an engineering framework for Oracle APEX applications written as APEXlang
declarative source (`.apx`): five skills on top of Oracle's official APEXlang skills, plus the
contracts that make them one system (`framework/`). If you are a coding agent (Claude Code,
Codex, opencode, Cursor, aider, …) working on an APEXlang app, load the relevant skill file below
**before** designing, changing, or verifying anything.

## The five skills

1. **`skills/apexlang-architecture/SKILL.md`** — read it when deciding WHERE business logic,
   validation, or DML belongs. Core rule: every write goes through a PL/SQL package (single
   write-path); never region-bound Automatic Row Processing (DML). Which layer owns an operation
   (entity / multi-entity flow / external-system integration), and when the answer is no package
   at all, is in `skills/apexlang-architecture/package-boundaries.md`; recipes in `recipes/`,
   backend conventions in `back-end-conventions.md`, the read-side data contract in `ui-contracts.md`.

2. **`skills/apex-sync-guard/SKILL.md`** — read it BEFORE running any `apex import` or
   `apex export` (Oracle's `deploy-apex-app.sh` included: it runs `apex import` inside). Both are
   total silent overwrites; the skill gates them behind a sync-check against the opposite replica,
   keyed to a recorded syncpoint. Never assume the Builder is clean because "the flow is
   source-first" — verify. Wiring (config + the Claude Code hook) is in
   `skills/apex-sync-guard/setup.md`; other agents call `skills/apex-sync-guard/scripts/apex-sync-check.sh`
   directly.

3. **`skills/apex-sentinel/SKILL.md`** — read it after importing or changing a page, before
   claiming the change works. The running app in a real browser is the ONLY verification gate;
   it never degrades to "validate/import succeeded". Setup in `skills/apex-sentinel/setup.md`,
   per-archetype checklists in `skills/apex-sentinel/checks/`.

4. **`skills/apex-ux/SKILL.md`** — read it when designing, changing or reviewing a page's UI.
   Criteria with IDs (`criteria/`) from WCAG 2.2 AA and Oracle's policies; a pattern catalog is
   an example only. `scripts/ux-scan.py` (static) and `ux-check.py` (runtime, through `pw.sh`)
   write a `ui-result`; the UI gate runs after Runtime when the app sets `"uiGate": true`.

5. **`skills/apex-security/SKILL.md`** — read it before calling a change safe to deploy.
   Criteria with IDs (`criteria.md`); `scripts/sec-scan.py` (`.apx`) and `plsql-scan.py`
   (packages) write a `security-result`. Runtime probes and the gate: Phase 3, not built yet.

They form one loop: **architect → build (`.apx` + package) → validate → sync-check → import →
record-sync → verify in the browser → UI checks** (plus sync-check before any export).

## Gates, statuses, evidence

- Every gate ends in `PASS`, `FAIL`, `CONFLICT` (sync only), `BLOCKED` or `UNKNOWN` — exit codes
  0, 1, 1, 2, 3. **Exit 3 (UNKNOWN) authorizes nothing: re-run.** `NOT_RUN` is never a verdict:
  an orchestrator records it for a gate that did not run, a runtime check for a criterion it did
  not exercise. PASS ≠ NOT_RUN ≠ UNKNOWN ≠ "it seemed to work".
- Results are JSON (`framework/schemas/`): the guard writes `.git/apex-sync/<alias>/last-<op>.json`
  on every run, and with `--task <id>` a copy under the evidence dir (`.apex-evidence/` by default,
  never committed); apex-ux's two scripts do the same with `--task` (`ui-result`). Record runtime
  and architecture verdicts the same way (`references/runtime-result.md`,
  `references/decision-record.md` in those skills).
- Never write a marker, a ref under `refs/apex-sync/` or a result by hand, and never run
  `record-sync --force`: those are the user's calls.
- What each gate establishes and what it does not, and how an orchestrator may use them:
  `framework/GATES.md`.

## Hard requirements (apex-sync-guard)

- `git`, SQLcl on PATH, and `jq` *or* `python3`; bash (Linux/macOS natively, Windows through
  Git Bash or WSL — never PowerShell/cmd for the scripts; the hook watches `Bash|PowerShell`).
- A per-project `apex-sync.json` at the repo root; without it the guard cannot run — do NOT
  proceed to import/export unchecked, wire it first. With several apps (`apps[]`), every command
  takes `--app <alias>`; without it the gate is BLOCKED, never guessed.
- `scripts/apex-sync-check.sh doctor` verifies the wiring on a new machine, including that the
  saved SQLcl connection can see each configured `appId`.

## Hard requirements (apex-sentinel)

- A browser-automation tool — Playwright CLI (`@playwright/cli`) through `scripts/pw.sh`
  recommended; any browser-MCP that can navigate, snapshot, click, type and handle dialogs also
  works. No browser → STOP and report; never fake verification.
- SQLcl for data-side confirmation ("the UI said saved" ≠ "the row exists").
- A test user: `testUser` / `runtimeUrl` in `apex-sync.json`, the password from
  `$APEX_TEST_PASSWORD` (per app: `$APEX_TEST_PASSWORD_<ALIAS>`), a gitignored `.env`, or a json
  outside the repo — never in `apex-sync.json`. `pw.sh [--app <alias>] login` accepts the login
  only when APEX reports that user as `APP_USER`.

## Oracle's skills, by version

`apex@oracle-skills` routes by the app's `mmdVersion`: **26.1** has generation (policies, lint,
`apexctl`), compile, deploy and inventory; **26.2** has compile, deploy and inventory. Grammar,
`validate`, `import` and round-trip belong to Oracle's skills and SQLcl, not to this repo; where
the two disagree, `framework/PRINCIPLES.md` P6 sets the precedence.

## Runnable examples

`skills/apexlang-architecture/examples/` holds three complete slices (DDL + package + `.apx`):
`sectors-catalog` (editable Interactive Grid), `absences-workflow` (state machine) and
`employees-form` (single-entity form, full page + drawer); the first two have browser
walkthroughs in `skills/apex-sentinel/examples/`. Start at `skills/apexlang-architecture/examples/README.md`.
