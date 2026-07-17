# Check: editable Interactive Grid

**Verifies the promise of** `apexlang-architecture/recipes/editable-ig-to-package.md`: the IG routes writes through a package, and business rules surface as **friendly** errors.

**REQUIRED BACKGROUND:** `setup.md` (backend config, login, session token) and `SKILL.md` §Snapshot diet. IG pages have the largest accessibility trees in APEX — this check is where the diet matters most.

## 1. Render

Navigate (with `?session=<token>`), then assert render with one `eval` — no snapshot:

```js
() => ({
  rows: apex.region('<static-id>').call('getViews').grid.model.getTotalRecords(),
  error: document.querySelector('#t_Alert_Notification')?.innerText ?? null
})
```

Assert `rows > 0` and `error` null. (If the region has no static ID, one snapshot to find it is fine — then keep using `eval`.)

## 2. Inline-edit mechanics (non-obvious)

IG cells are `<td role="gridcell">`, **not inputs**. Typing into the cell fails (`Element is not an <input>`); a cell only swaps to an editable `textbox`/`combobox` on **double-click** (single click focuses). The whole dance is a fixed sequence — no reasoning needed between steps — so run it as **one round-trip** (`run code` / batched CLI), not stepwise with a snapshot per action:

1. click **Add Row** (toolbar) → new empty row, grid enters edit mode.
2. Per required column: double-click the cell → type into the revealed input. Fill **all** required columns (the save process enforces required fields *before* the package call, so missing one tests the wrong path).
3. click **Save**.

MCP: `browser_run_code_unsafe` with `getByRole('button', { name: 'Add Row' })`, `getByRole('gridcell', …).dblclick()`, etc. CLI: batch the equivalent commands; Grep the on-disk snapshot once if you need refs first.

## 3. The high-value assertion — rejection path (non-mutating)

Make the new row's code **duplicate an existing one**, throwaway values elsewhere, Save. Then read the error region with the same `eval` as §1 — the notification text is the assertion target, no snapshot needed.

**Two levels of assertion:**

- **Routing (must pass):** the error text cites the package's business rule — e.g. `A level with code MANAGEMENT already exists.` with the package's `-20940`-band code. This proves the write went **through the package**, not raw automatic DML, and the duplicate was **rejected** (no insert).
- **Friendliness (often fails — this is the gold):** the text must **not** start with a raw `ORA-NNNNN:` prefix. Observed in a real app: `ORA-20940: A level with code...` — the package raised correctly, but the app has **no application-level Error Handling Function** registered (see `apexlang-architecture/back-end-conventions.md` §3), so the `ORA-` prefix leaks to the user. **validate and import never catch this; only the browser does.** Flag it as a defect: register the error-handling function.

Then confirm **no row persisted**: `sql -name <conn>` → `select count(*) ... where <dup-key>` returns the original count. The UI rejecting is necessary; the DB being unchanged is the proof.

## 4. Cleanup

The unsaved row sits in the IG edit buffer. Navigating away triggers a beforeunload dialog → handle dialog (accept). Nothing was committed (the Save was rejected), so no DB cleanup is needed — but verify with the SQL count above.

## Pass criteria

- Grid renders with data (`getTotalRecords() > 0`).
- Duplicate Save → package error in the notification region, row rejected, DB count unchanged.
- Message is friendly (no `ORA-` prefix) — or you've flagged the missing error-handling function.
