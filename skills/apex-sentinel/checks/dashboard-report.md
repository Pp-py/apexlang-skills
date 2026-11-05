# Check: dashboard / analytical report

**Verifies** `apexlang-architecture/recipes/dashboard-kpis-charts.md` and `analytical-report.md`. Read-only — no write, so the check is about **rendering real values**, not interaction.

**REQUIRED BACKGROUND:** `setup.md` and `SKILL.md` §Snapshot diet.

## Dashboard (KPIs + charts)

1. Navigate (`?session=<token>`).
2. Read every KPI value with one `eval` — e.g. `[...document.querySelectorAll('.t-Card, [class*="value"]')].map(c => c.innerText)` scoped to the KPI regions — and assert each is **non-empty, numeric** — not blank, not `#NULL#`, not an error string. (A KPI sourced from a broken scalar subquery renders the card chrome but an empty/garbage metric — validate never catches this.)
3. Assert each chart region is present and not showing "No Data Found" when data is expected (`eval` for the region + that text). Charts render to canvas/SVG; **this is the one place a screenshot earns its cost** — if the a11y tree/DOM text is thin, screenshot to confirm bars/lines actually drew.
4. Spot-check one KPI against SQLcl: run the same count and compare — the number must match.
5. **Time order.** For a chart whose categories are time (months, weeks, days), compare the order it **drew** with the order of the time key — a correct neighbouring table proves nothing about the chart (a series ordered by its label draws "Agosto, Julio, Junio, Noviembre…" next to a chronological table). Expected: from SQLcl, the same labels formatted with the page's mask and NLS, `order by` the **date** column, never the label. Rendered: read the chart's own text and order it by **position** (DOM order is not visual order), then compare with that sequence — never "is it sorted?", which an alphabetical chart passes:

   ```js
   () => {
     const expected = ['<label 1, earliest>', '<label 2>', '…'];            // from SQLcl, time order
     const svg = document.querySelector('#<static-id> svg');                // horizontal-bar charts: sort by .top
     const hit = [...svg.querySelectorAll('text')].map(t => ({ t: t.textContent.trim(), x: t.getBoundingClientRect().left }))
       .filter(o => expected.includes(o.t));
     const seen = hit.map(o => o.t);
     const duplicated = expected.filter(e => seen.filter(s => s === e).length > 1);
     const drawn = hit.sort((a, b) => a.x - b.x).map(o => o.t);
     const missing = expected.filter(e => !seen.includes(e));
     return { drawn, missing, duplicated,
              ok: !duplicated.length && !missing.length && JSON.stringify(drawn) === JSON.stringify(expected) };
   }
   ```

   `ok: false` with nothing `missing` and nothing `duplicated` is a **FAIL**. An expected label that appears more than once in the chart's text (a twin axis, a legend or a tooltip repeating it) is **UNKNOWN**: the snippet cannot tell which one is the axis. So is a label not drawn (a thinned axis) and a chart with no readable text (canvas, a screenshot only) — never PASS. A window that crosses a year boundary (Nov → Dec → Jan) is the case an alphabetical or year-less sort gets wrong: say in `observed` whether the window crossed one; if it did not, say that too, and do not write rows into the app to force it.

## Analytical report (IRs + charts)

1. Navigate; assert the IR renders **≥1 data row** for the current filter (`eval` the IR region's row count or absence of the "no rows" message) — not an empty "no rows" when rows are expected.
2. If the page toggles views (`serverSideCondition` on a `:Px_VIEW` item), change the toggle and assert the **other region appears** and the first hides (`eval` both regions' visibility).
3. Assert any badge/`htmlExpression` column rendered as markup (a pill/label), not as escaped HTML text — `eval` that the cell contains an element, not a literal `&lt;span&gt;`.

## Pass criteria

Each criterion has an ID: a runtime-result (`framework/schemas/runtime-result.schema.json`) reports it by that ID, with what was observed and the evidence it rests on.

- `DASH-KPI-VALUES` — Every KPI shows a real number (matches a SQL spot-check); charts drew.
- `DASH-CHART-ORDER` — A chart whose categories are time draws them in time order: the rendered label sequence equals the SQL's, ordered by the date key (also across a year boundary); a label that repeats in the chart's text, or one not drawn, is UNKNOWN. `NOT_RUN` when the page has no time-axis chart.
- `DASH-REPORT-ROWS` — IR returns expected rows; view toggle swaps regions; badges render as HTML.
- `DASH-NO-EMPTY-TILES` — No empty/error tiles where data is expected.
