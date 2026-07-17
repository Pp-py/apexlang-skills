# apex-sync-guard — approved design (2026-07-04)

## Problem

In the APEXlang workflow (`apex export`/`apex import` via SQLcl), git and the APEX Builder are
two replicas of the same app **with no record of their last common state**. Both operations are
total, silent overwrites:

- `apex import` replaces the entire app in the Builder → clobbers changes made in the Builder
  and never exported (real loss, happened twice on the original project).
- `apex export` replaces the working tree → clobbers edited, uncommitted `.apx`.

The official `apex` skill covers grammar/validate/import; it has no notion of synchronization.

## Decisions (brainstorming 2026-07-04, approved)

| Decision | Choice |
|---|---|
| Scope | Guard + assisted merge (not just detect-and-stop) |
| Trigger | Skill + blocking PreToolUse hook + agent-agnostic wrapper script |
| Location | Third skill of the `apexlang-skills` package, generic, per-project config |
| Division | architecture = WHERE? · **sync-guard = is it SAFE now?** · sentinel = does it WORK? |

## Model

**Syncpoint** = the `.apx` tree of the last synchronized state, as a git plumbing commit
(`commit-tree` + local ref `refs/apex-sync/<alias>`, never pushed) + `state.json` in
`.git/apex-sync/<alias>/` (machine-local: the Builder is per-environment).

3-way comparison in the style of `git pull` before `push`:

- **BASE** = syncpoint · **LOCAL** = working tree · **REMOTE** = Builder (materialized with
  `apex export` to scratch).
- Pre-import: if REMOTE ≠ BASE, the Builder moved → resolve before importing
  (only the Builder moved → capture into git; both moved → merge, see finding 7).
- Pre-export: dirty working tree under the APEXlang dir → stop.
- `record-sync` after every successful import/export; without it the next comparison is poisoned.

## Implementation findings (refine the original design)

1. **BASE must be canonical.** The export is byte-stable (two consecutive exports: 0 diff
   over 66 files) but does NOT textually match hand-edited `.apx` (JSON spacing, trailing
   whitespace, fenced vs inline blocks). `record-sync` therefore snapshots the **Builder
   export**, never the raw working tree: BASE↔REMOTE compares canonical-vs-canonical,
   noise-free. Only the bootstrap (BUILDER vs LOCAL, no BASE) can surface formatting-only
   diffs, exactly once.
2. **APEX dictionary timestamps cannot serve as a pre-check.** After an APEXlang import,
   `LAST_UPDATED_ON`/`CREATED_ON` are NULL in `APEX_APPLICATION_PAGES`/`APEX_APPLICATIONS`
   (the import recreates components). The original design planned a cheap timestamp
   pre-check; it was discarded — the core check is **always** export+diff (~20 s measured)
   and the timestamp remains a best-effort who/when report.
3. **`ignorePaths`** in `apex-sync.json`: repo-only artifacts inside the app dir
   (e.g. `apex-exports/`) are excluded from every comparison.
4. **Direction-aware, text-matching hook.** Separate markers `check-ok.import`/
   `check-ok.export` (TTL 10 min). The hook matches the command *text* → an `echo` or a
   commit message that mentions the trigger phrase is also blocked (accepted trade-off:
   err on the blocking side); it also evaluates the *session's* cwd, not `cd`s inside the
   command.
5. **No hard dependency on `jq`**: automatic fallback to `python3` in wrapper and hook
   (a hook dying on a missing dependency would silently disable enforcement).

## Verification performed

- writing-skills TDD: RED baseline (an agent without the skill imported directly,
  rationalizing "I assume source-first, I'll mention the risk afterwards"); GREEN in both
  directions with the skill.
- Real smoke against a live DEV instance: `check-export` blocks a dirty working tree;
  bootstrap detects divergence and preserves the scratch export; `record-sync` +
  `check-import` PASS; hook exercised on 4 synthetic cases and live (blocked real commands
  in the session).
- Full E2E against the same DEV instance (2026-07-04): bootstrap (canonical normalization
  of 4 files + first syncpoint), real REMOTE mutation via `APEX_APPLICATION_ADMIN.
  SET_APPLICATION_VERSION` (equivalent to a Builder edit) + LOCAL edit in git, FAIL
  detection with the exact diff, capture fast-path, "captured" PASS, import allowed by the
  hook, record-sync, reversal through the same flow. Final state: replicas aligned,
  version restored.

## E2E findings (protocol corrections)

6. **Circular gate fixed**: after capturing the Builder's changes into LOCAL,
   `check-import` still FAILed (BASE↔REMOTE). New PASS: Builder untouched **or** every
   Builder-side change already contained in LOCAL (importing rewrites them identically).
7. **Merge per file, not per branch**: the syncpoint commit shares no history with the
   working branch → merging an ephemeral branch produces unrelated histories and add/add
   conflicts. Validated protocol: fast-path copy when LOCAL==BASE, and
   `git merge-file <local> <base-from-ref> <export>` when both sides touched the file.
