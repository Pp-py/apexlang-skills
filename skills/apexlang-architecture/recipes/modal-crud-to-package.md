# Recipe: master list + create/edit modal → write-path package

**Use for:** entities edited one at a time through a modal form (richer than inline IG): employee enrollment, an absence request, a new rate vigency.

**REQUIRED BACKGROUND:** `back-end-conventions.md`.

## Shape

1. A **master** page: an `interactiveReport` over a view/SQL, with a link column opening the modal and passing the PK.
2. A **modal** page (`pageMode: modalDialog`): form items + page-level validations + a single `afterSubmit` process that calls the package.
3. The package exposes intent-named procedures (`create_row`, `update_row`, `approve`, `new_vigency`) — **not** raw DML.

## Master → modal link

```
region sectors-ir (
    type: interactiveReport
    source { sqlQuery: ```sql select sector_id, code, name, active_flag from hr_sectors order by code``` }
    link {
        linkColumn: customTarget
        target { page: 81  items { P81_SECTOR_ID: #SECTOR_ID# }  clearCache: 81 }
        linkIcon: <span class="fa fa-pencil"></span>
    }
)
```

## Modal page

The `staticContent` region is the container; items live in its `regionBody` slot. The `load-sector` process pre-fetches on edit (PK present) at `beforeHeader` — an inline SQL read is fine there. The `save-sector` process is the write: it calls the package, never `INSERT`/`UPDATE` here. `close-dialog` closes on success ONLY — last submit-time sequence, gated by `:REQUEST`; if the package raises a `-20xxx` error the submit halts, it never runs, and the modal stays open showing the friendly error.

```
page 81 (
    appearance { pageMode: modalDialog  dialogTemplate: @/modal-dialog }

    region form-sector ( type: staticContent )

    pageItem P81_SECTOR_ID ( type: hidden )
    pageItem P81_CODE ( type: textField  label { label: Code }
        layout { region: @form-sector  slot: regionBody } )
    pageItem P81_NAME ( type: textField  label { label: Name } )

    button save   ( buttonName: SAVE  layout { region: @form-sector  slot: create }
        behavior { warnOnUnsavedChanges: doNotCheck } )
    button cancel ( buttonName: CANCEL  behavior { action: definedByDynamicAction } )

    dynamicAction cancel-modal (
        execution { sequence: 10 }
        when { event: click  selectionType: button  button: @cancel }
        action close ( action: cancelDialog  execution { sequence: 10 } )
    )

    process load-sector (
        type: executeCode
        source { plsqlCode: ```plsql
            if :P81_SECTOR_ID is not null then
              select code, name into :P81_CODE, :P81_NAME
                from hr_sectors where sector_id = :P81_SECTOR_ID;
            end if;``` }
        execution { point: beforeHeader }
    )

    process save-sector (
        type: executeCode
        source { plsqlCode: ```plsql
            if :P81_SECTOR_ID is null then
              pkg_sectors.create_row(:P81_CODE, :P81_NAME);
            else
              pkg_sectors.update_row(:P81_SECTOR_ID, :P81_CODE, :P81_NAME, 'Y');
            end if;``` }
        execution { point: afterSubmit }
    )

    process close-dialog (
        type: closeDialog
        execution { sequence: 90 }
        serverSideCondition { type: expression  plsqlExpression: :REQUEST = 'SAVE' }
    )
)
```

Note `selectionType` is required in the dynamic action's `when` block.

## Close & refresh — the master must see the change

The save is not done until the modal closes **and** the master shows the new value
(`apex-sentinel/checks/modal-crud.md` asserts exactly these two behaviors, plus the
rejection path). Two halves:

- **Modal side:** the `close-dialog` process above. Sequence it after every other
  submit-time process; the `:REQUEST` gate keeps a business error from closing the
  dialog silently.
- **Master side:** a dynamic action on the master page refreshes the report when the
  dialog closes:

```
dynamicAction refresh-sectors (
    execution { sequence: 10 }
    when { event: apexafterclosedialog  selectionType: region  region: @sectors-ir }
    action refresh-ir (
        action: refresh
        affectedElements { selectionType: region  region: @sectors-ir }
        execution { sequence: 10 }
    )
)
```

`apexafterclosedialog` fires on the `closeDialog` path; a cancel (`cancelDialog` DA)
fires `apexafterclosecanceldialog` instead, so cancelling doesn't refresh. Don't invent
event aliases like `dialogClosed` — they are invalid for `when.event`.

## Validation placement

- **Field-shape** (required, maxLength): declarative item attributes.
- **Business rules** (uniqueness, "date must be later", "not duplicated"): in the package (`back-end-conventions.md` §2). A page-level `noRowsReturned`/`plsqlExpression` validation gated by `whenButtonPressed: @save` is acceptable for a *UX pre-check*, but the rule is still enforced in the package as the source of truth.

## Why modal over IG here

Choose the modal when the entity has many fields, multi-step input, or per-record workflow (approve/reject). Choose the editable IG (other recipe) for flat catalogs edited in bulk. Both route writes through the same package.
