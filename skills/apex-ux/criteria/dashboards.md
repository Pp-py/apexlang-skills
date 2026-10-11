# Dashboards — `UXDASH`

Recipe: `apexlang-architecture/recipes/dashboard-kpis-charts.md`. Runtime companion: `apex-sentinel/checks/dashboard-report.md`.

| ID | Criterion | Sev | By | Source |
|---|---|---|---|---|
| `UXDASH-KPI-METRICCARD` | aggregate KPIs are a `themeTemplateComponent/metricCard` region, never a Classic Report or a `cards` region | ADVISE | static | Oracle dashboard |
| `UXDASH-KPI-COUNT` | a KPI row holds 2 to 6 KPIs; more is a second row or a different page | ADVISE | static | Oracle layout; ex: CAT 26.1.6 dashboard-simple (4) |
| `UXDASH-KPI-CONTEXT` | each KPI shows its value, a short title and its context — the period, the target or the unit — and keeps the thousands separator | ADVISE | static + manual | Oracle dashboard; ex: CAT 26.1.6 metrics ("KPI Scorecards") |
| `UXDASH-TREND-TEXT` | a trend or threshold badge carries its value as text and an icon whose direction agrees with it; colour follows meaning, not the sign | ADVISE | static + manual | WCAG 1.4.1; repo `dashboard-kpis-charts.md`. The example catalog colours "-14 items" danger by sign: do not copy it |
| `UXDASH-STATUS-REASON` | a status (on track, at risk) is shown with its reason ("-4% vs target") | ADVISE | manual | ex: CAT 26.1.6 dashboard-executive |
| `UXDASH-CHART-FIT` | each chart type fits its question — line or area for change over time, bar for comparison and ranking, pie or donut only for a part-to-whole with few categories (at most 6) | ADVISE | manual | Oracle dashboard; ex: CAT 26.1.6 charts |
| `UXDASH-CHART-TEXT` | each chart has a title that states what it shows, labelled axes with units, and its data reachable as text (a nearby report or the data cursor) | ADVISE | static + manual | WCAG 1.1.1, 1.4.1; Oracle chart-page |
| `UXDASH-CHART-ROWS` | charts sit side by side in planned rows (2-up, 3-up), not stacked, unless one is a full-width detail section | ADVISE | static | Oracle dashboard |
| `UXDASH-DRILLDOWN` | every KPI and chart that raises a question has a follow-up path — the card's own link only when all cards open one page with their own key, otherwise one action in the region header's `slot: edit` (a text link when the follow-up is common, an icon button when it is secondary) or the report next to it; a purely informational region has none | ADVISE | static | Oracle region-contracts, region-interactions; repo `dashboard-kpis-charts.md` |
| `UXDASH-FILTER-TOP` | dashboard filters sit at the top of the body and refresh every region they affect | ADVISE | static + runtime | Oracle dashboard |
| `UXDASH-NO-ENTRY` | a dashboard reads; it carries no data-entry form | ADVISE | static | Oracle dashboard |
