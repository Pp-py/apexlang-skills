# Recipe: workflow / state-machine entity

**Use for:** records that move through states (requests, approvals, orders): REQUESTED → APPROVED/REJECTED, plus soft-delete (cancel). The transitions carry side effects, so they are **named package operations**, not raw `UPDATE status`.

**REQUIRED BACKGROUND:** `back-end-conventions.md` (single write-path, soft-delete §6); `package-boundaries.md` (which package a transition with side effects belongs to).

## Principle

A transition is a verb with rules and side effects, not a column write:

- `approve` may need to check balance, stamp approver + timestamp, deduct a quota.
- `reject` records a reason.
- `cancel` reverses a previously-approved effect (e.g. give back vacation days).

The state change is always a named operation enforcing which *from-state* is legal, and the UI never
sets `status` directly. **Which package it lives on depends on what the side effect writes:**

| The transition writes | Where it lives |
|---|---|
| Only the entity and its satellites — status, audit stamp, an event row | the **entity package**: `pkg_absences.approve` |
| A second independent entity as well — the employee's quota, stock, a ledger | a **`_flow` package**: `pkg_absence_flow.approve`, coordinating `pkg_absences` + `pkg_quotas` |

The quota is the common case, and it is **not** a satellite of the absence: its FK points at the
employee, and payroll writes it too (`package-boundaries.md` §Test 1). So an `approve` that deducts a
quota is a domain operation — the entity package keeps the from-state guard, and the flow owns the
sequence, the spanning invariant and the lock order.

```plsql
-- Entity package: owns hr_absences, guards the from-state, writes nothing else.
PROCEDURE approve (p_absence_id IN NUMBER, p_approver IN VARCHAR2) IS
    l_status hr_absences.status%TYPE;
BEGIN
    SELECT status INTO l_status FROM hr_absences
     WHERE absence_id = p_absence_id AND cancelled_at IS NULL FOR UPDATE;
    IF l_status <> 'REQUESTED' THEN
        RAISE_APPLICATION_ERROR(pkg_errors.k_absence_invalid_status,
            'Only an absence in REQUESTED status can be approved.');
    END IF;
    UPDATE hr_absences
       SET status = 'APPROVED', approved_by = p_approver, approved_at = SYSTIMESTAMP
     WHERE absence_id = p_absence_id;
END approve;
```

The legal-transition guard lives here so every caller (UI, job, REST) is bound by it.

When the transition also has to deduct a quota, that write belongs to the quota's own package and the
coordination to a flow — no `COMMIT`, and the lock order stated in the header
(`back-end-conventions.md` §4):

```plsql
-- Flow package: coordinates two entities, issues no DML of its own.
PROCEDURE approve (p_absence_id IN NUMBER, p_approver IN VARCHAR2) IS
    l_employee_id hr_absences.employee_id%TYPE;
    l_days        PLS_INTEGER;
BEGIN
    -- Reading another entity to decide is allowed in any layer
    -- (back-end-conventions.md section 5).
    SELECT employee_id, date_to - date_from + 1
      INTO l_employee_id, l_days
      FROM hr_absences WHERE absence_id = p_absence_id;

    pkg_absences.approve(p_absence_id, p_approver);   -- locks the absence first,
    pkg_quotas.deduct(l_employee_id, l_days);         -- then the quota row.
END approve;
```

The flow owns the *invariant* — *no approval without balance* is its contract — but **the check does
not live here.** It lives inside `pkg_quotas.deduct`, immediately after the lock that protects the row
it reads:

```plsql
-- Entity package: the balance is checked under the lock that protects it.
PROCEDURE deduct (p_employee_id IN NUMBER, p_days IN PLS_INTEGER) IS
    l_days_left hr_employee_quota.days_left%TYPE;
BEGIN
    SELECT days_left INTO l_days_left FROM hr_employee_quota
     WHERE employee_id = p_employee_id FOR UPDATE;
    IF l_days_left < p_days THEN
        RAISE_APPLICATION_ERROR(pkg_errors.k_quota_insufficient,
            'The employee does not have enough days left.');
    END IF;
    UPDATE hr_employee_quota SET days_left = days_left - p_days
     WHERE employee_id = p_employee_id;
END deduct;
```

