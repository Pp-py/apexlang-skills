# Example: absences workflow (state machine → package verbs)

Absence requests that move REQUESTED → APPROVED / REJECTED, plus soft-delete (cancel).
Transitions are **named package operations** with a legal from-state guard, not raw
`UPDATE status`. The UI never sets `status` directly.

Implements `apexlang-architecture/recipes/workflow-state-transitions.md`.
Verify it with `apex-sentinel/examples/absences-workflow.md`.

## Files

| File | What |
|---|---|
| `01-ddl.sql` | `hr_absences` table (status + audit/cancel columns), seed: one REQUESTED, one APPROVED |
| `02-pkg_absences.sql` | verbs `create_row`/`approve`/`reject`/`cancel`, each guarding the legal from-state |
| `03-page-absences.apx` | master IR (page 60): status badge rendered from a CSS token, resolve link on the column |
| `04-page-absence-resolve.apx` | resolve modal (page 62) gated by `:REQUEST`, with the `VAL_`-prefixed validation |

One page per file, named `p<5-digit page>-<alias>.apx` in the app tree: the validator checks that a page file's number and alias match its filename (`PAGE_FILENAME_NUMBER_MISMATCH_001`, `PAGE_ALIAS_FILENAME_MISMATCH_001`), so page 60 and page 62 cannot share a file. The `03-`/`04-` prefixes here only convey deploy order — rename to `p00060-absence-requests.apx` / `p00062-absence-resolve.apx` when you copy them in.

## Deploy (run in order)

```bash
# 1. shared core (skip if already loaded by the sectors slice)
sql -name <conn> @../00-pkg_errors.sql
sql -name <conn> @../00-error_handling_function.sql      # then register it (see that file's header)

# 2. this slice
sql -name <conn> @01-ddl.sql
sql -name <conn> @02-pkg_absences.sql

# 3. the pages — validate BEFORE importing
apex validate -input <apexlang-src-dir>                   # copy both .apx into your app's pages/ first
apex import   -input <apexlang-src-dir>
```

> Validated against APEXlang **2026.08.01**: page 62 is clean; page 60 reports only
> `BREADCRUMB_COVERAGE_ENTRY_REQUIRED_001`, which is satisfied by adding a `pageNumber: 60`
> entry to **your** app's `shared-components/breadcrumbs.apx` — a page file cannot carry it.
> Re-validate against your own APEX version before importing, and mind that page numbers
> (60/62) and aliases must not collide with your app's.

## Notes

- **Badges** use Universal Theme text-color classes (`u-color-*-text`) so they render
  without custom CSS. Swap for your own pill classes if you have them.
- **Close-on-success:** page 62 ships a `closeDialog` process (last sequence, gated by
  `:REQUEST in ('APPROVE','REJECT')`) and page 60 an `apexafterclosedialog` → refresh
  dynamic action — a successful transition closes the modal and the master refreshes;
  a guard error keeps the modal open on the friendly message.

## What "done" looks like

- Master shows rows with **status badges** (Requested / Approved / Rejected).
- Opening the REQUESTED row and clicking **Approve** closes the modal, the master
  refreshes on its own, and the row flips to APPROVED with `approved_by` / `approved_at`
  stamped.
- Trying to approve the already-APPROVED row hits the guard:
  `Only an absence in REQUESTED status can be approved.` (friendly, no `ORA-` prefix),
  and `status` is unchanged.
