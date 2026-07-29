# Verification walkthrough: absences workflow (state transitions)

Concrete instantiation of `checks/workflow-state.md` against the example pages built in
`apexlang-architecture/examples/absences-workflow/` (master page 60, modal page 62).
Read `../setup.md` first.

Goal: prove a transition is a **package verb with a legal-state guard**, surfaced as a state
change — and that an illegal transition is blocked (non-mutating).

## Step 0 — prerequisite (do NOT skip)

Resolve a browser backend with the launcher probe in `../SKILL.md` §Prerequisites — Playwright
CLI first (global binary *or* npx), browser-MCP only if that resolves nothing (`../setup.md` §0).
If neither is available, **stop and report**. Don't substitute validate/import as proof.

## 1. Render the master

1. navigate to page 60 with the session token (`?session=<token>`).
2. Assert rows render with **status badges** via `eval` — read the badge texts directly
   instead of snapshotting:

   ```js
   () => [...document.querySelectorAll('.t-Badge, [class*="badge"]')].map(b => b.innerText)
   ```

   Expect the employee `1001` row **Requested** and the `1002` row **Approved**. Take one
   snapshot only if you still need the resolve icon's ref (CLI: Grep the YAML for it).

## 2. Legal transition (mutating — use the REQUESTED row)

1. click the resolve icon (gavel) on the **1001 / Requested** row → modal page 62 opens
   with `P62_ABSENCE_ID` set (reached the real way, so APEX carries the PK + session).
2. click **Approve**.
3. Assert the dialog closes and, back on the master, the `1001` badge is now **Approved**
   (re-run the §1 `eval`, or `wait` for the new badge text — not a re-snapshot).
4. Confirm with SQLcl that state + audit stamp changed (and any side effect applied):

```
sql -name <conn>
select status, approved_by, approved_at from hr_absences where employee_no = '1001';
-- expect APPROVED, a user, a timestamp
```

## 3. Illegal transition (non-mutating — use the already-APPROVED row)

1. Open the resolve modal for the **1002 / Approved** row.
2. click **Approve** again.
3. Assert the package guard fires:
   `Only an absence in REQUESTED status can be approved.` (friendly, no `ORA-20901:`
   prefix), and the state is unchanged:

```
select status from hr_absences where employee_no = '1002';   -- still APPROVED
```

(If the app instead correctly **hides** the Approve button for non-REQUESTED rows via
`serverSideCondition`, that's an equally valid pass — assert the button is absent.)

## Pass criteria

- Badges render; the legal transition flips badge + `approved_by`/`approved_at`.
- The illegal transition is blocked (guard error or hidden button); `status` unchanged.
- No process wrote `status` directly — the guard + audit stamp prove it routed through the verb.
