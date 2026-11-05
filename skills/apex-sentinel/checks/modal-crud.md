# Check: master + create/edit modal

**Verifies** `apexlang-architecture/recipes/modal-crud-to-package.md`.

**REQUIRED BACKGROUND:** `setup.md` and `SKILL.md` §Snapshot diet.

## Steps

1. Navigate to the **master** page (with `?session=<token>`). Assert render with `eval` (report rows present, no error region — see the §1 snippet in `editable-ig.md`). Take **one** snapshot only to locate the row's edit/link icon ref (CLI: `pw.sh find <label>`, or Grep the YAML; MCP: note the ref, don't re-snapshot).
2. **Open the modal the real way:** `click` that edit/link icon. This makes APEX set the PK item *and* carry the session — don't deep-link the modal standalone. Assert the dialog opened and (for edit) prefilled: `eval` → `apex.item('Px_<PK>').getValue()` / the dialog's visible title text — not a fresh snapshot.
3. Fill fields + submit as **one batched round-trip** (fill form / `run code`). If the rejection path below is also run, run it **first**: its corrected resubmit is this write, not an extra one.
4. Assert the **dialog closed** and the master **refreshed**: `eval` → dialog absent (`!document.querySelector('.ui-dialog:not([style*="display: none"])')`) and the new/edited value present in the report region's text.

## Rejection path (non-mutating, high value)

Submit a value that violates a business rule (duplicate, "date must be later than", etc.). Assert via `eval` of the notification/error region text: the modal **stays open**, the error cites the package rule, and the message is **friendly** (no raw `ORA-NNNNN:` prefix — same defect to watch as in `editable-ig.md`).

### Then correct and resubmit in the same dialog

Do not close the dialog after the rejection. A dynamic action that disables the submit button on click and is not undone when the server answers with errors leaves the dialog dead: the next click times out, and the user must close it and lose what they typed. The assertions above never see that.

1. Still in the refused dialog, read the submit button's state in the dialog's frame (a modal page is an iframe inside `.ui-dialog`; an inline dialog is not — read the button in the page itself):

   ```js
   async (page) => {
     const b = page.frameLocator('.ui-dialog iframe').locator('#<submit-static-id>');
     const present = await b.count();
     return { present, enabled: present ? await b.isEnabled() : null,
              apexDisabled: present ? await b.evaluate(e => e.classList.contains('apex_disabled')) : null };
   }
   ```

   `present: 0` is UNKNOWN (a wrong id, not a pass). `enabled: false` or `apexDisabled: true` is a **FAIL** of `MODAL-REFUSED-SUBMIT` — report the dynamic action that disables the button and does not revert it.
2. Correct the offending field and click the **same** button in the **same** dialog, with no reopening. Assert as in step 4: dialog closed, master refreshed with the corrected value.
3. `sql -name <conn>` three times: before the rejection, after it, after the resubmit. Create: `n, n, n+1` for the key — the rejection wrote nothing, the resubmit wrote once (`n+2` is a double submit). Edit: the rejected value was never in the row (read it after the rejection), the corrected one is, and `row_version` moved once.

## Dialog without a session (negative, non-mutating)

Two tests, kept apart in `observed`: the **normal opening** (steps 1-2 and `MODAL-OPEN-PREFILLED`; never deep-link to test it) and the **direct URL** — the dialog's URL as the link built it, with `session` removed, opened in a **second `pw.sh` session that never logs in**, the way `sec-probe.py` holds the low-privilege user in its own:

```sh
PW_SESSION=<s>-anon pw.sh [--app <alias>] open '<dialog URL without session>'
PW_SESSION=<s>-anon pw.sh eval '() => ({ password: !!document.querySelector("input[type=password]"), step: (document.getElementById("pFlowStepId") || {}).value || null, controls: [...document.querySelectorAll("a, button")].filter(e => e.offsetParent).map(e => e.innerText.trim()).slice(0, 8) })'
PW_SESSION=<s>-anon pw.sh close
```

`<s>` is the held session's name (`$PW_SESSION`, default `apex`). `pw.sh` hands the second session the same TLS config as the first (`PW_INSECURE_TLS` applies to both; checked against a stub of the Playwright CLI, not yet against a self-signed APEX), and it never touches the held login. Close it with `close`, never `close-all`, which would end the held session too. `open` also replaces the workspace's remembered last URL (session removed), which matters only if the held browser dies and is recovered.

The contract is `SEC-ANON-REDIRECT` (`apex-security`): a request without a session for a page that is not public ends on the login page, never on the page's content. This check reads the **navigation** half for a dialog:

- It ended on the login (`password: true`, or a redirect to it): met. An error page that offers a control which reaches the login also meets it — click that control in the same session (`find`, `click`) and read again.
- A page that offers only a way back, or stays an error, is a **dead end: FAIL**. A "session ended" page that APEX itself renders is not by itself a defect of the app: say in `observed` whether the markup is Oracle's own, and that whether stock APEX serves the same page for the same URL has not been measured (`tests/live`, to be measured in the lab). Never relax Session State Protection or checksums to get a prettier page.
- **Data**: no value of any record may appear in the page text. If one does, stop — that is `SEC-ANON-REDIRECT`'s verdict (`sec-probe.py --anon <url>`, which reads APEX's error page under the requested page id as UNKNOWN, never FAIL), not this check's; record it there, not twice. A full-page form has no dialog to test: `NOT_RUN` with that reason.

## Confirm

For a real write, `sql -name <conn>` to confirm the row landed (or didn't, on rejection). UI "saved" ≠ row exists.

## Pass criteria

Each criterion has an ID: a runtime-result (`framework/schemas/runtime-result.schema.json`) reports it by that ID, with what was observed and the evidence it rests on.

- `MODAL-OPEN-PREFILLED` — Edit icon opens a prefilled modal.
- `MODAL-SUBMIT-CLOSES` — Valid submit closes the modal and updates the master.
- `MODAL-REFUSED-SUBMIT` — Invalid submit keeps the modal open with a friendly package error; DB unchanged, and the same dialog accepts the corrected values exactly once.
- `MODAL-NO-SESSION` — A dialog URL requested without a session shows no record data and leaves the user a working way to the login page (the login itself, a redirect to it, or a control that reaches it), never a dead end.
