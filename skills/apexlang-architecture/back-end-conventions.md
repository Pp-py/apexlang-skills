# Back-end conventions — the PL/SQL core

The spine of a well-architected APEXlang app is a small, disciplined PL/SQL core that owns every write and every business rule. These conventions are domain-agnostic — they hold for HR, inventory, billing, anything.

## 1. Single write-path package per table

For each table that gets written, there is **exactly one package** that is the only thing allowed to INSERT/UPDATE/DELETE it. Every page, job, and REST handler goes through it. State the contract in the package header so it is unambiguous:

```plsql
CREATE OR REPLACE PACKAGE pkg_sectors AS
  /*
   * Only write path for hr_sectors.
   * No internal COMMIT (the caller / APEX commits).
   * Business exceptions via pkg_errors (-208xx codes).
   */
  PROCEDURE create_row (p_code IN VARCHAR2, p_name IN VARCHAR2);
  PROCEDURE update_row (p_sector_id IN NUMBER, p_code IN VARCHAR2,
                        p_name IN VARCHAR2, p_active_flag IN VARCHAR2);
  PROCEDURE delete_row (p_sector_id IN NUMBER);
  -- IG adapter: see recipes/editable-ig-to-package.md
  PROCEDURE save_row (p_row_status IN VARCHAR2,
                      p_sector_id IN OUT NUMBER, ...);
END pkg_sectors;
```

**Why single write-path:** all invariants live in one testable place; the UI cannot bypass them; the same API serves a second UI (mobile, ORDS REST) for free. This is the architectural rule everything else hangs on.

## 2. Validation lives in the package, not the UI

Business rules (uniqueness, "cannot delete while referenced", domain checks) are enforced **inside the package**, raising a named error. The UI is for *field-shape* hints only.

```plsql
PROCEDURE create_row (p_code IN VARCHAR2, p_name IN VARCHAR2) IS
  l_cnt PLS_INTEGER;
BEGIN
  IF TRIM(p_code) IS NULL OR TRIM(p_name) IS NULL THEN
    RAISE_APPLICATION_ERROR(pkg_errors.k_sector_invalid_data,
      'Code and name are required.');
  END IF;
  SELECT COUNT(*) INTO l_cnt FROM hr_sectors
   WHERE UPPER(code) = UPPER(TRIM(p_code));
  IF l_cnt > 0 THEN
    RAISE_APPLICATION_ERROR(pkg_errors.k_sector_code_duplicate,
      'A sector with code ' || TRIM(p_code) || ' already exists.');
  END IF;
  INSERT INTO hr_sectors (code, name, active_flag)
  VALUES (UPPER(TRIM(p_code)), TRIM(p_name), 'Y');
END create_row;
```

A DB unique index on `UPPER(code)` is the **backstop** for the check-then-insert race — not the user-facing mechanism. Keep both: index = correctness, package check = friendly message.

## 3. Centralized error catalog

One package (`pkg_errors`) owns all `-20xxx` codes, in reserved bands per domain, each as a constant **and** a named exception:

```plsql
k_sector_code_duplicate CONSTANT NUMBER := -20800;
e_sector_code_duplicate EXCEPTION;
PRAGMA EXCEPTION_INIT(e_sector_code_duplicate, -20800);
```

Reserve a band per domain (e.g. `-20800..-20809` sectors). To show clean text instead of `ORA-20800:` prefix, register one application-level **Error Handling Function** that strips the `ORA-` prefix from `raise_application_error` messages.

## 4. No COMMIT inside the package

The caller owns the transaction. APEX commits on page submit; jobs commit explicitly (`BEGIN pkg_x.do(); COMMIT; END;`). The one documented exception is high-throughput batch ingestion, which commits once per batch — and says so in its header. State the convention in every header so it is not accidentally broken.

## 5. Reads: inline SQL or a view — never the package

Packages are the **write** path. Reads go straight to SQL:

- Region/IR/chart `source.sqlQuery` inline for page-local queries and KPI scalars.
- A `v_*` view when the aggregation is complex or reused (reports, charts).
- An `f_*` package **function** only for LOV/lookup values that encapsulate resolution logic.

Do not route reporting through the write-path package.

## 6. Recurring data patterns

- **Soft delete via flag:** catalogs carry `active_flag` ('Y'/'N'); queries filter `active_flag='Y'`. Inactivation is blocked while referenced.
- **Soft delete via audit columns:** transactional rows carry `cancelled_at`/`cancelled_by`/`cancel_reason`; queries filter `cancelled_at IS NULL`. Preserves history.
- **Append-only vigencies:** time-valid rows (rates, assignments) keep history by closing the old row (`valid_to = new_from − 1`) and inserting a new open one, enforcing "one open row per key" with a **partial unique index**: `CREATE UNIQUE INDEX ... ON t (CASE WHEN valid_to IS NULL THEN key END)`. (Use the single-expression CASE form; the multi-column `(key, CASE WHEN ... THEN 1 END)` form misfires on Oracle 23ai.)

## Layering summary

| Layer | Job |
|---|---|
| DB constraints (PK/FK/UQ/CHECK) | last-line integrity, race backstop |
| Write-path package | business rules, the only DML, friendly `-20xxx` errors |
| `.apx` process (`afterSubmit`) | normalize input, call the package, surface errors |
| `.apx` validation / column hints | field-shape only (required, maxLength) |
| `v_*` views / inline SQL | all reads |