**Where the check sits matters more than which package declares it.** Read the balance in the flow,
before anything is locked, and two concurrent approvals both pass it and both deduct — a
check-then-act race that the friendly error will never report, and which also reads the quota *before*
the absence lock, against the order the flow declares. Under the `FOR UPDATE` the second caller waits,
then re-reads the decremented balance and is refused. In `pkg_absences` the whole thing would force
that package to write the quota; in the page it would let a job approve without checking at all.

## `.apx` — master IR with status badges

```
region requests (
    type: interactiveReport
    source { type: sqlQuery  sqlQuery: ```sql
        select absence_id, employee_no, absence_type, date_from, date_to, status,
               case status
                    when 'APPROVED' then 'u-color-9-text'
                    when 'REJECTED' then 'u-color-7-text'
                    else 'u-color-15-text'
               end as status_css
          from hr_absences where cancelled_at is null order by date_from desc``` }
    column STATUS ( type: plainText
        columnFormatting { htmlExpression: <span class="#STATUS_CSS#">#STATUS#</span> } )
    column STATUS_CSS ( type: hidden  source { dataType: STRING } )
    column ABSENCE_ID ( type: plainText
        heading { heading: Resolve }
        source { dataType: NUMBER }
        link {
            target { page: 62  items { P62_ABSENCE_ID: #ABSENCE_ID# }  clearCache: 62 }
            linkText: <span class="fa fa-gavel"></span> } )
)
```

Two rules the compiler enforces here:

- **No markup in the query.** `source.sqlQuery` must be data-only (`REPORT_SQL_HTML_LITERAL_FORBIDDEN_001`): project the status and a plain CSS token, and let the column's `columnFormatting.htmlExpression` build the badge. The `case` above therefore yields `u-color-9-text`, not a `<span>`.
- **The link belongs to a column**, never to the region — see `modal-crud-to-package.md` for the full note.

## `.apx` — resolve modal (approve / reject as distinct buttons)

`close-dialog` closes on success ONLY — last submit-time sequence, gated to the transition requests. A `-20xxx` guard error halts the submit, so the modal stays open showing the friendly message.

```
button approve ( buttonName: APPROVE  label: Approve  layout { region: @form-resolve  slot: create } )
button reject  ( buttonName: REJECT   label: Reject   layout { region: @form-resolve  slot: delete } )

process approve (
    type: executeCode
    source { plsqlCode: ```plsql pkg_absence_flow.approve(:P62_ABSENCE_ID, :APP_USER);``` }
    execution { sequence: 10  point: afterSubmit }
    serverSideCondition { type: expression  plsqlExpression: :REQUEST = 'APPROVE' }
)
process reject (
    type: executeCode
    source { plsqlCode: ```plsql pkg_absences.reject(:P62_ABSENCE_ID, :P62_REASON);``` }
    execution { sequence: 20  point: afterSubmit }
    serverSideCondition { type: expression  plsqlExpression: :REQUEST = 'REJECT' }
)

process close-dialog (
    type: closeDialog
    execution { sequence: 90 }
    serverSideCondition { type: expression  plsqlExpression: :REQUEST in ('APPROVE','REJECT') }
)
```

Note the two targets: `approve` goes to the flow package because it deducts a quota, while `reject`
only records a reason on the absence itself and stays on the entity package. The page does not know
or care which layer it is calling — it states one intent per button.

Each button submits with its `buttonName` as `:REQUEST`; each process is gated by `serverSideCondition { plsqlExpression: :REQUEST = '<BUTTONNAME>' }` so exactly one transition runs. No process writes `status` directly. (This `:REQUEST`-matching gate is the validated pattern; do not invent a `whenButtonPressed` attribute on process `execution`.)

On the master page, wire the `apexafterclosedialog` → refresh dynamic action so the badge flips without a manual reload — see `modal-crud-to-package.md` §Close & refresh; verify with `apex-sentinel/checks/workflow-state.md`.

## Common mistakes

| Tempting | Why wrong |
|---|---|
| An IG/form that lets you edit the `status` column | Skips the legal-transition guard and the side effects (quota, audit stamp). State changes must be verbs. |
| "Reject" just sets a column with a page process | Loses the reason capture and the from-state check. Route through `pkg.reject`. |
| Hard delete a request | Use soft-delete (`cancelled_at`) so history and any reversal stay auditable. |
