# Example: employee form (full page + drawer → write-path package)

The archetype Oracle's UX Pattern Catalog demonstrates but never persists: a single-entity form,
once as a full page and once as an end/right drawer, both writing through `pkg_employees` and
neither using a `form` region's Automatic Row DML.

Implements `apexlang-architecture/recipes/form-page-to-package.md`.
Verify it with `apex-sentinel/checks/form-page.md`.

## Files

| File | What |
|---|---|
| `01-ddl.sql` | `hr_employees` table, FK to `hr_sectors`, case-insensitive `UNIQUE` email index, seed row |
| `02-pkg_employees.sql` | write-path package: `create_row` (PK out) / `update_row` / `delete_row` (inactivates) |
| `03-page-employee-form.apx` | full page (page 41): sections, plain items, one process per intent |
| `04-page-employee-drawer.apx` | drawer (page 42): same processes, `closeDialog` gated by `:REQUEST` |

`hr_sectors` comes from the `sectors-catalog/` slice — deploy that one's `01-ddl.sql` first, or point
the FK at your own sector table.

## Deploy (run in order, on a schema parsing as your APEX app)

```bash
# 1. shared core (once for all slices)
sql -name <conn> @../00-pkg_errors.sql
sql -name <conn> @../00-error_handling_function.sql      # then register it (see that file's header)

# 2. this slice (hr_sectors must exist first)
sql -name <conn> @../sectors-catalog/01-ddl.sql          # skip if already deployed
sql -name <conn> @01-ddl.sql
sql -name <conn> @02-pkg_employees.sql

# 3. the pages — validate BEFORE importing
apex validate -input <apexlang-src-dir>                   # add both .apx into your app source tree first
apex import   -input <apexlang-src-dir>
```

> Validated against APEXlang **2026.08.01** with one known diagnostic:
> `BREADCRUMB_COVERAGE_ENTRY_REQUIRED_001` for page 41, satisfied by adding a `pageNumber: 41` entry
> to **your** app's `shared-components/breadcrumbs.apx` (page 42 is a modal drawer, so it needs
> none). Page numbers (41, 42) and aliases (`EMPLOYEE-FORM`, `EMPLOYEE-DRAWER`) must not collide
> with your app's.

## Why no `form` region

The official form standard binds a `type: form` region to exactly one `formAutoRowProcessing`
(`apex.form.md:135`) and, unlike the Interactive Grid standard, offers no "dedicated API" carve-out.
These pages therefore use a plain item container: ordinary page items, a `load` process for the read,
and one `executeCode` process per intent for the write. Nothing is deviating from the official
contract because no form region exists — and the single write-path survives intact. The cost is
visible in the source: two short processes instead of an inherited column mapping.

## What "done" looks like

- Opening page 41 with no `P41_EMPLOYEE_ID` shows **Create**; with a PK it loads the row and shows
  **Apply Changes** / **Delete**.
- Creating with a new email saves, and the page continues in edit mode — the process copies the
  generated PK back into the item.
- Creating with `ana.rojas@example.com` is rejected with *"An employee with email
  ana.rojas@example.com already exists."* — no `ORA-20811:` prefix, and **no row inserted**.
- Same rejection on the drawer (page 42) leaves the drawer **open** with the message: the
  `closeDialog` process is `:REQUEST`-gated and never runs when the submit halts. That is the whole
  point of not closing the dialog from a button's trigger action.
- **Delete** deactivates (`active_flag = 'N'`); the row stays for history.
