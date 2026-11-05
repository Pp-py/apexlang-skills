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

**Then correct and resubmit in the same page or drawer** — do not reopen it. The submit control must still be enabled (a "disable on submit" dynamic action that is not undone when the server returns errors leaves it dead), and the corrected submit succeeds exactly once: on the full page as the create that returns it in edit mode (`FORM-CREATE`), on the drawer by closing it and refreshing the list. Procedure, snippet and the three SQL counts (`n, n, n+1`): `modal-crud.md` §Then correct and resubmit. Do the rejection first and the resubmit is the valid write of step 2, not an extra one.

Cancel the drawer and assert the calling list did **not** refresh (cancel fires `apexafterclosecanceldialog`, not `apexafterclosedialog`).

**Drawer opened by its URL without a session:** `modal-crud.md` §Dialog without a session; report it as `MODAL-NO-SESSION`, with `NOT_RUN` on a full page. Data leaking there is `SEC-ANON-REDIRECT`'s, not this check's.

## Confirm

`sql -name <conn>`: the row exists with the submitted values after a valid save, and **no row was inserted** after a rejection. UI "saved" ≠ row exists.

For delete, read the entity's retention first: a `rule` decision whose subject begins `retention:` in the task's `architecture-result` (`<evidenceDir>/<task>/architecture.json`; `apexlang-architecture/back-end-conventions.md` §6). None means **soft**, and `FORM-HARD-DELETE` is `NOT_RUN`.

- **Soft** (the default): the row is still there with `active_flag = 'N'` (or `cancelled_at` set), not gone.
- **Hard** (declared): the row is gone and so are the dependents the declaration names, and no other row changed. Delete is refused — friendly message, row and dependents intact — while a row **other than the declared dependents** still references it.

## Pass criteria

Each criterion has an ID: a runtime-result (`framework/schemas/runtime-result.schema.json`) reports it by that ID, with what was observed and the evidence it rests on.

- `FORM-CREATE` — Create mode shows only the create action; a valid create returns the page in edit mode with the new PK.
- `FORM-UPDATE` — Edit mode prefills; a valid update persists.
- `FORM-REFUSED-SUBMIT` — A refused submit shows a friendly package error, leaves the drawer open, and writes nothing, and the same page or drawer accepts the corrected values exactly once.
- `FORM-SOFT-DELETE` — For an entity whose retention is soft (the default, when none is declared), delete deactivates rather than deleting. `NOT_RUN` when the declared retention is hard.
- `FORM-HARD-DELETE` — For an entity whose declared retention is hard, delete removes the row and exactly the dependents the declaration names, and is refused while a row other than the declared dependents references it. `NOT_RUN` when the retention is soft or undeclared.
