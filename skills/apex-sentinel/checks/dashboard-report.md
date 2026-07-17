# Check: dashboard / analytical report

**Verifies** `apexlang-architecture/recipes/dashboard-kpis-charts.md` and `analytical-report.md`. Read-only — no write, so the check is about **rendering real values**, not interaction.

**REQUIRED BACKGROUND:** `setup.md` and `SKILL.md` §Snapshot diet.

## Dashboard (KPIs + charts)

1. Navigate (`?session=<token>`).
2. Read every KPI value with one `eval` — e.g. `[...document.querySelectorAll('.t-Card, [class*="value"]')].map(c => c.innerText)` scoped to the KPI regions — and assert each is **non-empty, numeric** — not blank, not `#NULL#`, not an error string. (A KPI sourced from a broken scalar subquery renders the card chrome but an empty/garbage metric — validate never catches this.)
3. Assert each chart region is present and not showing "No Data Found" when data is expected (`eval` for the region + that text). Charts render to canvas/SVG; **this is the one place a screenshot earns its cost** — if the a11y tree/DOM text is thin, screenshot to confirm bars/lines actually drew.
4. Spot-check one KPI against SQLcl: run the same count and compare — the number must match.

## Analytical report (IRs + charts)

1. Navigate; assert the IR renders **≥1 data row** for the current filter (`eval` the IR region's row count or absence of the "no rows" message) — not an empty "no rows" when rows are expected.
2. If the page toggles views (`serverSideCondition` on a `:Px_VIEW` item), change the toggle and assert the **other region appears** and the first hides (`eval` both regions' visibility).
3. Assert any badge/`htmlExpression` column rendered as markup (a pill/label), not as escaped HTML text — `eval` that the cell contains an element, not a literal `&lt;span&gt;`.

## Pass criteria

- Every KPI shows a real number (matches a SQL spot-check); charts drew.
- IR returns expected rows; view toggle swaps regions; badges render as HTML.
- No empty/error tiles where data is expected.
