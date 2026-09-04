# Check: full-page / drawer form

**Verifies** `apexlang-architecture/recipes/form-page-to-package.md`.

**REQUIRED BACKGROUND:** `setup.md` and `SKILL.md` §Snapshot diet.

## Steps

1. **Create mode.** Navigate to the form page with **no PK** in the URL (`?session=<token>`). Assert with one `eval`: the create button is present and the update/delete buttons are **absent** (`document.getElementById('B_CREATE')` style lookups, or the buttons' visible labels) — that asymmetry is the `serverSideCondition` on the PK item doing its job. A page showing Create *and* Apply Changes means the conditions are not wired.
2. Fill every required item and submit as **one batched round-trip** (fill form / `run code`). Assert the success notification and — the part that matters — that the page came back in **edit mode**: `eval` → `apex.item('Px_<PK>').getValue()` is now non-empty. That is the generated PK the process copied back; empty means the write happened but the page lost the row.
3. **Edit mode.** Open the same row the real way (from the list that links to it, so APEX sets the PK item and carries the session) and assert the items are **prefilled** via `eval` of `apex.item(...).getValue()` — not a fresh snapshot.
4. Change one value, submit, and assert the new value survives a reload of the same PK.

## Rejection path (non-mutating, high value)

Submit a value the package refuses (duplicate email, inactive FK, missing required field). Assert via `eval` of the notification/error region text: the error cites the **package** rule and is **friendly** — no raw `ORA-NNNNN:` prefix (that means the Error Handling Function is not registered).

**On the drawer variant this is the whole check:** assert the drawer is **still open** after the rejection — `eval` → a visible dialog still in the DOM (`document.querySelector('.ui-dialog:not([style*="display: none"])')`). A drawer that closed on a failed submit is the defect this recipe exists to prevent: the close is a `:REQUEST`-gated `closeDialog` **process**, not a button trigger action.

Then cancel the drawer and assert the calling list did **not** refresh (cancel fires `apexafterclosecanceldialog`, not `apexafterclosedialog`).

## Confirm

`sql -name <conn>`: the row exists with the submitted values after a valid save, and **no row was inserted** after a rejection. UI "saved" ≠ row exists.

For delete, confirm the soft delete: the row is still there with `active_flag = 'N'` (or `cancelled_at` set), not gone.

## Pass criteria

- Create mode shows only the create action; a valid create returns the page in edit mode with the new PK.
- Edit mode prefills; a valid update persists.
- A refused submit shows a friendly package error, leaves the drawer open, and writes nothing.
- Delete deactivates rather than deleting.
