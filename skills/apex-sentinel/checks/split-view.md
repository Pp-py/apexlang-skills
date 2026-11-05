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
6. **Back from empty.** After step 5, clear the filter. Assert the empty-state region is hidden, the
   context item is non-empty and names a row that is in the list, and the detail regions show *that*
   row, not a blank or half-refreshed pane (on the `rowSelection` variant that row is also the
   highlighted one). In Oracle's catalog the handler that refreshes the details skips a null item, so
   leaving the empty state is the case a copy of it can miss.
7. **Paging**, only on the `rowSelection` variant (visible selection and reconciliation) and only when
   the data has more rows than one page: select a row, change page; separately, filter so the
   selected row survives but moves off the first page. At rest one `eval` reads three things — the
   highlighted row, the context item, the identifying value in the detail regions — and they name the
   same record. On `fullRowLink` or the tree nothing highlights or reselects, and with a single page
   there is nothing to page: record `SPLIT-PAGE-RECONCILES` NOT_RUN with that reason.

**Not covered yet (deferred).** Where focus lands after a reconcile, two quick selections A then B,
and whether the change of detail is announced (WCAG 4.1.3) are not steps here: the first two are
races or need a slowed response, `pw.sh` has no induced delay, so a PASS would not be diagnostic, and
the announcement needs an assistive-technology read. They wait for an induced delay in `pw.sh`.

## Confirm

Spot-check one detail value against `sql -name <conn>` for the selected PK — a detail pane bound to
the wrong item renders plausible data from the wrong row, which no UI assertion catches.

## Pass criteria

Each criterion has an ID: a runtime-result (`framework/schemas/runtime-result.schema.json`) reports it by that ID, with what was observed and the evidence it rests on.

`SPLIT-PAGE-RECONCILES` applies to one variant only: where it does not, record it `required: false`,
status `NOT_RUN`, with a `notApplicableReason` — never `required: true`, which `evidence.py` turns
into UNKNOWN for the whole gate.

- `SPLIT-INITIAL-SELECTION` — Page opens with a selection and a populated detail (or an explicit empty state).
- `SPLIT-DETAIL-FOLLOWS` — Selecting another row moves **all** detail regions.
- `SPLIT-FILTER-RECONCILES` — Filtering never leaves the detail on a row that is no longer in the list.
- `SPLIT-EMPTY-STATE` — Zero results shows the empty state, not a stale detail.
- `SPLIT-EMPTY-RETURN` — After the filter clears from zero rows, the empty state is hidden, the context item names a listed row and the detail regions show that row, not a stale or blank pane.
- `SPLIT-PAGE-RECONCILES` — On the `rowSelection` variant with more than one page, after a page change or a filter that moves the selected row off the first page, the highlighted row, the context item and the detail name the same record.
- `SPLIT-NO-CONSOLE-ERRORS` — No `console` errors and no leftover debug logging from the reconcile handler.
