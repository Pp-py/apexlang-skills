# Example: sectors catalog (editable Interactive Grid → write-path package)

The canonical expression of the core principle: an inline-editable catalog whose IG
routes every write through `pkg_sectors`, never the built-in *Automatic Row Processing (DML)*.

Implements `apexlang-architecture/recipes/editable-ig-to-package.md`.
Verify it with `apex-sentinel/examples/sectors-catalog.md`.

## Files

| File | What |
|---|---|
| `01-ddl.sql` | `hr_sectors` table, `CHECK`, case-insensitive `UNIQUE` index, seed rows |
| `02-pkg_sectors.sql` | write-path package: `create_row`/`update_row`/`delete_row` + `save_row` adapter |
| `03-page-sectors.apx` | the IG page (page 30): grid + `executeCode @afterSubmit` calling the package |

## Deploy (run in order, on a schema parsing as your APEX app)

```bash
# 1. shared core (once for all slices)
sql -name <conn> @../00-pkg_errors.sql
sql -name <conn> @../00-error_handling_function.sql      # then register it (see that file's header)

# 2. this slice
sql -name <conn> @01-ddl.sql
sql -name <conn> @02-pkg_sectors.sql

# 3. the page — validate BEFORE importing (grammar can vary by APEX version)
apex validate -input <apexlang-src-dir>                   # add 03-page-sectors.apx into your app source tree first
apex import   -input <apexlang-src-dir>
```

> The `.apx` is written in validated grammar (`apex validate` green against APEX 26.1 /
> SQLcl 26.1) — still re-validate against your own APEX version before importing, and mind
> that page number (30) and alias (`SECTORS-CATALOG`) must not collide with your app's.

## What "done" looks like

- The grid renders the two seed rows (PROD, ADM).
- Adding a row with a **new** code saves; the new PK comes back via the `IN OUT` param.
- Adding a row whose code **duplicates** an existing one is rejected with a *friendly*
  message (`A sector with code PROD already exists.`) — no `ORA-20800:` prefix, because the
  Error Handling Function is registered. The duplicate row is **not** inserted.

That rejection path is the high-value, non-mutating check — see the sentinel walkthrough.
