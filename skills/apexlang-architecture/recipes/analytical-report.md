# Recipe: analytical report (interactive reports + charts)

**Use for:** a reporting page with filters, one or more Interactive Reports, and charts over the same
data (monthly/weekly pivots, by-sector breakdowns).

Read-only: **no write-path package**. The complex aggregation lives in a **`v_*` view**; the page
reads it. Data-side rules: `ui-contracts.md`.

## Shape

1. Hidden/visible filter items (`P30_YEAR`, `P30_MONTH`, `P30_VIEW`).
2. One or more `interactiveReport` regions over a `v_*` view, shown conditionally by
   `serverSideCondition`.
3. Charts over the same view.
4. Badges and flags rendered by `columnFormatting.htmlExpression` over plain tokens from the query.

## Put the aggregation in a view

```plsql
CREATE OR REPLACE VIEW v_ot_monthly_employee AS
SELECT employee_id,
       TO_NUMBER(TO_CHAR(work_date,'YYYY')) year_no,
       TO_NUMBER(TO_CHAR(work_date,'MM'))   month_no,
       ot_rule_code,
       ROUND(SUM(ot_minutes)/60, 2)         ot_hours
  FROM hr_ot_daily
 GROUP BY employee_id, TO_NUMBER(TO_CHAR(work_date,'YYYY')),
          TO_NUMBER(TO_CHAR(work_date,'MM')), ot_rule_code;
```

The page never re-derives this; it selects from the view. Reuse across the report's IRs and charts.

## `.apx` — conditional IR + badge

The query projects a **label and a token**; the markup is built in the column. HTML in the SQL is
rejected by the live compiler (`REPORT_SQL_HTML_LITERAL_FORBIDDEN_001`) and by non-negotiable rule 1
of the official `apex.report-column-rendering.md`.

```
region ot-monthly (
    type: interactiveReport
    serverSideCondition { type: expression  plsqlExpression: :P30_VIEW = 'MONTHLY' }
    source { type: sqlQuery  sqlQuery: ```sql
        select e.employee_no, e.full_name, s.name sector, v.ot_hours,
               case v.ot_rule_code
                    when 'PRODUCTION' then 'Production'
                    else 'Clock hour'
               end as rule,
               case v.ot_rule_code
                    when 'PRODUCTION' then '11'
                    else '1'
               end as rule_color,
               case when v.ot_hours > 40 then 'danger' else 'info' end as hours_state
          from v_ot_monthly_employee v
          join hr_employees e on e.employee_id = v.employee_id
          join hr_sectors   s on s.sector_id  = e.sector_id
         where v.year_no = :P30_YEAR and v.month_no = :P30_MONTH``` }

    column RULE (
        heading { heading: Rule }
        columnFormatting { htmlExpression: <span class="u-color-#RULE_COLOR#-text">#RULE#</span> } )
    column RULE_COLOR  ( type: hidden  heading { heading: Rule colour } )
    column HOURS_STATE ( type: hidden  heading { heading: Hours state } )
)
```

Swap to a weekly IR with the same pattern under `:P30_VIEW = 'WEEKLY'`.

Three easy-to-miss report contracts: markup goes **inside** `columnFormatting` (never a top-level
`htmlExpression` on the column), the column stays plain-text rendering (no `type: richText`), and on
an Interactive Report **every** column emits a `heading` — hidden ones included.

## Boolean flags read as icons, not as `Y`

```
column IS_APPROVED (
    columnFormatting { htmlExpression: |
        {if IS_APPROVED/}<span class="fa fa-check" aria-hidden="true" title="Yes"></span>
        {else/}<span class="fa fa-circle-o" aria-hidden="true" title="No"></span>
        {endif/} } )
```

The directive lives in the column, the icon carries `title` for the accessible name and
`aria-hidden` on the glyph. Do not build this string in the query.

## Which columns the user sees

An Interactive Report exposes business semantics; the columns that only feed the render are
mechanics. Keep them out of the saved report:

- support columns (`RULE_COLOR`, `HOURS_STATE`, `*_CSS`, `*_URL`) → `type: hidden`, and absent from
  `savedReport ... displayColumn`;
- the visible list gets explicit `sequence` values, so the column order is a decision, not an
  accident of the SELECT list;
- `pagination { type: rowRangesXToY }` when the user needs to know how deep the result is.

An actions column (`themeTemplateComponent/actions`) is the one place to also set
`enableUsersTo { hide: false  sort: false  filter: false }` — a row-action column that a user can
hide or sort is a support call.

## Badge as markup or as a template component

Two ways to render a state, and they are not interchangeable:

- **`columnFormatting.htmlExpression` over a token** — the default, as above. It is what the official
  column-rendering contract prescribes and what `workflow-state-transitions.md` already uses.
- **`type: themeTemplateComponent/badge | avatar | actions`** — for avatars and row-action menus,
  where an `htmlExpression` cannot reproduce the component (initials, image, menu). Not for a plain
  status pill.

## Conventions

- **Complex/reused aggregation → `v_*` view.** Inline SQL only for trivial page-local selects.
- Toggle alternate views with `serverSideCondition` (`plsqlExpression`), not by deleting regions.
- The query projects values and tokens; the column projects markup (`ui-contracts.md` §2, §5).
- Report columns substitute with `#COLUMN#`; cards and content rows use `&COLUMN.` — mixing them
  fails silently.
- The link belongs to the column, never to the region (see `SKILL.md` §Report contracts).
- `displayOnly` preview/echo items that shouldn't post back: `settings { sendOnPageSubmit: false }`.
- Charts read the same view as the IRs — one source of truth per metric.

## Verify

`apex-sentinel/checks/dashboard-report.md`: the IR returns rows for the current filter, the view
toggle swaps regions, and badge columns render as markup rather than escaped text.
