# Recipe: home dashboard (KPI cards + charts)

**Use for:** a landing page with a strip of KPI numbers and one or more charts.

Read-only: **no package**. KPI scalars and chart series read straight from tables/views.

## KPI cards — prefer the native `metricCard` region

One region, one SQL query returning **one row per card**. Declarative, round-trips cleanly, responsive layout for free. Reach for this first.

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

Each KPI = one row; the number is `to_char()` of a scalar subquery bound into `&METRIC.`. `&LINK.` gives per-card drill-down.

### When to drop to the PL/SQL-built-HTML variant

Only when cards share expensive intermediate computation a flat SQL row would duplicate (e.g. "expected = active − on-leave − absent", plus a tardiness window function). Then a `beforeHeader` `executeCode` process builds an HTML string into a hidden item, and a `staticContent` region renders `&P1_KPIS_HTML!RAW.`. This is heavier (hand-rolled HTML + bespoke CSS) — use only when justified, and don't mix both styles on one page.

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

Default chart type is bar; add `chart { type: area }` for trend lines.

## Conventions

- Dashboard reads do **not** get a package — they're presentation aggregation over base tables/`v_*` views.
- Keep KPI numbers + their drill-down link in one reviewable region.
- One KPI styling system per page.
