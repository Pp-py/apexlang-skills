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
   () => [...document.querySelectorAll('td span.t-Badge')].map(b => b.innerText.trim())
   ```

   The page renders `<span class="t-Badge #STATUS_CSS#">#STATUS#</span>`, so the texts are the
   raw upper-case statuses: expect a non-empty list containing `APPROVED` (seed row `1002`).
   An empty list means the selector does not match the page — never a pass. Take one
   snapshot only if you still need the resolve icon's ref (CLI: Grep the YAML for it).

## 2. Illegal transition first (non-mutating — use the already-APPROVED row)

1. Open the resolve modal for the **1002 / Approved** row.
2. click **Approve** again.
3. Assert the package guard fires:
   `Only an absence in REQUESTED status can be approved.` (friendly, no `ORA-20901:`
   prefix), and the state is unchanged:

```
select status from hr_absences where employee_no = '1002';   -- still APPROVED
```

(If the app instead **hides** the Approve button for non-REQUESTED rows via
`serverSideCondition`, assert the button is absent — by a selector that demonstrably
matches the button where it IS shown, on the fixture row of §3; a lookup that matches
nothing is not evidence of absence. The guard error message is then not exercised.)

## 3. Legal transition (mutating — on a fixture row, never on the seed)

Approving the seed's REQUESTED row would change the data the next run expects, so the
mutating step runs on a throwaway fixture created through the package itself:

```
sql -name <conn>
begin
  pkg_absences.create_row(p_employee_no => 'ZZ-SENTINEL', p_absence_type => 'VACATION',
                          p_date_from => date '2099-01-01', p_date_to => date '2099-01-02');
  commit;
end;
/
select absence_id from hr_absences where employee_no = 'ZZ-SENTINEL' and cancelled_at is null;
```

(Its future dates put it first in the master, which orders by `date_from desc`.)

1. click the resolve icon (gavel) on the **ZZ-SENTINEL / REQUESTED** row → modal page 62
   opens with `P62_ABSENCE_ID` set (reached the real way, so APEX carries the PK + session).
2. click **Approve**.
3. Assert the dialog closes and, back on the master, the fixture's badge is now
   **APPROVED** (re-run the §1 `eval`, or `wait` for the new text — not a re-snapshot).
4. Confirm with SQLcl that state + audit stamp changed — `approved_by` is the test user,
   which also cross-checks the login:

```
select status, approved_by, approved_at from hr_absences where employee_no = 'ZZ-SENTINEL' and cancelled_at is null;
-- expect APPROVED, the test user, a timestamp
```

5. Cleanup — the package's own verb, a soft delete that hides the row from the master
   (one cancelled `ZZ-SENTINEL` row stays behind per run, by design):

```
begin
  pkg_absences.cancel(p_absence_id => <absence_id>, p_reason => 'apex-sentinel fixture', p_user => 'APEX-SENTINEL');
  commit;
end;
/
```

## Pass criteria

- `WF-LEGAL-TRANSITION` — Badges render (a non-empty list from the page's own markup), and the legal transition, on the fixture, flips badge + `approved_by`/`approved_at`; the fixture is cancelled afterwards.
- `WF-ILLEGAL-BLOCKED` — The illegal transition is blocked (guard error or hidden button); `status` unchanged.
