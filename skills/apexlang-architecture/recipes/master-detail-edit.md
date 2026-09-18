# Recipe: master-detail edit

**Use for:** a parent record with a child collection edited together — order + lines, employee + assignments, sector + members.

**REQUIRED BACKGROUND:** `back-end-conventions.md`; `package-boundaries.md` §Test 1 (is the child a satellite or an entity?); `editable-ig-to-package.md` (the child grid reuses that pattern).

## Principle

Two tables on one page are **not** automatically two packages. Run the satellite test first
(`package-boundaries.md` §Test 1), because the two cases wire differently.

**Case A — the child is a satellite.** Order + lines: a `NOT NULL` FK to the master, no other entity
writes it, meaningless without it. **One** entity package owns both tables. The detail IG routes to an
operation on that package (`pkg_orders.save_line`), and the master's process may create the header
and its lines in a single call. There is no second package to keep in step.

**Case B — the child is an independent entity.** Sector + employees: an employee exists without that
sector, and other operations write employees. **Two** entity packages, one per entity. The page wires:

- the master via a form/modal process → `pkg_master.*`,
- the detail via an editable IG → `pkg_detail.save_row`, scoped to the master PK.

In Case B, do **not** let one region's automatic DML touch both tables, and do not write the child rows
from the master's process: that couples two entities' rules in one place and makes the child package
bypassable. Each entity keeps its own package and invariants. **The example below is Case B.**

## `.apx` — master region (read + context)

A `staticContent` (or form) region shows/holds the master PK; the hidden page item carries it:

```
region header (
    type: staticContent
    source { htmlCode: <h3>Sector: &P30_CODE. — &P30_NAME.</h3> }
    layout { sequence: 10  slot: body }
)
pageItem P30_SECTOR_ID ( type: hidden )
```

## `.apx` — detail editable IG, scoped by master PK

```
region members (
    type: interactiveGrid
    source { type: sqlQuery  sqlQuery: ```sql
        select employee_id, employee_no, full_name, sector_id
          from hr_employees
         where sector_id = :P30_SECTOR_ID
         order by full_name``` }
    edit { enabled: true  allowedOperations: [ add  update  delete ] }
    layout { sequence: 20  slot: body }
    column EMPLOYEE_ID ( type: hidden  source { databaseColumn: EMPLOYEE_ID  dataType: number  primaryKey: true } )
    column SECTOR_ID   ( type: hidden  source { databaseColumn: SECTOR_ID    dataType: number } )
)
```

(Visible columns omitted for brevity.)

```
process save-members (
    type: executeCode
    editableRegion: @members
    source { plsqlCode: ```plsql
        -- stamp the parent FK on new child rows, then route to the child package
        if :APEX$ROW_STATUS = 'C' then
            :SECTOR_ID := :P30_SECTOR_ID;
        end if;
        pkg_employees.save_sector_assignment(
            p_row_status  => :APEX$ROW_STATUS,
            p_employee_id => :EMPLOYEE_ID,
            p_sector_id   => :SECTOR_ID);``` }
    execution { sequence: 20  point: afterSubmit }
)
```

## Conventions

- **Parent FK on new child rows** is stamped in the detail process from the master PK item (`:P30_SECTOR_ID`), then passed to the child package — the child package still owns the write and its rules. (`save_sector_assignment` is this recipe's scoped IG adapter, the same shape as `save_row` in `editable-ig-to-package.md`; the shipped `examples/employees-form` package exposes plain CRUD instead.)
- **Two packages, two transactions-of-rules** (Case B) under one page submit (APEX commits once). If the master must exist before children, create/fetch it in a `beforeHeader` step and carry its PK. In Case A there is one package, so the ordering is its problem, not the page's.
- For a deep master + many-child create-in-one-shot flow (Case B), an APEX **page-level** orchestration process calling `pkg_master.create_row` and then looping children through `pkg_detail` is the right shape — the `.apx` is allowed to call packages in sequence. It stops being enough when the cross-entity test fires (`package-boundaries.md` §Test 2): an intermediate state that is invalid if the sequence halts, or the same operation needed from a job or REST. Then the coordination moves into a `_flow` package and the page calls that one operation instead.

## Common mistakes

| Tempting | Why wrong |
|---|---|
| Bind the detail IG's automatic DML to the child table | Bypasses the child package's invariants (e.g. "employee already assigned elsewhere"). Replacing it with a per-row process (`executeCondition: forEachRow`) is sanctioned by `apex.interactive-grid-page.md:49` — *"unless invoking a dedicated API"*; `pkg_employees` is that API. |
| Write child rows from the master's process, in Case B | Couples two entities' rules in one place; the child package becomes bypassable. Keep them separate. (In Case A the child is a satellite and one package owns both — that is not this mistake.) |
| Give a satellite its own package, in Case A | `order_lines` has a `NOT NULL` FK to `orders`, nothing else writes it, and it means nothing alone. A second package there buys no isolation and forces a `_flow` to coordinate what one entity already owns. |
| Forget to stamp the parent FK | New child rows land with a null/inherited FK. Set it from the master PK item in the detail process. |
