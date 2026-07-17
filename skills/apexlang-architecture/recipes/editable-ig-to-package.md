# Recipe: editable Interactive Grid → write-path package

**Use for:** a catalog the admin edits inline (add/update/delete rows in one grid). This is the canonical expression of the core principle.

**REQUIRED BACKGROUND:** `back-end-conventions.md` (single write-path, error catalog, no-COMMIT).

## Shape

1. An `interactiveGrid` region over a SQL query, `edit.enabled: true`.
2. An `executeCode` process bound to the region (`editableRegion`), point `afterSubmit`, that runs **once per changed row**, branches on `:APEX$ROW_STATUS`, and calls `pkg_x.save_row`.
3. A package `save_row` adapter routing `C`/`U`/`D` to `create_row`/`update_row`/`delete_row`.

The built-in *Interactive Grid – Automatic Row Processing (DML)* is **not** used. Delete it if APEX scaffolds it.

## `.apx` — region

The `validation` block on each column is a field-shape hint only (see Validation placement in `back-end-conventions.md`):

```
region sectors (
    name: Sectors
    type: interactiveGrid
    source {
        location: localDatabase
        type: sqlQuery
        sqlQuery:
            ```sql
            select sector_id, code, name, active_flag
              from hr_sectors
             order by code
            ```
    }
    edit { enabled: true  allowedOperations: [ add  update  delete ] }
    toolbar { controls: [ searchField  actionsMenu  resetButton  saveButton ] }

    column SECTOR_ID (
        type: hidden
        source { databaseColumn: SECTOR_ID  dataType: number  primaryKey: true }
    )
    column CODE (
        type: textField
        heading { heading: Code }
        validation { maxLength: 30 }
        source { databaseColumn: CODE  dataType: varchar2 }
    )
    column NAME (
        type: textField
        heading { heading: Name }
        validation { maxLength: 100 }
        source { databaseColumn: NAME  dataType: varchar2 }
    )
    column ACTIVE_FLAG (
        type: selectList
        heading { heading: Active }
        lov { type: staticValues  staticValues: STATIC2:Active;Y,Inactive;N  displayNullValue: false }
        source { databaseColumn: ACTIVE_FLAG  dataType: varchar2 }
    )
)
```

`primaryKey: true` on the hidden PK is what lets the IG track identity for update/delete.

## `.apx` — save process

The `execution.point` must be `afterSubmit`, NOT `processing` (see Non-obvious points):

```
process save-sectors (
    name: Save sectors
    type: executeCode
    editableRegion: @sectors
    source {
        plsqlCode:
            ```plsql
            declare
                l_err boolean := false;
            begin
                -- required-field checks must live here: IG column validations
                -- do NOT fire on IG Save. Surface cleanly:
                if :APEX$ROW_STATUS in ('C','U') then
                    if trim(:CODE) is null then
                        apex_error.add_error(
                            p_message => 'Sector code is required.',
                            p_display_location => apex_error.c_inline_in_notification);
                        l_err := true;
                    end if;
                end if;

                if not l_err then
                    :CODE := upper(trim(:CODE));     -- normalize before write
                    pkg_sectors.save_row(
                        p_row_status  => :APEX$ROW_STATUS,
                        p_sector_id   => :SECTOR_ID,  -- IN OUT: receives PK on insert
                        p_code        => :CODE,
                        p_name        => :NAME,
                        p_active_flag => :ACTIVE_FLAG);
                end if;
            end;
            ```
    }
    execution { sequence: 10  point: afterSubmit }
)
```

## PL/SQL — the adapter

```plsql
PROCEDURE save_row (
    p_row_status  IN     VARCHAR2,
    p_sector_id   IN OUT hr_sectors.sector_id%TYPE,
    p_code        IN     hr_sectors.code%TYPE,
    p_name        IN     hr_sectors.name%TYPE,
    p_active_flag IN     hr_sectors.active_flag%TYPE
) IS
BEGIN
    CASE p_row_status
        WHEN 'C' THEN
            create_row(p_code, p_name);
            SELECT sector_id INTO p_sector_id          -- return generated PK
              FROM hr_sectors                          -- so the IG finalizes the new row
             WHERE UPPER(code) = UPPER(TRIM(p_code));
        WHEN 'U' THEN update_row(p_sector_id, p_code, p_name, NVL(p_active_flag,'Y'));
        WHEN 'D' THEN delete_row(p_sector_id);
        ELSE NULL;                                     -- unchanged rows don't reach here
    END CASE;
END save_row;
```

All validation (uniqueness, "cannot delete while referenced") lives in `create_row`/`update_row`/`delete_row` — see `back-end-conventions.md` §2. The adapter only routes.

## Non-obvious points

- **`p_sector_id` is IN OUT.** On insert it returns the new PK so the IG can finalize the row; on update/delete it carries the existing PK in.
- **Process point is `afterSubmit`**, not `processing` — IG per-row binds (`:CODE`, `:APEX$ROW_STATUS`) are only available there.
- **Required-field checks go in the process**, because IG column validations don't fire on Save. Use `apex_error.add_error(..., c_inline_in_notification)` for clean inline text.
- **Two grids on one page:** give each its own `editableRegion`-bound process, ordered by `sequence`.

## Verify

```bash
apex validate -input <apexlang-src-dir>   # your project's .apx source root
```
Then in the running grid: add a duplicate code → friendly inline error, save rolled back, grid stays open.
