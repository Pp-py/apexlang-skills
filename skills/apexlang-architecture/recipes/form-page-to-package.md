# Recipe: full-page / drawer form → write-path package

**Use for:** one entity edited on its own screen — many fields, grouped in sections, reached by
deep link (full page) or opened beside the list it came from (drawer). Employee enrollment, a
purchase request header, a contract.

**REQUIRED BACKGROUND:** `back-end-conventions.md` (single write-path, error catalog, no COMMIT).

Oracle's UX Pattern Catalog demonstrates both containers, as *Data Entry – Simple Form* and
*Data Entry – Drawer Form* — but its forms read from `source.location: sampleData` and
**never persist**: the drawer's "Apply Changes" only closes the dialog. The layout is the catalog's; the write path below is the part it
does not have.

**Contents:** shape · why no `form` region (and the documented deviation) · `.apx` container,
sections and items · `.apx` the write · drawer variant and its close contract · item↔column
mapping traps · which form archetype to pick · verify.

## Shape

1. A container region (`type: staticContent`) holding one child region per section
   (`template: @/content-block`), so the field groups are declarative, not `<h3>` markup.
2. Plain page items laid out into the section regions — no form-region column mapping; the PK item
   is `hidden` with `sessionStateProtection: checksumRequiredSessionLevel`.
3. A `load-*` process at `beforeHeader` — inline SQL read, PK-gated.
4. One process per intent at `afterSubmit`, each gated by `:REQUEST`, each calling the package.
5. Buttons in a `@/buttons-container` region: CREATE (PK null), APPLY CHANGES / DELETE (PK not null).

## Why no `form` region

The official standard binds a `type: form` region to exactly one `formAutoRowProcessing` — Automatic
Row DML — and, unlike the Interactive Grid standard, it carries **no "dedicated API" carve-out**
(`apex.form.md:135`; compare `apex.interactive-grid-page.md:49`). A plain item container has no form
region, so there is no form contract to break: the items are ordinary page items and the write is an
ordinary process. This is the same shape `modal-crud-to-package.md` already uses, which keeps all
three form-shaped recipes consistent.

*Documented deviation, when the entity has 20+ columns and the declarative column mapping earns its
keep:* use `type: form` with `formInitialization` for the read, replace the ARP with the
`executeCode` process below, and say so in the region's `comments` — citing `apex.form.md:166`
("keep form SQL minimal and offload logic to views or packages when possible"). Everything else in
this recipe is unchanged.

## `.apx` — container, sections, items

```
page 41 (
    appearance { pageTemplate: @/standard }
    security { pageAccessProtection: argumentsMustHaveChecksum }

    region form-employee ( type: staticContent )

    region basic-data (
        type: staticContent
        layout { parentRegion: @form-employee  slot: regionBody }
        appearance { template: @/content-block  templateOptions: t-ContentBlock--h2 }
    )

    pageItem P41_EMPLOYEE_ID (
        type: hidden
        layout { region: @basic-data }
        security { sessionStateProtection: checksumRequiredSessionLevel } )

    pageItem P41_ROW_VERSION (
        type: hidden                    -- lost-update guard, back-end-conventions.md section 7
        layout { region: @basic-data }
        security { sessionStateProtection: checksumRequiredSessionLevel } )

    pageItem P41_FULL_NAME (
        type: textField
        label { label: Full name }
        appearance { template: @/required-floating }
        validation { valueRequired: true  maxLength: 120 }
        layout { region: @basic-data  slot: regionBody }
        help { inlineHelpText: Legal name as on the ID document. } )

    pageItem P41_SECTOR_ID (
        type: selectList
        label { label: Sector }
        appearance { template: @/required-floating }
        lov { type: sqlQuery  sqlQuery: ```sql
            select name d, sector_id r from hr_sectors
             where active_flag = 'Y' order by name``` }
        layout { region: @basic-data } )
)
```

**No `source {}` on these items.** `source { formRegion: @form  column: ... }` only exists for items
bound to a form region; here the `load` process below fills them and the `save` process reads them.
The trade is explicit: you write two short processes instead of inheriting a column mapping.

Foreign keys are select lists over dynamic SQL — filtered by `active_flag = 'Y'`, so an inactive
sector cannot be picked for a new row even though history keeps it. Help text on editable items is
an official default, not a nicety: keep `inlineHelpText` under ~60 characters and put the "why it
matters" in `helpText`.

## `.apx` — the write

Each button names its intent; each process is gated on that name. Same discipline as
`workflow-state-transitions.md`, so a page never guesses what the user asked for.

