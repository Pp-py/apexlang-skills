# Recipe: analytical report (interactive reports + charts)

**Use for:** a reporting page with filters, one or more Interactive Reports, and charts over the same data (monthly/weekly pivots, by-sector breakdowns).

Read-only: **no write-path package**. The complex aggregation lives in a **`v_*` view**; the page reads it.

## Shape

1. Hidden/visible filter items (`P30_YEAR`, `P30_MONTH`, `P30_VIEW`).
2. One or more `interactiveReport` regions over a `v_*` view, shown conditionally by `serverSideCondition`.
3. Charts over the same view.
4. Badge formatting via `htmlExpression` computed in SQL.

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

The `RULE` column renders the HTML built in the SQL `CASE` via `htmlExpression`:

```
region ot-monthly (
    type: interactiveReport
    serverSideCondition { type: expression  plsqlExpression: :P30_VIEW = 'MONTHLY' }
    source { type: sqlQuery  sqlQuery: ```sql
        select e.employee_no, e.full_name, s.name sector, v.ot_hours,
               case v.ot_rule_code
                    when 'PRODUCTION' then '<span class="bdg bdg--purple">Production</span>'
                    else '<span class="bdg bdg--blue">Clock hour</span>'
               end as rule
          from v_ot_monthly_employee v
          join hr_employees e on e.employee_id = v.employee_id
          join hr_sectors   s on s.sector_id  = e.sector_id
         where v.year_no = :P30_YEAR and v.month_no = :P30_MONTH``` }

    column RULE ( type: plainText
        columnFormatting { htmlExpression: #RULE!RAW# } )
)
```

Swap to a weekly IR with the same pattern under `:P30_VIEW = 'WEEKLY'`.

## Conventions

- **Complex/reused aggregation → `v_*` view.** Inline SQL only for trivial page-local selects.
- Toggle alternate views with `serverSideCondition` (`plsqlExpression`), not by deleting regions.
- Compute badge/pill HTML in the SQL `CASE`, render with `htmlExpression: #COL!RAW#`.
- `displayOnly` preview/echo items that shouldn't post back: `settings { sendOnPageSubmit: false }`.
- Charts read the same view as the IRs — one source of truth per metric.
