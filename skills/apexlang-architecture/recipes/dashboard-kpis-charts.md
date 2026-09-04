# Recipe: home dashboard (KPI cards + charts)

**Use for:** a landing page with a strip of KPI numbers and one or more charts.

Read-only: **no package**. KPI scalars and chart series read straight from tables/views.
Data-side rules: `ui-contracts.md`.

Composition, the 12-column row planning (`layout_row_plan`, `startNewRow`), the valid
`settings.layout` values and the filter/refresh wiring are specified in the official
`apex.dashboard.md`. This recipe covers what it does not: where the aggregation lives, what the SQL
must project, and how a KPI earns its badge.

**Contents:** KPI cards with `metricCard` (and when to drop to built HTML) · the badge as a semantic
group · where the aggregation lives · charts and their rules · drill-down and detail actions ·
conventions · verify.

## KPI cards — prefer the native `metricCard` region

One region, one SQL query returning **one row per card**. Declarative, round-trips cleanly,
responsive layout for free. Reach for this first — aggregate numbers in a `cards` region (or worse,
a Classic Report) is a review finding.

```
region kpis (
    name: Today's indicators
    type: themeTemplateComponent/metricCard
    source { type: sqlQuery  sqlQuery: ```sql
        select 1 id, 'Active employees' title,
               to_char((select count(*) from hr_employees where active_flag='Y')) metric,
               'current headcount' meta, 'fa-users' icon,
               apex_page.get_url(p_page => 10) link
          from dual
        union all
        select 2, 'Present today',
               to_char((select count(distinct c.employee_id) from hr_clockings c
                         where c.clocking_date = trunc(sysdate) and c.cancelled_at is null)),
               'clocked in today', 'fa-check', apex_page.get_url(p_page => 70) from dual``` }
    settings { title: &TITLE.  metric: &METRIC.  meta: &META.  link: &LINK.  layout: 3Columns }
    plugin-avatar { displayAvatar: true  icon: &ICON. }
    column ID     ( source { databaseColumn: ID     dataType: number  primaryKey: true } )
    column TITLE  ( source { databaseColumn: TITLE  dataType: varchar2 } )
    column METRIC ( source { databaseColumn: METRIC dataType: varchar2 } )
    column META   ( source { databaseColumn: META   dataType: varchar2 } )
    column ICON   ( source { databaseColumn: ICON   dataType: varchar2 } )
    column LINK   ( source { databaseColumn: LINK   dataType: varchar2 } )
)
```

Each KPI = one row; the number is `to_char()` of a scalar subquery bound into `&METRIC.`. `&LINK.`
gives per-card drill-down. Emit a `column (...)` block for every projected field, and keep the
thousands separator on the number — a KPI is read at a glance (`formatMask` on the metric, or
`to_char(..., 'FM999G999G990')` in the query, decided once for the region).

## A KPI badge is a semantic group

When a card carries a trend or a threshold, its value, state and icon must tell the same story:

```
plugin-badge { value: BADGE_VALUE  state: BADGE_STATE  icon: &BADGE_ICON.  style: subtle }
```

The query projects `+4.2%`, the token `success`, and `fa-arrow-up` **together** — derived from the
same expression, never independently. A green badge with a downward arrow is worse than no badge.
Tokens are the four semantic states only (`ui-contracts.md` §2); a plain count needs no state at all.

## Where the aggregation lives

- Scalar KPIs the page owns: inline scalar subqueries, as above.
- Anything reused by a chart *and* a card, or expensive: a `v_*` view
  (`back-end-conventions.md` §5). One metric, one source of truth — a card and a chart disagreeing
  about "present today" is the classic dashboard bug.
- Never one query per card row; never a per-row scalar subquery inside a chart series.

### When to drop to the PL/SQL-built-HTML variant

Only when cards share expensive intermediate computation a flat SQL row would duplicate (e.g.
"expected = active − on-leave − absent", plus a tardiness window function). Then a `beforeHeader`
`executeCode` process builds an HTML string into a hidden item, and a `staticContent` region renders
`&P1_KPIS_HTML!RAW.`. This is heavier (hand-rolled HTML + bespoke CSS) — use only when justified,
and don't mix both styles on one page.

## Chart

```
region sector-headcount (
    type: chart
    layout { columnSpan: 6 }
    series headcount (
        source { type: sqlQuery  sqlQuery: ```sql
            select s.name label, count(e.employee_id) value
              from hr_sectors s
              left join hr_employees e on e.sector_id = s.sector_id and e.active_flag='Y'
             where s.active_flag='Y' group by s.name order by s.name``` }
        columnMapping { label: LABEL  value: VALUE }
    )
    axis y ( value { format: decimal  decimalPlaces: 0 } )
)
```

Default chart type is bar; `bar`, `line`, `area`, `pie` and `combination` are the officially
sanctioned set, and a combination chart must give each series its type plus explicit axes. The
catalog also demonstrates `pyramid`, `bubble`, `radar`, `stock` and `timeAxisType` /
`zoomAndScroll` / stacked series — reachable, but each needs a written reason: exotic chart types
read as decoration unless the question they answer is stated.

Aggregate in SQL, at the granularity the axis shows (`trunc(date)` for daily). A chart series that
returns raw rows and lets the chart engine group is a performance problem that only appears in
production data volumes.

`componentAdvanced.initJavaScriptFunction` (area opacity, a forced palette) is the last resort — the
official line is to avoid custom behaviour where a standard attribute exists. If you use it, the
`comments` block says which declarative attribute was missing.

## Drill-down and detail actions

`metricCard` and `chart` regions **do not own links or actions** — that is an official contract, not
a limitation to work around with JavaScript. Navigation hangs off:

- the metric card's own `&LINK.` column (`apex_page.get_url`, `ui-contracts.md` §3);
- a region-level detail action in the header's `slot: edit` — a text link when the drill-down is a
  common follow-up, an icon button when it is secondary, nothing when the region is purely
  informational (`ui-contracts.md` §7);
- a neighbouring report or card list for row-level navigation.

## Conventions

- Dashboard reads do **not** get a package — they're presentation aggregation over base tables/`v_*`
  views.
- Keep KPI numbers + their drill-down link in one reviewable region.
- One KPI styling system per page.
- Local geometry fixes get a scoped class named after the pattern (`app-MetricCards`) with a one-line
  comment (`ui-contracts.md` §6) — not a new palette.
- An alternative chart kept in the source but not rendered belongs behind
  `config { buildOption: @<option> }`, not commented out.

## Verify

`apex-sentinel/checks/dashboard-report.md`: every KPI shows a real number (spot-checked against
SQLcl), charts actually drew, no empty tiles where data is expected.
