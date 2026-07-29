# Verification walkthrough: sectors catalog (editable IG)

Concrete instantiation of `checks/editable-ig.md` against the example page built in
`apexlang-architecture/examples/sectors-catalog/` (page 30). Read `../setup.md` first.

Goal: prove the IG **routes writes through `pkg_sectors`** and that a duplicate code is
rejected with a **friendly** error — without persisting test data (the rejection path).

## Step 0 — prerequisite (do NOT skip)

Resolve a browser backend with the launcher probe in `../SKILL.md` §Prerequisites — Playwright
CLI first (global binary *or* npx; a missing global binary is **not** a missing CLI), browser-MCP
only if that resolves nothing. See `../setup.md` §0. If neither is available, **stop and report** —
`apex validate`/`import` already succeeded but prove nothing about rendering. Don't fake it.

## 1. Connect & render

1. Resolve the base URL and log in (batched — one round-trip) — see `../setup.md` §0–§2.
2. navigate to page 30 with the session token appended (`?session=<token>`).
3. Assert render with one `eval` — no snapshot:

   ```js
   () => ({
     rows: apex.region('sectors').call('getViews').grid.model.getTotalRecords(),
     error: document.querySelector('#t_Alert_Notification')?.innerText ?? null
   })
   ```

   Expect `rows >= 2` (seed rows **PROD** and **ADM**) and `error: null`.

## 2. Drive the rejection path (non-mutating, high value)

The add-row dance is a fixed sequence — run it as **one** `run code` round-trip
(MCP: `browser_run_code_unsafe`; CLI: batched commands), not stepwise with snapshots:

1. click **Add Row** → a new editable row appears.
2. Double-click the **Code** cell → it becomes a textbox; type `PROD` (a code that
   already exists).
3. Double-click **Name**, type a throwaway like `ZZZ duplicate`.
4. click **Save**.

Then re-run the §1 `eval` and assert on the notification text:
   - **Routing (must pass):** an error region cites the package rule —
     `A sector with code PROD already exists.` This proves the write went through
     `pkg_sectors.create_row` (the duplicate check), not raw Automatic DML.
   - **Friendliness (must pass here — the EHF is installed):** the message has **no**
     `ORA-20800:` prefix. If you see `ORA-20800: A sector with code...`, the Error Handling
     Function isn't registered — flag it (see `../checks/editable-ig.md` §3 and
     `apexlang-architecture/examples/00-error_handling_function.sql`).

## 3. Confirm the DB is unchanged

```
sql -name <conn>
select count(*) from hr_sectors where upper(code) = 'PROD';   -- expect 1, not 2
```

The UI rejecting is necessary; the row count being unchanged is the proof.

## 4. Cleanup

The unsaved row sits in the IG edit buffer. Navigating away triggers a beforeunload dialog →
handle dialog (accept). Nothing committed, so no DB cleanup — the count above already confirmed it.

## Pass criteria

- Grid renders the seed rows.
- Duplicate Save → package error region, row rejected, `count(PROD) = 1` unchanged.
- Message is friendly (no `ORA-` prefix).
