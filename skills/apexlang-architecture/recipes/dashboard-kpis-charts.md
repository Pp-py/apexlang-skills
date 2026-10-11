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
               to_char((select count(*) from hr_employees where active_flag='Y'),
                       'FM999G999G990') metric,
               'current headcount' meta, 'fa-users' icon
          from dual
        union all
        select 2, 'Present today',
               to_char((select count(distinct c.employee_id) from hr_clockings c
                         where c.clocking_date = trunc(sysdate) and c.cancelled_at is null),
                       'FM999G999G990'),
               'clocked in today', 'fa-check' from dual``` }
    appearance { template: @/blank-with-attributes }
    componentAppearance { display: report }
    settings { title: &TITLE.  metric: &METRIC.  meta: &META.  layout: 3Columns }
    plugin-avatar { displayAvatar: true  type: icon  icon: &ICON. }
    column ID     ( source { databaseColumn: ID     dataType: number  primaryKey: true } )
    column TITLE  ( source { databaseColumn: TITLE  dataType: varchar2 } )
    column METRIC ( source { databaseColumn: METRIC dataType: varchar2 } )
    column META   ( source { databaseColumn: META   dataType: varchar2 } )
    column ICON   ( source { databaseColumn: ICON   dataType: varchar2 } )
)
```

Each KPI = one row; the number is `to_char()` of a scalar subquery bound into `&METRIC.`. Emit a
`column (...)` block for every projected field. The metric is projected as text, so the query
formats it once (`to_char(..., 'FM999G999G990')`); how it must read is `apex-ux` `UXDASH-KPI-CONTEXT`. The icon column returns literals only, so every value is a
proven Font APEX icon.

These two cards lead to different pages, so they carry **no** link: a Metric Card action has one
declarative target for every card in the region. Their drill-downs are the region's header action
or the report next to them (§Drill-down below).

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

A Metric Card action is declarative, `position: link`, and its target is the same for every card
in the region. A `chart` owns no actions. Oracle routes drill-down from both *"through nearby
report/card links rather than chart or metric actions"* (`apex.region-contracts.md`), which leaves
three options:

- **A breakdown strip** — every card opens the **same** page, filtered by the card's own key —
  is the one case for the card's own link:

  ```
  region requests-by-status (
      type: themeTemplateComponent/metricCard
      source { type: sqlQuery  sqlQuery: ```sql
          select status status_code, initcap(status) title,
                 to_char(count(*), 'FM999G999G990') metric
            from hr_absences where cancelled_at is null
           group by status``` }
      appearance { template: @/blank-with-attributes }
      componentAppearance { display: report }
      orderBy { type: staticValue  orderByClause: STATUS_CODE asc }
      settings { title: &TITLE.  metric: &METRIC. }
      action open-status (
          position: link
          layout { sequence: 10 }
          behavior { type: redirectThisApp
                     target: { page: 60  items: { P60_STATUS: &STATUS_CODE. }  clearCache: 60 } } )
      column STATUS_CODE ( source { databaseColumn: STATUS_CODE dataType: varchar2  primaryKey: true } )
      column TITLE       ( source { databaseColumn: TITLE       dataType: varchar2 } )
      column METRIC      ( source { databaseColumn: METRIC      dataType: varchar2 } )
  )
  ```

  The target page reads `P60_STATUS` as a filter, and the query projects only the key, never a
  URL (`ui-contracts.md` §3).
- **A region-level detail action** in the header when the region as a whole has one follow-up
  (its form and place: `apex-ux` `UXDASH-DRILLDOWN`).
- **A neighbouring report or card list** for row-level navigation, with its own column or card
  links. This is what Oracle's dashboard composition already puts below the KPIs.

KPIs that lead to different pages are different questions. Use a header action per region, or split
the strip, and never compute a destination per row.

## Conventions

- Dashboard reads do **not** get a package — they're presentation aggregation over base tables/`v_*`
  views.
- Keep KPI numbers and their drill-down in one reviewable place: the card's declarative action, or
  the region's header action.
- One KPI styling system per page.
- Local geometry fixes: `apex-ux` `UX-NO-INVENTED-CLASS` — not a new palette.
- An alternative chart kept in the source but not rendered belongs behind
  `config { buildOption: @<option> }`, not commented out.

## Verify

`apex-sentinel/checks/dashboard-report.md`: every KPI shows a real number (spot-checked against
SQLcl), charts actually drew, no empty tiles where data is expected.
