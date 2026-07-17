# Check: master + create/edit modal

**Verifies** `apexlang-architecture/recipes/modal-crud-to-package.md`.

**REQUIRED BACKGROUND:** `setup.md` and `SKILL.md` §Snapshot diet.

## Steps

1. Navigate to the **master** page (with `?session=<token>`). Assert render with `eval` (report rows present, no error region — see the §1 snippet in `editable-ig.md`). Take **one** snapshot only to locate the row's edit/link icon ref (CLI: Grep the YAML for the icon; MCP: note the ref, don't re-snapshot).
2. **Open the modal the real way:** `click` that edit/link icon. This makes APEX set the PK item *and* carry the session — don't deep-link the modal standalone. Assert the dialog opened and (for edit) prefilled: `eval` → `apex.item('Px_<PK>').getValue()` / the dialog's visible title text — not a fresh snapshot.
3. Fill fields + submit as **one batched round-trip** (fill form / `run code`).
4. Assert the **dialog closed** and the master **refreshed**: `eval` → dialog absent (`!document.querySelector('.ui-dialog:not([style*="display: none"])')`) and the new/edited value present in the report region's text.

## Rejection path (non-mutating, high value)

Submit a value that violates a business rule (duplicate, "date must be later than", etc.). Assert via `eval` of the notification/error region text: the modal **stays open**, the error cites the package rule, and the message is **friendly** (no raw `ORA-NNNNN:` prefix — same defect to watch as in `editable-ig.md`).

## Confirm

For a real write, `sql -name <conn>` to confirm the row landed (or didn't, on rejection). UI "saved" ≠ row exists.

## Pass criteria

- Edit icon opens a prefilled modal.
- Valid submit closes the modal and updates the master.
- Invalid submit keeps the modal open with a friendly package error; DB unchanged.
