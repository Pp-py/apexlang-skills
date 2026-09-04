# Back-end conventions — the PL/SQL core

The spine of a well-architected APEXlang app is a small, disciplined PL/SQL core that owns every write and every business rule. These conventions are domain-agnostic — they hold for HR, inventory, billing, anything.

## 1. Single write-path: one owner per table

For each table that gets written, there is **exactly one package** that is the only thing allowed to INSERT/UPDATE/DELETE it. Every page, job, and REST handler goes through it.

That owner is the table's **entity package**, and it also owns the entity's satellite tables (lines,
event rows, per-entity history). A `_flow` package coordinating several entities issues no DML of its
own, so it never becomes a second writer. One package per table is how you *choose* the owner — it is
not a CRUD mapping, and it is a default rather than an obligation: `package-boundaries.md` has the
ordered procedure and the satellite test. State the contract in the package header so it is
unambiguous:

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
  -- Intent-named operations belong here too, next to the CRUD -- as long as
  -- they write only this entity and its satellites (package-boundaries.md).
  PROCEDURE deactivate (p_sector_id IN NUMBER);
  -- IG adapter: see recipes/editable-ig-to-package.md
  PROCEDURE save_row (p_row_status IN VARCHAR2,
                      p_sector_id IN OUT NUMBER, ...);
END pkg_sectors;
```

**Why single write-path:** all invariants live in one testable place; the UI cannot bypass them; the same API serves a second UI (mobile, ORDS REST) for free; and the `.apx` states an intent instead of describing a mutation, so a page diff stops being a business-logic diff. This is the architectural rule everything else hangs on — developed in `package-boundaries.md` §Why a package at all, which also answers *which* package owns a given rule.

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

This holds for flow packages too: a `_flow` is a boundary of **atomicity**, not of transaction. It
guarantees atomicity by not committing between steps, and **declares in its header the order in which
it takes `FOR UPDATE` locks** — two flows locking the same entities in opposite orders deadlock. It
reaches for `SAVEPOINT` only when it must undo one step and *carry on*; letting an exception propagate
already unwinds everything, because nothing committed in between. The
pattern is in `package-boundaries.md` §Atomicity and locking in a flow package.

## 5. Reads: inline SQL or a view — never the package

Packages are the **write** path. Reads go straight to SQL:

- Region/IR/chart `source.sqlQuery` inline for page-local queries and KPI scalars.
- A `v_*` view when the aggregation is complex or reused (reports, charts).
- An `f_*` package **function** only for LOV/lookup values that encapsulate resolution logic — on the entity package that owns the value.

Do not route reporting through the write-path package.

Reading in order to **decide** is a different thing and is always allowed, in any package: a package
may query another entity to enforce a rule — `pkg_employees` checks that the sector is active before
writing an employee. What it may not do is *write* that other entity, or become the path a report
reads through.

Views and inline reads project **data and plain tokens** — a state token, a `apex_page.get_url` link,
a count — never CSS class names or HTML. What each UI pattern needs projected, and where that
derivation belongs, is in `ui-contracts.md` §2–§4.

## 6. Recurring data patterns

- **Soft delete via flag:** catalogs carry `active_flag` ('Y'/'N'); queries filter `active_flag='Y'`. Inactivation is blocked while referenced. The UI half of that agreement — which value a switch or checkbox stores — is declared once in shared components, not per item (`ui-contracts.md` §10).
- **Soft delete via audit columns:** transactional rows carry `cancelled_at`/`cancelled_by`/`cancel_reason`; queries filter `cancelled_at IS NULL`. Preserves history.
- **Append-only vigencies:** time-valid rows (rates, assignments) keep history by closing the old row (`valid_to = new_from − 1`) and inserting a new open one, enforcing "one open row per key" with a **partial unique index**: `CREATE UNIQUE INDEX ... ON t (CASE WHEN valid_to IS NULL THEN key END)`. (Use the single-expression CASE form; the multi-column `(key, CASE WHEN ... THEN 1 END)` form misfires on Oracle 23ai.)

## 7. Lost-update protection: the version token

Routing writes through a package removes *Automatic Row Processing* — and with it the row-version
check APEX was performing for free. Nothing above replaces it, so a package that updates by PK alone
is **more** exposed to lost updates than the mechanism it displaced: two users open the same employee,
both save, and the second silently overwrites the first with no error anywhere.

Every `update_row`, `save_row` and state transition therefore takes the version the page read, and
updates conditionally:

```plsql
PROCEDURE update_row (p_employee_id IN NUMBER,
                      p_full_name   IN VARCHAR2,
                      p_row_version IN NUMBER) IS      -- what the page loaded
BEGIN
    UPDATE hr_employees
       SET full_name   = TRIM(p_full_name),
           row_version = row_version + 1               -- bumped in the same statement
     WHERE employee_id = p_employee_id
       AND row_version = p_row_version;                -- the guard

    IF SQL%ROWCOUNT = 0 THEN
        -- The row is gone, or someone saved first. Both are conflicts to the user.
        RAISE_APPLICATION_ERROR(pkg_errors.k_row_changed,
            'This record was changed by someone else since you opened it. Reload and try again.');
    END IF;
END update_row;
```

- `row_version NUMBER DEFAULT 1 NOT NULL` on every table an interactive screen edits. An `updated_at`
  timestamp also works, but a counter cannot collide inside one clock tick.
- **The bump belongs to the same `UPDATE`.** A separate statement reopens the window it closes.
- **`SQL%ROWCOUNT = 0` is the signal.** Never pre-check with a `SELECT` — that *is* the race.
- One shared code in `pkg_errors` for it, outside the per-domain bands (§3): every table raises the
  same conflict and the user reads the same sentence.
- A transition that reads its row `FOR UPDATE` (`recipes/workflow-state-transitions.md`) is already
  serialized against other *transitions*, but still needs the token if a form can edit that row's
  other columns.
- Delete needs it too when the screen offers delete-after-read; a hard `DELETE ... AND row_version =`
  with the same `SQL%ROWCOUNT` check. Soft delete via §6 goes through `update_row` and inherits it.

The UI half is one hidden value carried back on submit — a hidden IG column
(`recipes/editable-ig-to-package.md`) or a hidden page item (`recipes/form-page-to-package.md`). It is
not optional: a package with the guard and a page that does not send the token fails every save.

## Layering summary

| Layer | Job |
|---|---|
| DB constraints (PK/FK/UQ/CHECK) | last-line integrity, race backstop |
| Entity package `pkg_<entity>` | one entity's business rules; the only DML on its table and its satellites; friendly `-20xxx` errors |
| Flow package `pkg_<flow>_flow` | the order of a multi-entity operation and the invariant spanning it — no DML of its own |
| Integration package `pkg_<system>_api` | one external system's protocol — no business rule, no entity DML |
| `.apx` process (`afterSubmit`) | normalize input, call the package, surface errors |
| `.apx` validation / column hints | field-shape only (required, maxLength) |
| `v_*` views / inline SQL | all reads |
