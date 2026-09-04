# Check: split view (master list or tree + detail panes)

**Verifies** `apexlang-architecture/recipes/split-view-selection.md`. Read-only page — the check is
about the **detail following the selection**, and surviving a filter.

**REQUIRED BACKGROUND:** `setup.md` and `SKILL.md` §Snapshot diet.

## Steps

1. Navigate (`?session=<token>`). Assert the master list rendered rows and that a selection already
   exists: `eval` → `apex.item('Px_<CONTEXT>').getValue()` is non-empty **and** the empty-state
   region is hidden. A page that opens with an empty detail and no empty state is the most common
   defect here.
2. Read one identifying value out of a detail region (`eval` of the region's text). Then select a
   **different** row (`click` its row link — one snapshot to locate the ref, no re-snapshotting) and
   assert two things with a single `eval`: the context item changed, and the detail text changed with
   it. Same text after a new selection means a detail region is missing `pageItemsToSubmit` — it
   rendered once against a stale session value.
3. Assert **every** detail region moved, not just the first. Collect their texts in one `eval` (the
   shared refresh class makes this one selector) and compare against step 2's snapshot of the same
   set. A region that never changes is the one that forgot the refresh class or the bind.
4. **Filter, then check reconciliation.** Apply a facet or type in the search that keeps the current
   row out of the result set. Assert: the list shrank, a valid row is selected, and the detail
   matches *that* row — not the row that disappeared. This is the step the two-item variant exists
   for; on the `fullRowLink` default assert at least that the detail is not showing a filtered-out
   record.
5. Filter to **zero** rows and assert the empty-state region is visible and the detail regions are
   hidden or empty.

## Confirm

Spot-check one detail value against `sql -name <conn>` for the selected PK — a detail pane bound to
the wrong item renders plausible data from the wrong row, which no UI assertion catches.

## Pass criteria

- Page opens with a selection and a populated detail (or an explicit empty state).
- Selecting another row moves **all** detail regions.
- Filtering never leaves the detail on a row that is no longer in the list.
- Zero results shows the empty state, not a stale detail.
- No `console` errors and no leftover debug logging from the reconcile handler.
