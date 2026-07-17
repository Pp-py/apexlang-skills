# Recipe: master-detail edit

**Use for:** a parent record with a child collection edited together — order + lines, employee + assignments, sector + members.

**REQUIRED BACKGROUND:** `back-end-conventions.md`; `editable-ig-to-package.md` (the child grid reuses that pattern).

## Principle

Master and detail are **two tables**, so they have **two write-path packages**. The page wires:

- the master via a form/modal process → `pkg_master.*`,
- the detail via an editable IG → `pkg_detail.save_row`, scoped to the master PK.

Do **not** let one region's automatic DML touch both tables, and do not write the child rows from the master's process. Each table keeps its own package and invariants.

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

- **Parent FK on new child rows** is stamped in the detail process from the master PK item (`:P30_SECTOR_ID`), then passed to the child package — the child package still owns the write and its rules.
- **Two packages, two transactions-of-rules** under one page submit (APEX commits once). If the master must exist before children, create/fetch it in a `beforeHeader` step and carry its PK.
- For a deep master + many-child create-in-one-shot flow, consider an APEX **page-level** orchestration process calling `pkg_master.create_row` then looping children through `pkg_detail` — still one package per table.

## Common mistakes

| Tempting | Why wrong |
|---|---|
| Bind the detail IG's automatic DML to the child table | Bypasses the child package's invariants (e.g. "employee already assigned elsewhere"). |
| Write child rows from the master's process | Couples two tables' rules in one place; the child package becomes bypassable. Keep them separate. |
| Forget to stamp the parent FK | New child rows land with a null/inherited FK. Set it from the master PK item in the detail process. |
