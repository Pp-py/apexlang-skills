# Live checks

What only a real APEX instance and a real browser can show. Run them **against a DEV
workspace only**, record each run in the framework's format (a task directory under the
evidence dir, its results, a manifest) and add a row to
[CAPABILITIES.md](../../framework/CAPABILITIES.md) §Recorded runs. Until a run is on file, its
matrix cell says `not recorded`.

**Risk and rollback.** L1 imports into the Builder and exports into the working tree —
the very overwrites the guard exists to prevent. Use a throwaway copy of an app in DEV
(`apex export` it first and keep the files), on a branch of the project repo. Rollback:
re-import the kept export, `git checkout` the branch, `git update-ref -d refs/apex-sync/<alias>`.

## L1 — the sync protocol against a real Builder

Prerequisites: `apex-sync.json` for the copy (`setup.md` §1), `apex-sync-check.sh doctor` all OK.

1. `check-import --task L1` on a clean repo with no syncpoint → PASS, first syncpoint
   (or CONFLICT, BOOTSTRAP_DIVERGED: reconcile once, `setup.md` §2).
2. Edit a page in the Builder → `check-import` → **CONFLICT**, `BUILDER_DIVERGED`, the page in
   `changes[]`; the hook blocks `apex import`.
3. Copy the page from the kept export into LOCAL, commit → `check-import` → PASS,
   `BUILDER_CHANGES_CAPTURED`; import; `record-sync` → PASS, `basis: fresh-check`.
4. Dirty a file under the source dir → `check-export` → **FAIL**, `LOCAL_DIRTY`; commit;
   `check-export` → PASS; export; `record-sync` → PASS, `basis: local-equals-builder` (or
   `fresh-check`, while step 3's `check-import` PASS is under 10 minutes old).
5. Every result in `.apex-evidence/L1/` validates (`tests/contract/schemas.py --captured`
   pointed at a copy of it).

**L1b** — with two apps in `apps[]`: steps 2–3 for one app leave the other's syncpoint and
markers untouched; a command naming the other app's dir stays blocked.

## L2 — the hook in a live session

`skills/apex-sync-guard/setup.md` §4: the four rows of its table, in an isolated
`CLAUDE_CONFIG_DIR`, with `echo` commands only.

## L3 — the compiler

```bash
SQLCL_BIN=<path to sql or sql.exe> tests/upstream/validate-examples.sh --compiler
```

Offline (`/nolog`); records what SQLcl's `apex validate` says about the examples on Oracle's
26.1 scaffold. A FAIL is recorded as a FAIL (KC-7), never allowlisted.

## L4 — the runtime walkthroughs

`skills/apex-sentinel/examples/sectors-catalog.md` and `absences-workflow.md` against the
deployed example slices, through `pw.sh` with a dedicated low-privilege test user; one
`runtime-result` per walkthrough, criteria by ID, raw evidence under `raw/runtime-<alias>/`.

## L5 — Windows

The integration tier under Git Bash on a Windows machine with a Windows SQLcl on `PATH`
(CI covers the stubbed tier on `windows-latest`), plus L2 in a Windows Claude Code
session — the `PowerShell` half of the matcher.