```
button create (
    buttonName: CREATE
    label: Create
    layout { region: @form-buttons  slot: NEXT }
    appearance { buttonTemplate: @/text  hot: true }
    behavior { warnOnUnsavedChanges: doNotCheck }
    serverSideCondition { type: itemIsNull  item: P41_EMPLOYEE_ID } )

button apply (
    buttonName: APPLY-CHANGES
    label: Apply changes
    layout { region: @form-buttons  slot: NEXT }
    appearance { buttonTemplate: @/text  hot: true }
    behavior { warnOnUnsavedChanges: doNotCheck }
    serverSideCondition { type: itemIsNotNull  item: P41_EMPLOYEE_ID } )

process load-employee (
    type: executeCode
    source { plsqlCode: ```plsql
        if :P41_EMPLOYEE_ID is not null then
          select full_name, sector_id, email, row_version
            into :P41_FULL_NAME, :P41_SECTOR_ID, :P41_EMAIL, :P41_ROW_VERSION
            from hr_employees
           where employee_id = :P41_EMPLOYEE_ID;
        end if;``` }
    execution { point: beforeHeader }
)

process create-employee (
    type: executeCode
    source { plsqlCode: ```plsql
        pkg_employees.create_row(
            p_full_name => :P41_FULL_NAME,
            p_sector_id => :P41_SECTOR_ID,
            p_email     => :P41_EMAIL);``` }
    execution { point: afterSubmit }
    serverSideCondition { type: requestIsContainedInValue  value: CREATE }
)

process update-employee (
    type: executeCode
    source { plsqlCode: ```plsql
        pkg_employees.update_row(
            p_employee_id => :P41_EMPLOYEE_ID,
            p_full_name   => :P41_FULL_NAME,
            p_sector_id   => :P41_SECTOR_ID,
            p_email       => :P41_EMAIL,
            p_row_version => :P41_ROW_VERSION);``` }
    execution { point: afterSubmit }
    serverSideCondition { type: requestIsContainedInValue  value: APPLY-CHANGES }
)
```

`DELETE` follows the same shape — official button contract (`requiresConfirmation: true` plus a
`confirmation {}` block, shown only when the PK is present), process gated on `DELETE`, calling
`pkg_employees.delete_row`, which for a catalog-style table *inactivates* rather than deletes
(`back-end-conventions.md` §6) and refuses while the row is still referenced.

## Drawer variant

Same regions, same processes. Only the container changes:

```
appearance {
    pageMode: modalDialog
    dialogTemplate: @/drawer
    templateOptions: [ #DEFAULT#  js-dialog-class-t-Drawer--pullOutEnd ]
}
region form-buttons ( type: staticContent
    layout { slot: dialogFooter }
    appearance { template: @/buttons-container  templateOptions: t-ButtonRegion--noUI } )
```

**Close it with a process, not with a trigger action.** The catalog wires "Apply Changes" to
`behavior.action: triggerAction` → `triggerAction closeDialog`, which closes the drawer on click —
fine for a form that writes nothing, wrong here: a `-20xxx` from the package would tear down the
drawer and the friendly message with it. Use the modal recipe's contract instead:

```
process close-drawer (
    type: closeDialog
    execution { sequence: 90 }
    serverSideCondition { type: requestIsContainedInValue  value: CREATE,APPLY-CHANGES,DELETE }
)
```

Last submit-time sequence, `:REQUEST`-gated: business error → submit halts → the drawer stays open
showing the message. Cancel keeps the `triggerAction cancelDialog` (nothing to protect), and the
calling page refreshes its list on `apexafterclosedialog` — see `modal-crud-to-package.md`.

The official default for a single-row create/edit launched from a report is the **end/right drawer**;
a centred modal needs an explicit reason.

## Non-obvious points

- **Map items to columns 1:1.** The catalog's sample-data forms reuse one column across several
  items (`datePicker` bound to a `varchar2` column, two `subtype: phone` items on the same column) —
  harmless in a demo, a data corruption in a real table. Re-map every item against the real column,
  and keep `dataType` lowercase.
- **Field shape in the item, rules in the package.** `valueRequired` / `maxLength` on the item;
  uniqueness, "email already used", cross-field dates in `pkg_employees` raising `-20xxx`. A
  page-level validation gated by `whenButtonPressed` is acceptable as a UX pre-check only.
- **Sections are regions.** Nesting `@/content-block` children under the container keeps grouping
  declarative; hand-written headings inside a `staticContent` body do not survive a theme change.
- **Buttons region.** Keep `@/buttons-container` (page body for the full page, `dialogFooter` for the
  drawer) and leave spacing to the template — no custom classes.

## Which form archetype

| Signal | Recipe |
|---|---|
| Flat catalog, several rows edited in one sitting | `editable-ig-to-package.md` |
| One row at a time, few fields, opened from a master list | `modal-crud-to-package.md` |
| Many fields, sections, deep-linkable, its own URL | this recipe, full page |
| Edit without losing the list behind it | this recipe, drawer variant |
| Parent plus its child collection in one screen | `master-detail-edit.md` |

## Verify

`apex validate`, then drive it: `apex-sentinel/checks/form-page.md` asserts create, edit, the row
actually landing in the table (SQLcl, not the success message), and the rejection path leaving the
drawer open.
