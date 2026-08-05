---
name: apex-sync-guard
description: Use when about to run `apex import` or `apex export` on an APEXlang app, when the APEX Builder may hold unexported changes (tweaks made directly in the Builder UI), or after discovering lost work following an import/export — detects Builder↔git divergence before either replica gets overwritten.
---

# apex-sync-guard

## Overview

`apex import` replaces the **entire app** in the Builder with the working tree. `apex export` replaces the **working tree** with the Builder. Both are total, silent overwrites: whichever side held unsynchronized changes loses them, irreversibly. Git and the Builder are two replicas of the same app with no built-in record of their last common state — this skill maintains that record (the **syncpoint**) and gates both directions.

**Principle: cleanliness is verified, never assumed. No `apex import` or `apex export` runs until a sync-check against the opposite replica has PASSED in this session.**

The check answers **two** questions, and both are reported. *Is anything destroyed?* — does the opposite replica hold work this operation would overwrite. *What is deployed?* — since import replaces the whole app, a PASS still pushes every LOCAL change accumulated since the syncpoint, not just today's edit. The second half never blocks (every legitimate import has a payload), but it is printed on every PASS: an app that quietly starts behaving like the last four days of commits is a surprise worth one paragraph of output.

Division of labor: this skill decides whether it is **SAFE** to import/export *now*. The official `apex` skill stays the **HOW** (grammar/validate/import); `apexlang-architecture` decides **WHERE** logic goes; `apex-sentinel` proves the result **WORKS**.

## The model

| Role | What | Materialized as |
|---|---|---|
| BASE | last synchronized state | git tree under local ref `refs/apex-sync/<app-alias>` + `.git/apex-sync/<app-alias>/state.json` |
| LOCAL | your working tree | the APEXlang source dir in the repo |
| REMOTE | the Builder | `apex export` to a scratch dir (the export is byte-stable: zero diff ⇒ genuinely untouched) |

Same 3-way logic as `git pull` before `push`: if REMOTE moved since BASE, integrate before overwriting.

**Canonical space:** BASE is always snapshotted from an `apex export`, never from the raw working tree — hand-edited `.apx` differ *textually* from the exporter's canonical serialization (whitespace, fenced vs inline blocks, JSON spacing) without differing semantically. BASE↔REMOTE comparisons are therefore noise-free; only the one-time bootstrap (BUILDER vs LOCAL, no BASE yet) can surface formatting-only diffs, which reconcile by adopting the canonical form.

**Comparison is byte-exact and independent of your git config.** Replicas are compared with `cmp`, not with `git diff --no-index`: git applies `.gitattributes` / `core.autocrlf` to whichever side it resolves inside the repo and not to the scratch export, so its verdict tracked the machine's git settings instead of the content (with `core.autocrlf=true` — the Git-for-Windows default — a CRLF and an LF copy of the same file compare *equal*). Files that differ **only** in line endings are reported as `E` and do not gate: that difference cannot carry a Builder-side change, and blocking on it would deadlock since every re-export reintroduces it. Silence them with `*.apx text eol=lf` in the consuming repo's `.gitattributes`.

## Protocol

All operations go through `scripts/apex-sync-check.sh` in this skill's directory, run from the project repo root. It reads `apex-sync.json` (per-project config: app id, alias, source dir, SQLcl connection — see `setup.md`; setup also covers the first-run bootstrap when no syncpoint exists yet).

**Pre-import** — `apex-sync-check.sh check-import`:

1. Exports REMOTE (the Builder) to scratch — **always**, ~20 s. Dictionary timestamps cannot gate this: an APEXlang import recreates components with NULL audit columns, so `LAST_UPDATED_ON`/`LAST_UPDATED_BY` feed only the best-effort who/when report.
2. Byte-compares REMOTE vs BASE. Zero diff → Builder untouched → **PASS**. Diff, but LOCAL already contains every Builder-side change (captured/merged earlier) → **PASS** — importing rewrites those files identically, losing nothing.
3. Otherwise **FAIL** with the per-file diff plus the who/when report → resolve (next section), then re-run.
4. On every PASS it then prints the **deploy payload** — BASE vs LOCAL, plus how many commits touched the source dir since the syncpoint. Read it before importing: that is the change set the Builder is about to receive. `status` prints it too, without needing an export.

**Pre-export** — `apex-sync-check.sh check-export`:
Fails if the APEXlang source dir has uncommitted or untracked changes — the export would clobber them. Commit or stash first, then re-run.

**After every successful import or export** — `apex-sync-check.sh record-sync`:
Updates the syncpoint (tree + timestamps). Skipping this poisons every future comparison — treat import/export as unfinished until `record-sync` ran.

`apex-sync-check.sh status` shows syncpoint age and both replicas' state at any time; `apex-sync-check.sh doctor` validates the whole wiring on a machine (platform, git, SQLcl, JSON parser, config, and that the saved connection can see this `appId`) — run it first on any machine where a check behaves oddly.

## Resolution when the Builder moved

Per differing file (the FAIL report lists them; the Builder export is kept in scratch):

- **File changed only in the Builder** (LOCAL == BASE for it): copy it from the scratch export over the source dir, commit as a "capture Builder changes" commit.
- **File changed on both sides**: ordinary 3-way text merge, per file — materialize its BASE version from the syncpoint ref and let git merge it:
  ```bash
  git show refs/apex-sync/<alias>:<alias>/<file> > /tmp/base.apx
  git merge-file <source-dir>/<file> /tmp/base.apx <scratch>/<alias>/<file>
  ```
  Resolve any conflict markers, commit. (Do NOT merge the syncpoint ref as a branch — it shares no history with yours; `merge-file` is the right tool.)

Then re-run `check-import`: it PASSes once LOCAL contains every Builder-side change (importing rewrites those files identically, losing nothing). `apex validate`, import, `record-sync`.

## When NOT to use

- No APEXlang source in git (Builder-only development) — nothing to diverge.
- Grammar / validate / import mechanics or round-trip questions → official `apex` skill.
- Verifying that the imported page behaves → `apex-sentinel`.

## Rationalizations — every one of these means STOP and run the check

| Excuse | Reality |
|---|---|
| "The flow is source-first, so the Builder has no changes" | That exact assumption is how real work was lost. Assuming ≠ verifying; the check is one command (~20 s). |
| "`git status` is clean, so it's safe to import" | `git status` sees LOCAL only. The replica import destroys is the Builder, which git cannot see. |
| "The user is in a hurry — skip the check, mention the risk afterwards" | By "afterwards" the overwrite already happened, irreversibly. The check costs ~20 seconds; redoing lost Builder work costs hours. |
| "I'll export a backup first and sort it out later" | A backup nobody diffs is a graveyard. `check-import` both snapshots AND diffs — same cost, actual protection. |
| "It's only DEV, worst case we redo it" | The unexported Builder changes ARE the work being destroyed. |
| "The import only pushes the change I just made" | It replaces the whole app with LOCAL — every commit since the syncpoint lands at once. Read the deploy payload the PASS prints before you run it. |

## Red flags — you are about to violate the gate

- `apex import` / `apex export` is in the command you're about to run and there is no PASS from `check-import`/`check-export` minutes old.
- You wrote "assuming the Builder is unchanged" (or any equivalent assumption).
- An import/export finished and `record-sync` didn't run.
- You are treating a stale sync-check (from before someone opened the Builder) as still valid.
