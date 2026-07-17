# Recipe: workflow / state-machine entity

**Use for:** records that move through states (requests, approvals, orders): REQUESTED → APPROVED/REJECTED, plus soft-delete (cancel). The transitions carry side effects, so they are **named package operations**, not raw `UPDATE status`.

**REQUIRED BACKGROUND:** `back-end-conventions.md` (single write-path, soft-delete §6).

## Principle

A transition is a verb with rules and side effects, not a column write:

- `approve` may need to check balance, stamp approver + timestamp, deduct a quota.
- `reject` records a reason.
- `cancel` reverses a previously-approved effect (e.g. give back vacation days).

So the package exposes `create_row` / `approve` / `reject` / `cancel` — each enforcing which *from-state* is legal. The UI never sets `status` directly.

```plsql
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
    -- side effect: deduct quota, etc. — all inside the package
END approve;
```

The legal-transition guard lives here so every caller (UI, job, REST) is bound by it.

## `.apx` — master IR with status badges

```
region requests (
    type: interactiveReport
    source { type: sqlQuery  sqlQuery: ```sql
        select absence_id, employee_no, absence_type, date_from, date_to,
               case status
                    when 'APPROVED' then '<span class="bdg bdg--green">Approved</span>'
                    when 'REJECTED' then '<span class="bdg bdg--red">Rejected</span>'
                    else '<span class="bdg bdg--amber">Requested</span>'
               end as status_bdg
          from hr_absences where cancelled_at is null order by date_from desc``` }
    column STATUS_BDG ( type: plainText  columnFormatting { htmlExpression: #STATUS_BDG!RAW# } )
    link { linkColumn: customTarget
        target { page: 62  items { P62_ABSENCE_ID: #ABSENCE_ID# }  clearCache: 62 }
        linkIcon: <span class="fa fa-gavel"></span> }
)
```

## `.apx` — resolve modal (approve / reject as distinct buttons)

`close-dialog` closes on success ONLY — last submit-time sequence, gated to the transition requests. A `-20xxx` guard error halts the submit, so the modal stays open showing the friendly message.

```
button approve ( buttonName: APPROVE  label: Approve  layout { region: @form-resolve  slot: create } )
button reject  ( buttonName: REJECT   label: Reject   layout { region: @form-resolve  slot: delete } )

process approve (
    type: executeCode
    source { plsqlCode: ```plsql pkg_absences.approve(:P62_ABSENCE_ID, :APP_USER);``` }
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

Each button submits with its `buttonName` as `:REQUEST`; each process is gated by `serverSideCondition { plsqlExpression: :REQUEST = '<BUTTONNAME>' }` so exactly one transition runs. No process writes `status` directly. (This `:REQUEST`-matching gate is the validated pattern; do not invent a `whenButtonPressed` attribute on process `execution`.)

On the master page, wire the `apexafterclosedialog` → refresh dynamic action so the badge flips without a manual reload — see `modal-crud-to-package.md` §Close & refresh; verify with `apex-sentinel/checks/workflow-state.md`.

## Common mistakes

| Tempting | Why wrong |
|---|---|
| An IG/form that lets you edit the `status` column | Skips the legal-transition guard and the side effects (quota, audit stamp). State changes must be verbs. |
| "Reject" just sets a column with a page process | Loses the reason capture and the from-state check. Route through `pkg.reject`. |
| Hard delete a request | Use soft-delete (`cancelled_at`) so history and any reversal stay auditable. |
