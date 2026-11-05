# Check: browse & faceted search

**Verifies** `apexlang-architecture/recipes/master-faceted-search.md`. Read-only — the check is
that **filtering actually filters** (the right predicate, not merely fewer rows), and that the row the
user clicks opens the right record.

**REQUIRED BACKGROUND:** `setup.md` and `SKILL.md` §Snapshot diet.

**Two numbers, never confused.** The **total** is the region's own count text: the pagination
"1 - 20 of N", the `totalRowCountSelector` target, an interactive report's row text. **Rendered** is
the DOM rows of the current page — at most one page, so it cannot show a filter (100 rows filtered
to 60 still render 20). Compare totals; read rendered rows only for their content. Every expected
total comes from `sql -name <conn>`, run with the predicate the facet expresses **before** the
click. A filter that returns *plausible* rows for the wrong predicate is invisible in the browser.

## Steps

1. Navigate (`?session=<token>`). Assert the results region rendered rows and record the **baseline
   total** with one `eval` (the count text, plus the rendered count: `.a-CardView-item`,
   `.t-ContentRow-item`, or the IR's row elements). Take **one** snapshot only, to locate the facet
   controls' refs. A page with no count text is read by rendered rows only when the SQL total fits
   one page; otherwise record `BROWSE-FACET-COUNT` NOT_RUN with that reason.
2. **Apply one facet** (`click` a checkbox / type in the search facet) whose value **discriminates**:
   pick it from SQL, a value whose count is strictly between 0 and the baseline total. Assert with a
   single `eval`: the total equals the SQL count, and the facet chip is present. Then add a facet of
   another group (AND across groups) and assert the total equals the SQL count of the combination.
   Reading it: a total still at the baseline means the region is not the `filteredRegion`, or
   something re-filters it manually — the classic symptom of a hand-wired WHERE clause fighting the
   faceted region; a total that moved but differs from SQL means the wrong predicate. A value that
   covers every row leaves the total unchanged by design: it proves nothing, pick another.
3. **Clear it** and assert the total returns to the baseline. A total that does not come back means
   the facet state is leaking into session state.
4. **Range facet** (date/amount), if present: set it and assert it filters as **one** item — a page
   exposing `_FROM` / `_TO` items for a single range facet is the defect, visible in the DOM.
5. **Selector mode**, if the results header is hidden: assert `#total_row_count` (or whatever
   `totalRowCountSelector` names) actually **contains a number**, and the current-facets container is
   populated. An empty count element is the usual sign the selector never matched — the region
   rendered before its target existed.
6. **Zero results:** filter to a combination SQL says is empty and assert the region shows its
   no-data message (`messages.whenNoDataFound`), not a blank frame.
7. **Drill-down:** `click` the row/card action and assert the detail page opened **with the right
   record** — `eval` the PK item's value or the detail title, and assert no checksum error region
   (`argumentsMustHaveChecksum` plus a hand-built `f?p=` URL is a frequent break; a declarative
   `behavior.target` lets APEX add the checksum — `apexlang-architecture/ui-contracts.md` §3).
8. **Dual view**, if the page declares a `regionDisplaySelector`: switch views and assert the other
   region is visible **and still filtered** — the same total as the active facet produced (= SQL),
   not the unfiltered set. One `facetedSearch` names one region; the second view is wired by hand or
   absent (`master-faceted-search.md`), and this step is what tests that wiring.
9. **Search box** — a text item that refreshes the region (not a facet, not an IR's own search bar),
   if the page has one (`master-faceted-search.md`, "A search box that is a page item"). Read the
   *state* in one `eval` per case — landing prompt visible, results visible, total, no-data message
   visible — not only the count: (a) empty box: Initial, the landing prompt and no results;
   (b) **spaces only**: Initial too — the term is trimmed on the client *and* in the SQL, so a blank
   term is never searched; results under a landing prompt, or every row listed for blank input, is
   FAIL; (c) a term with a known count: the total equals `sql -name <conn>` run with the same
   trimmed, case-folded term; (d) a term matching nothing: the no-data message with its next step;
   (e) clear the box: back to (a). Also reload with the blank value kept in session state: Initial.
   What the browser cannot see is whether the SQL trims too (the client already did): read it in the
   `.apx`. Not exercised, on purpose: the loading and error states (no verified source here for how
   APEX renders them for a page-item search, and an error cannot be induced without breaking the
   app) and a fast A-then-B typing race (`pw.sh` cannot slow a response, so a PASS would not be
   diagnostic).

## Cards and content rows specifically

Assert the row actually rendered its payload, not just its chrome: `eval` that a sample card has
non-empty title text, that a badge element exists where a state column is mapped, and — when media is
mapped — that the image resolved (`naturalWidth > 0`, not a broken `img`). A cards region over a
query missing its `card.primaryKeyColumn1` or with a null media URL renders a tidy row of empty
boxes, and `validate` never sees it.

## Pass criteria

Each criterion has an ID: a runtime-result (`framework/schemas/runtime-result.schema.json`) reports it by that ID, with what was observed and the evidence it rests on.

A criterion about a feature the page does not have (`BROWSE-FACET-TARGETS`, `BROWSE-ROW-CONTENT`,
`BROWSE-SEARCH-STATES`, and the facet ones on a page with no facets) is recorded `required: false`,
status `NOT_RUN`, with a `notApplicableReason` — never `required: true`: `evidence.py` derives
UNKNOWN from a required criterion left NOT_RUN, and the gate would stay open on every page without
that feature.

- `BROWSE-FACET-COUNT` — With a discriminating facet value, and with an AND across two groups, the region's **total** equals the SQL count of the predicate; clearing restores the baseline total. Rendered rows alone never satisfy it, and a matching total does not prove the same rows (this check does not walk the pages).
- `BROWSE-FACET-TARGETS` — Selector-mode count and current-facets targets are populated when used.
- `BROWSE-NO-DATA` — Zero results shows the no-data message.
- `BROWSE-ROW-CONTENT` — Cards/content rows render title, badge and media — no empty boxes, no broken images.
- `BROWSE-ROW-LINK` — The row's link opens the right record with no checksum error.
- `BROWSE-SEARCH-STATES` — A page-item search shows Initial for an empty or blank term, the matching rows (total = SQL) for a term with a known count, the no-data message for a term matching nothing, and returns to Initial when cleared.
