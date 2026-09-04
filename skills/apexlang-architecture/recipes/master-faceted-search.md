# Recipe: searchable master with faceted filters

**Use for:** a directory/master list a user browses and filters (employees, products, orders) —
read-only listing that links out to detail/edit.

This recipe is **read-only**: no package. Reads use inline SQL or a `v_*` view. (Writes happen on the
detail/modal/drawer pages — see `modal-crud-to-package.md`, `form-page-to-package.md`.)
Data-side rules: `ui-contracts.md`.

The facet grammar itself — valid facet types, `listEntries` limits, `source.dataType` per type,
region placement, naming — is fully specified by the official `apex.faceted-search.md`. What follows
is only what it leaves to the architect.

## Shape

1. `pageTemplate: @/left-side-column`.
2. A `facetedSearch` region in `leftColumn`, its `source.filteredRegion` pointing at the body region.
3. A body region over the data. It auto-filters — no manual WHERE wiring, no `pageItemsToSubmit`.

```
page 10 (
    appearance { pageTemplate: @/left-side-column }

    region filters (
        type: facetedSearch
        source { filteredRegion: @results }
        layout { slot: leftColumn }
        facet P10_F_SECTOR   ( type: checkboxGroup  lov { type: distinctValues } ... )
        facet P10_F_HIRED_ON ( type: range  source { dataType: date } ... )
        facet P10_F_SEARCH   ( type: search  ... )
    )

    region results (
        type: cards
        source { type: sqlQuery  sqlQuery: ```sql
            select employee_id, full_name, sector_name, status_label, badge_state, photo_url
              from v_employee_browse``` }
        layout { slot: body }
    )
)
```

## Choosing the facet type

Grammar aside, the decision is about the shape of the domain:

| The column is | Facet |
|---|---|
| A short closed list the user combines (sectors, statuses) | `checkboxGroup` |
| A short closed list where only one value makes sense at a time | `radioGroup` (`hideRadioButtons: true` reads as a link list) |
| High-cardinality (employee, supplier, SKU) | `checkboxGroup` with the facet-value search enabled, or drop it and rely on `search` |
| Free text across several columns | `search` |
| A date or amount window | `range` with `source.dataType: date` / `number` |
| A handful of independent booleans | `checkbox` facets grouped in one `facetGroup` |

Two failure modes: a facet over a column the user cannot reason about (a surrogate id, a technical
flag) is noise; and a range facet split into `_FROM` / `_TO` items is wrong — one range facet is one
item.

## Choosing the results body

`cards`, `contentRow` and `interactiveReport` all work as the filtered region. Pick with
`ui-contracts.md` §1: media/recognition → `cards`; dense vertical scanning → `contentRow`; the user
needs sorting, personalisation, export → `interactiveReport`.

**This is a documented deviation.** The official default results region is a Classic Report with its
header visible, and hiding a region header is listed there as an anti-pattern — yet the catalog's
own browse patterns (`p00210` cards, `p00220` content row) hide it, because the count and the active
facets move up into the title bar. Fine, provided the reason is in the region's `comments`
(`ui-contracts.md` §9). No reason in the source means take the default.

## Count and active facets in the title bar

Selector mode is opt-in officially, and this is the case that earns it: once the results header is
hidden, the row count and the active-facet chips have nowhere to live.

```
settings {
    showCurrentFacets: selector   currentFacetsSelector: #active_facets
    showTotalRowCount: selector   totalRowCountSelector: #total_row_count
}
```

Then an empty region (`advanced.htmlDomId: active_facets`) and a `<span id="total_row_count">` in the
title-bar region are the render targets. Both selectors must exist in the DOM before the region
renders, or the facet region silently drops them. Skip all of this when the results region keeps its
own header — the defaults already show both.

## Variant — filters behind a dialog

When the left column is needed for the list itself (a split view, `split-view-selection.md`), keep
the facets but expose them only through the Add Filter dialog:

```
facet P33_F_STATUS ( type: checkboxGroup  appearance { display: addFilterDialog }  ... )
```

Officially inline is the default and this is the exception — same rule, write the reason down.

## Variant — two views over one source

Cards for browsing, report for scanning, same query. Declare both regions and let the theme switch
them:

```
region view-switch ( type: regionDisplaySelector  layout { slot: body } )
region results  ( type: cards              advanced { regionDisplaySelector: true } ... )
region results-list ( type: interactiveReport  advanced { regionDisplaySelector: true } ... )
```

No JavaScript, no page item, and both regions stay filtered by the same `facetedSearch`. (Hand-rolled
`apex.region().refresh()` toggles are only worth it if the choice must persist per user — then it is
a preference to store, not a view to hide.)

## Conventions

- The faceted region filters its target automatically via `filteredRegion` — no manual WHERE wiring.
- Source from a `v_*` view when the listing joins many tables or reuses an aggregation; inline SQL
  when it's page-local. The view is also where the badge state token and the detail URL come from
  (`ui-contracts.md` §2–§3).
- Link out with the PK: `items { P20_ID: #EMPLOYEE_ID# }  clearCache: 20` on a report column, or
  `action.behavior.target: &EDIT_LINK` on a card.
- One row = one entity. A facet over a query that already aggregates counts filters the aggregate,
  not the rows, and the numbers stop adding up.

## Verify

`apex-sentinel/checks/browse-search.md`: applying a facet lowers the row count (not just adds a chip),
clearing it restores the baseline, selector-mode counts actually fill, zero results shows the no-data
message, and the row link opens the right record without a checksum error.
