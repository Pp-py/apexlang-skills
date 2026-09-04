# Check: browse & faceted search

**Verifies** `apexlang-architecture/recipes/master-faceted-search.md`. Read-only — the check is that
**filtering actually filters**, and that the row the user clicks opens the right record.

**REQUIRED BACKGROUND:** `setup.md` and `SKILL.md` §Snapshot diet.

## Steps

1. Navigate (`?session=<token>`). Assert the results region rendered rows and record the **baseline
   count** with one `eval` — the region's row count (`.a-CardView-item`, `.t-ContentRow-item`, or the
   IR's row elements), plus the pagination/count text if the page shows one. Take **one** snapshot
   only, to locate the facet controls' refs.
2. **Apply one facet** (`click` a checkbox / type in the search facet). Assert with a single `eval`:
   the row count **dropped**, and the facet chip is present. A chip with an unchanged count means the
   region is not the `filteredRegion`, or something re-filters it manually — the classic symptom of a
   hand-wired WHERE clause fighting the faceted region.
3. **Clear it** and assert the count returns to the baseline. A count that does not come back means
   the facet state is leaking into session state.
4. **Range facet** (date/amount), if present: set it and assert it filters as **one** item — a page
   exposing `_FROM` / `_TO` items for a single range facet is the defect, visible in the DOM.
5. **Selector mode**, if the results header is hidden: assert `#total_row_count` (or whatever
   `totalRowCountSelector` names) actually **contains a number**, and the current-facets container is
   populated. An empty count element is the usual sign the selector never matched — the region
   rendered before its target existed.
6. **Zero results:** filter to nothing and assert the region shows its no-data message
   (`messages.whenNoDataFound`), not a blank frame.
7. **Drill-down:** `click` the row/card action and assert the detail page opened **with the right
   record** — `eval` the PK item's value or the detail title, and assert no checksum error region
   (`argumentsMustHaveChecksum` plus a hand-built `f?p=` URL is a frequent break; a card action must
   carry a `apex_page.get_url`-built link).
8. **Dual view**, if the page declares a `regionDisplaySelector`: switch views and assert the other
   region is visible **and still filtered** — same row count as the active facet produced, not the
   unfiltered set.

## Cards and content rows specifically

Assert the row actually rendered its payload, not just its chrome: `eval` that a sample card has
non-empty title text, that a badge element exists where a state column is mapped, and — when media is
mapped — that the image resolved (`naturalWidth > 0`, not a broken `img`). A cards region over a
query missing its `card.primaryKeyColumn1` or with a null media URL renders a tidy row of empty
boxes, and `validate` never sees it.

## Confirm

`sql -name <conn>`: run the same predicate the facet expresses and compare the count with what the UI
showed. A filter that returns *plausible* rows for the wrong predicate is invisible in the browser.

## Pass criteria

- Applying a facet lowers the count; clearing it restores the baseline.
- Selector-mode count and current-facets targets are populated when used.
- Zero results shows the no-data message.
- Cards/content rows render title, badge and media — no empty boxes, no broken images.
- The row's link opens the right record with no checksum error.
