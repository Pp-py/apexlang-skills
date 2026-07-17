# Recipe: searchable master with faceted filters

**Use for:** a directory/master list a user browses and filters (employees, products, orders) — read-only listing that links out to detail/edit.

This recipe is **read-only**: no package. Reads use inline SQL or a `v_*` view. (Writes happen on the detail/modal pages — see `modal-crud-to-package.md`.)

## Shape

1. `pageTemplate: @/left-side-column`.
2. A `facetedSearch` region in `leftColumn`, its `source.filteredRegion` pointing at the body region.
3. A body region (`cards` or `interactiveReport`) over the data. Optionally two body regions toggled by a small JS view-switch.

## `.apx`

The `facetedSearch` region auto-filters the region named by `filteredRegion` — no manual WHERE wiring. Card template settings and the link to the detail page are omitted for brevity:

```
page 10 (
    appearance { pageTemplate: @/left-side-column }

    region filters (
        type: facetedSearch
        source { filteredRegion: @cards }
        layout { slot: leftColumn }
        facet P10_F_SECTOR ( type: checkboxGroup  ... )
        facet P10_F_SEARCH ( type: search  ... )
    )

    region cards (
        type: cards
        source { type: sqlQuery  sqlQuery: ```sql
            select e.employee_id, e.employee_no, e.full_name, s.name as sector
              from hr_employees e join hr_sectors s on s.sector_id = e.sector_id
             where e.active_flag = 'Y'``` }
        layout { slot: body }
    )
)
```

## Optional dual view (cards ⇄ report)

Keep a second `interactiveReport` region over the same source, hidden by default, and toggle with a page item + minimal JS:

```
javaScript {
    functionAndGlobalVariableDeclaration: |
        function toggleView(refresh) {
            var cards = apex.region('cards'), rep = apex.region('list');
            if ($v('P10_DISPLAY_TYPE') === 'CARDS') { rep.element.hide(); cards.element.show(); if(refresh) cards.refresh(); }
            else { cards.element.hide(); rep.element.show(); if(refresh) rep.refresh(); }
        }
    executeWhenPageLoads: |
        $('#P10_DISPLAY_TYPE').change(function(){ toggleView(true); }); toggleView(false);
}
```

## Conventions

- The faceted region filters its target automatically via `filteredRegion` — no manual WHERE wiring.
- Source from a `v_*` view when the listing joins many tables or reuses an aggregation; inline SQL when it's page-local.
- Link columns carry the PK to the detail/edit page (`items { P20_ID: #EMPLOYEE_ID# }  clearCache: 20`).
- Vanilla JS only for view toggles. No SPA framework.
