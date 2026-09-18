# Recipe: wizard / multi-step input

**Use for:** input a user cannot give in one screen — an onboarding, a claim with several sections, a
purchase request that collects a header and then its lines. Several steps, one outcome.

**REQUIRED BACKGROUND:** `back-end-conventions.md` (single write-path, no COMMIT, error catalog); `package-boundaries.md` §Test 1 if a step writes a second entity.

**Contents:** the one decision (where partial state lives) · when the package writes · the shell ·
validation across steps · going back · abandoned drafts · common mistakes · verify.

The shell is official and small: `dialogTemplate: @/wizard-modal-dialog`, one page whose step regions
are gated by `serverSideCondition { type: request=Value  value: STEP2 }`, buttons setting `:REQUEST`.
Copy that from the official `apex` skill. Everything below is the part it does not decide — and the
part that decides whether the wizard survives a closed laptop.

## The one decision: where partial state lives

A wizard is a transaction the user takes minutes to type. Until the last step, the data has to live
somewhere that is neither the final table nor nowhere:

| State lives in | Choose when | What it costs |
|---|---|---|
| **Session state** (page items across steps) | 2–4 steps, one sitting, nothing to resume; the classic "create X" wizard | Dies with the session. A closed browser is lost work, and nothing can be audited or reported on |
| **A draft row** in the real table (`status = 'DRAFT'`) | The user must be able to leave and come back; the entity is long-lived (a claim, an application) | Every query, view and constraint in the system must now tolerate incomplete rows — and remember to exclude drafts |
| **A staging table** written by the package | The wizard collects *rows* (lines, participants, files), or the target table must never see a partial record | One more table and a cleanup story — but it is queryable, testable and backed up |

Default to **session state** for a short create wizard; that is most of them, and it keeps the model
clean. Escalate to a **draft row** only when resumability is an actual requirement someone asked for,
because it is a change to your data model, not a UI decision — and it must be declared: the status
column, the `WHERE status <> 'DRAFT'` in every consuming view, the constraints that must become
conditional.

**Do not reach for `apex_collection`** as the middle option. It looks like the cheap staging table
and is not one: it lives and dies with the session (so it does not give you resumability), it is
untyped, no constraint or foreign key protects it, and nothing outside APEX can read it — which means
you cannot test the wizard's logic without a browser session. If the wizard needs a place to put rows,
that place is a table your package owns. A staging table is the one child the satellite test cannot
classify — there is no parent row yet to carry a `NOT NULL` FK to (`package-boundaries.md` §Test 1,
clause 1) — so ownership follows the operation instead: the package that will create the entity owns
its staging area, and clears it when it does.

## When the package writes

The package exposes **one intent-named entry point for the whole wizard** — not `create_row` called
three times:

```plsql
PROCEDURE create_request (p_employee_id IN NUMBER,
                          p_reason      IN VARCHAR2,
                          p_date_from   IN DATE,
                          p_date_to     IN DATE,
                          p_lines       IN t_request_lines,
                          p_request_id  OUT NUMBER);
```

One call, at the final step, inside one transaction: header, lines and any derived rows land together
or not at all. APEX commits on submit, the package does not (`back-end-conventions.md` §4), so a
`-20xxx` from the last validation leaves the database exactly as it was.

This stays on **one entity package** because the lines are a satellite of the header — `NOT NULL` FK
to it, nothing else writes them, meaningless without it (`package-boundaries.md` §Test 1). A wizard
whose final step also writes a second *independent* entity — reserving stock, moving a quota — puts
the entry point on a `_flow` package that coordinates both instead.

Per-step writes are the exception, and only with the draft-row model. Then each step gets its own
procedure (`save_step_1`, `add_line`), and each one must leave the row **valid for its own status** —
which is the real cost: the invariants stop being "a request is complete" and become "a request is
complete *for the step it has reached*". Write that down in the package header or the next person
will not know which columns are allowed to be null.

## The shell

```
page 62 (
    appearance { pageMode: modalDialog  dialogTemplate: @/wizard-modal-dialog }

    region progress   ( type: staticContent  layout { slot: REGION_POSITION_01 } )
    region step-dates ( type: staticContent  layout { slot: BODY }
        serverSideCondition { type: request=Value  value: STEP1 } )
    region step-detail ( type: staticContent  layout { slot: BODY }
        serverSideCondition { type: request=Value  value: STEP2 } )
    region buttons    ( type: staticContent  layout { slot: REGION_POSITION_03 } )

    process create-request (
        type: executeCode
        source { plsqlCode: ```plsql
            pkg_absences.create_request(
                p_employee_id => :P62_EMPLOYEE_ID,
                p_reason      => :P62_REASON,
                p_date_from   => :P62_DATE_FROM,
                p_date_to     => :P62_DATE_TO,
                p_request_id  => :P62_REQUEST_ID);``` }
        execution { sequence: 20 }
        serverSideCondition { type: requestIsContainedInValue  value: FINISH }
    )
)
```

One page, regions gated by `:REQUEST` — not one page per step. Page-per-step multiplies the session
plumbing (every item must be passed forward or re-fetched) and makes "go back" a navigation problem
instead of a request value.

Steps that only collect input need no process at all. The single write process is gated on the final
request, so no button but Finish can write.

## Validation across steps

- **Per step:** field shape on the items, plus page validations gated by
  `whenButtonPressed: @next` so step 2 is not validated while the user is on step 1.
- **At the end, in the package:** every rule that spans steps. This is not belt-and-braces, it is the
  only correct place — the user can walk back to step 1 and change the date that step 3 already
  validated against. The wizard's per-step validations are a UX courtesy; the package's check at
  commit is the truth.

## Going back must not write

The Back button sets `:REQUEST` to the previous step. Two things follow: the write process is gated
on `FINISH` alone, and no step's process may insert "so we don't lose it" — that is how a wizard ends
up creating three rows for one user who changed their mind twice. If something genuinely must persist
mid-flight, that is the draft-row model, and then it is an update of the same row, keyed by an id the
first step generated.

## Abandoned drafts need an owner

The moment a wizard writes drafts, it creates rows nobody will ever finish. Decide it when you build
it, not when the table has 40 000 orphans: a scheduled job calling
`pkg_x.purge_drafts(p_older_than => 30)` — a procedure **in the package**, like every other write,
which commits per batch and says so in its header. A wizard with a draft table and no purge is an
unfinished feature.

## Common mistakes

| Tempting | Why wrong |
|---|---|
| `apex_collection` as the staging area | Dies with the session, untyped, unconstrained, untestable outside a browser. Use a table your package owns. |
| Insert on step 1, update on each step | Three abandoned rows per indecisive user, and every consuming query now sees partial records. |
| One page per step | Session plumbing and navigation instead of one request value. |
| Validate only per step | The user can go back and invalidate a rule a later step already checked. Re-check at commit, in the package. |
| `create_row` called once per step | The wizard's outcome is one entity: one intent-named procedure, one transaction. |
| A draft status with no purge job | The table fills with rows nobody will finish and every report has to remember to exclude them. |

## Verify

Drive it: complete the happy path and confirm with SQLcl that **one** row (plus its lines) exists —
not two, not a partial. Then repeat, going back from the last step to change a value that a later
step validates, and assert the package rejects it at Finish with the friendly message. Abandon a third
run mid-way and confirm nothing was written (session-state model) or exactly one draft was written
(draft model). The abandoned-run check is the one that catches a step process that writes when it
should not.
