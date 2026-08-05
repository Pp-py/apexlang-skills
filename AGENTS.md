# Agent instructions — apexlang-skills

This repository ships three paired skills for building Oracle APEX applications written as
APEXlang declarative source (`.apx`). If you are a coding agent (Claude Code, Codex, opencode,
Cursor, aider, …) working on an APEXlang app, load the relevant skill file below **before**
designing, changing, or verifying anything.

## The three skills

1. **`skills/apexlang-architecture/SKILL.md`** — read it when deciding WHERE business logic,
   validation, or DML belongs. Core rule: every write goes through one PL/SQL package per table
   (single write-path); never use region-bound Automatic Row Processing (DML). Archetype recipes
   live in `skills/apexlang-architecture/recipes/`, backend conventions in
   `skills/apexlang-architecture/back-end-conventions.md`.

2. **`skills/apex-sync-guard/SKILL.md`** — read it BEFORE running any `apex import` or
   `apex export`. Both are total silent overwrites (import replaces the whole app in the
   Builder; export replaces the working tree); the skill gates them behind a sync-check
   against the opposite replica, keyed to a recorded syncpoint. Never assume the Builder is
   clean because "the flow is source-first" — verify. Per-project wiring (config + optional
   blocking hook for Claude Code) is in `skills/apex-sync-guard/setup.md`; non-Claude agents
   use the wrapper `skills/apex-sync-guard/scripts/apex-sync-check.sh` directly.

3. **`skills/apex-sentinel/SKILL.md`** — read it after importing or changing a page, before
   claiming the change works. The running app in a real browser is the ONLY verification gate;
   it never degrades to "validate/import succeeded". Environment discovery is in
   `skills/apex-sentinel/setup.md`, per-archetype checklists in `skills/apex-sentinel/checks/`.

They form one loop: **architect → build (`.apx` + package) → sync-check → import → verify in
the browser** (plus sync-check before any export, and `record-sync` after either operation).

## Hard requirements (apex-sync-guard)

- `git`, SQLcl on PATH, and `jq` *or* `python3`.
- A per-project `apex-sync.json` at the repo root (see `skills/apex-sync-guard/setup.md`);
  without it the guard cannot run — do NOT proceed to import/export unchecked, wire it first.
- bash: Linux/macOS natively, Windows through Git Bash or WSL (never PowerShell/cmd).
  `scripts/apex-sync-check.sh doctor` verifies the whole wiring on a new machine, including
  that the saved SQLcl connection can actually see the configured `appId`.

## Hard requirements (apex-sentinel)

- A browser-automation tool — Playwright CLI (`@playwright/cli`) recommended (snapshots to
  disk, persistent daemon); any browser-MCP that can navigate, snapshot, click, type, and
  handle dialogs also works (see `skills/apex-sentinel/setup.md` §0 for its performance
  flags). No browser → STOP and report; never fake verification.
- SQLcl for data-side confirmation ("the UI said saved" ≠ "the row exists").

## Out of scope

`.apx` grammar, `validate`, `import`, and round-trip belong to the official `apex` tooling/skill,
not to this repo.

## Runnable examples

`skills/*/examples/` contains two complete vertical slices (DDL + package + `.apx` + verification
walkthrough): `sectors-catalog` (editable Interactive Grid) and `absences-workflow` (state
machine). Start at `skills/apexlang-architecture/examples/README.md`.
