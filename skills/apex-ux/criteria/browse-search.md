# Browse and search — `UXBRW`

Recipes: `browse-interactive-report.md`, `master-faceted-search.md`, `analytical-report.md`. Runtime companion: `apex-sentinel/checks/browse-search.md`.

| ID | Criterion | Sev | By | Source |
|---|---|---|---|---|
| `UXBRW-PATTERN-FIT` | the result primitive fits the task — an Interactive Report when users sort, filter, save views or export; Cards when each record is a distinct item; Content Row for compact scanning — and a deviation from the default says why in `comments` | ADVISE | manual + static | Oracle region-contracts; repo `ui-contracts.md` §1, §9; ex: CAT 26.1.6 browse-search |
| `UXBRW-ROW-ACTIONS` | each row shows at most one visible primary action; further row actions go to a row menu | ADVISE | static | ex: CAT 26.1.6 browse-interactive-report |
| `UXBRW-LINK-COLUMN` | a report's drill-down is a column of `type: link` with a declarative target and a link text that names the row ("Edit sector SALES"), not a region-level link | ADVISE | static | repo `ui-contracts.md` §3, `references/oracle-26.1-lint.md` |
| `UXBRW-FILTER-LABELS` | every search box and facet has a visible label and help | ADVISE | static | Oracle smart-filter-search |
| `UXBRW-FACET-ORDER` | facets run search, then categorical, then range; high-cardinality facets show their filter box; current facets and the total row count are shown | ADVISE | static | Oracle faceted-search |
| `UXBRW-SEARCH-CASE` | text search ignores case | ADVISE | static + runtime | Oracle interactive-report |
| `UXBRW-RESULT-ANNOUNCE` | after a filter or search, the new result count is shown and announced through the region's native behaviour | ADVISE | runtime | Oracle smart-filter-search; WCAG 4.1.3 |
| `UXBRW-NO-RESULTS` | a search with no results says so and suggests the next step (clear a facet, try other words) | ADVISE | static + runtime | ex: CAT 26.1.6 full-page-search |
| `UXBRW-HEADINGS` | every visible column has a heading a user understands, not the column name | ADVISE | static | Oracle interactive-report |
