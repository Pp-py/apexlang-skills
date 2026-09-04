# Recipe: versioned append-only record (vigencies)

**Use for:** values that change over time and whose history must be preserved — rates, prices, surcharges, tax percentages, assignments. You never UPDATE the value; you close the current row and open a new one.

**REQUIRED BACKGROUND:** `back-end-conventions.md` §6 (vigencies + partial unique index).

## Shape

1. A **master** IR showing only the *open* rows (`valid_to IS NULL`).
2. A **modal** "new vigency" form whose process calls `pkg_x.new_vigency` — which closes the open row and inserts a new open one in one transaction.
3. A read-only **history** IR showing all rows (every version) for a key.

The package is the only writer; the UI never issues UPDATE/INSERT against the vigency table.

## The write — `new_vigency`

```plsql
PROCEDURE new_vigency (
    p_code       IN hr_surcharges.code%TYPE,
    p_percentage IN hr_surcharges.percentage%TYPE,
    p_valid_from IN DATE
) IS
    l_id      hr_surcharges.surcharge_id%TYPE;
    l_type    hr_surcharges.surcharge_type%TYPE;
    l_version hr_surcharges.version_no%TYPE;
    l_from    hr_surcharges.valid_from%TYPE;
BEGIN
    -- Locate the open vigency for this key AND lock it: two concurrent calls must
    -- not both close the same row.
    SELECT surcharge_id, surcharge_type, version_no, valid_from
      INTO l_id, l_type, l_version, l_from
      FROM hr_surcharges
     WHERE code = p_code AND valid_to IS NULL
       FOR UPDATE;

    IF TRUNC(p_valid_from) <= l_from THEN
        RAISE_APPLICATION_ERROR(pkg_errors.k_surcharge_invalid_date,
            'The new vigency must start after the current one.');
    END IF;

    -- close the current row (inclusive end = day before the new start)
    UPDATE hr_surcharges
       SET valid_to = TRUNC(p_valid_from) - 1
     WHERE surcharge_id = l_id;

    -- open the new row; carry the type, bump the version
    INSERT INTO hr_surcharges (code, surcharge_type, percentage, valid_from, valid_to, version_no)
    VALUES (p_code, l_type, p_percentage, TRUNC(p_valid_from), NULL, l_version + 1);
END new_vigency;
```

Two details in there are not decoration:

- **`valid_from` comes back in the same `SELECT INTO`.** PL/SQL does not accept a subquery in a
  procedural expression, so `IF TRUNC(p_valid_from) <= (SELECT valid_from FROM ...)` does not compile
  (`PLS-00405`). Fetch the value you are going to compare.
- **`FOR UPDATE` on the open row.** The invariant "one open row per key" is enforced by a partial
  unique index (`back-end-conventions.md` §6), not by the UI — but without the lock two concurrent
  `new_vigency` calls both find the same open row, both close it, both insert, and the second one
  surfaces as a raw `ORA-00001` instead of the friendly message the package exists to give.

## `.apx` — master (open rows only)

```
region current-surcharges (
    type: interactiveReport
    source { type: sqlQuery  sqlQuery: ```sql
        select surcharge_id, code, percentage, valid_from, version_no
          from hr_surcharges where valid_to is null order by code``` }
    column CODE ( type: plainText
        heading { heading: Code }
        source { dataType: STRING }
        link {
            target { page: 101  items { P101_CODE: #CODE# }  clearCache: 101 }
            linkText: <span class="fa fa-plus"></span> } )
)
```

The link is column-level: a report-level `link {}` is rejected by the live compiler — see `modal-crud-to-package.md`.

## `.apx` — modal new-vigency process

```
process save-vigency (
    type: executeCode
    source { plsqlCode: ```plsql
        pkg_surcharges.new_vigency(:P101_CODE, :P101_PERCENTAGE, to_date(:P101_VALID_FROM,'DD/MM/YYYY'));``` }
    execution { point: afterSubmit }
)
```

A `displayOnly` echo item can show "closes current vigency on <date−1>" (`settings { sendOnPageSubmit: false }`), populated by a dynamic action — UX only, the package computes the real close date.

## History IR (read-only)

```
region history (
    type: interactiveReport
    source { type: sqlQuery  sqlQuery: ```sql
        select code, percentage, valid_from, valid_to, version_no
          from hr_surcharges where code = :P102_CODE order by version_no desc``` }
)
```

## Why never UPDATE the value in place

Overwriting a rate destroys the record needed to recompute past periods (a payroll run for last month must use last month's rate). Append-only vigencies keep every version; the partial UQ guarantees exactly one is current. This is a write-path-package responsibility — the UI cannot be trusted to "remember to close the old row."
