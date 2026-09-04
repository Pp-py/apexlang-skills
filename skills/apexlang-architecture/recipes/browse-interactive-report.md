# Recipe: browse list on an Interactive Report

**Use for:** the working list of an entity — the screen a user lives in: sort it, filter it, save a
view of it, act on a row. Work orders, invoices, employees, tickets.

Read-only: **no package here.** Row actions leave to a modal or drawer that writes
(`modal-crud-to-package.md`, `form-page-to-package.md`). Data-side rules: `ui-contracts.md`.

The declarative contract — region and column templates, required `heading` on every column,
`rowRangesXToY` pagination, column-link syntax, `LOWER()` on both sides of a page-item predicate — is
specified in the official `apex.interactive-report.md`. This recipe covers what it leaves open.

**Contents:** IR vs facets vs cards · the data contract (and why hiding a column is not security) ·
navigation by column link · buttons in the toolbar · shipping a saved report · filtering from page
items · common mistakes · verify.

## IR, or facets, or cards

| The user's verb | Region |
|---|---|
| Narrow by known attributes, then look | faceted search (`master-faceted-search.md`) |
| Recognise by image or short text | cards / content row (`ui-contracts.md` §1) |
| **Sort, filter ad hoc, save a view, export, act on rows** | **Interactive Report — this recipe** |
| Compare aggregates over periods | `analytical-report.md` |

The IR earns its weight when the *user* decides how to look at the data. If every user wants the same
three filters, facets are cheaper and read better; an IR shipped to answer one fixed question is a
Classic Report with a toolbar the user has to learn.

## The data contract

One row per entity, from a `v_*` view when the list joins or derives; inline SQL when it is
page-local. The view projects **values and tokens**, never markup (`ui-contracts.md` §2):

```sql
select w.work_item_id, w.title, s.name sector_name, w.owner_name,
       w.status_label,
       case w.status_code when 'BLOCKED' then 'danger'
                          when 'PENDING' then 'warning'
                          else 'success' end as status_state,
       w.due_date, w.amount
  from hr_work_items w join hr_sectors s on s.sector_id = w.sector_id
 where w.cancelled_at is null
```

Two consequences that are architecture, not styling:

- **The filter set the user sees is the projection.** An IR only filters and sorts what the query
  returns, so deciding the column list *is* deciding what the user can ask. Project the columns
  people filter by even when they are hidden by default.
- **Row-level security is not a hidden column.** An IR user can add any projected column back into
  their own saved report. If a row must not be seen, it must not be in the view — put the predicate
  in the view (or a VPD policy), never in the report's default layout.

## Navigation: the link is the column's

```
column WORK_ITEM_ID (
    type: plainText
    heading { heading: Edit }
    source { dataType: NUMBER }
    link {
        target { page: 41  items { P41_WORK_ITEM_ID: #WORK_ITEM_ID# }  clearCache: 41 }
        linkText: <span class="fa fa-pencil"></span>
    }
)
```

Row values in `target.items` use `#COLUMN#`; `&ITEM.` is for page, app and session substitutions.
A region-level `link {}` is rejected by the compiler (`REPORT_REGION_LINK_BLOCK_UNSUPPORTED_001`), and
`type: link` is Classic-Report-only — see `modal-crud-to-package.md`, which has the full note.

When the target is modal, the parent page carries the `apexafterclosedialog` dynamic action that
refreshes this region. Without it the user saves, the drawer closes, and the row still shows the old
value — the single most common "it didn't save" report that isn't a save failure at all.

## Buttons belong to the toolbar

Region-scoped actions — create a row of *this* list, edit the selected one — go in the report's
toolbar slot (`rightOfInteractiveReportSearchBar`), not floating in the body grid. A page-level
create, on a page with a breadcrumb/title bar, belongs in that bar. Same rule as the master-detail
workbench in `split-view-selection.md`, and it is what keeps a screen from growing three competing
"New" buttons.

## Ship a saved report, not a column dump

```
savedReport primary (
    visibility: primaryDefault
    name: Primary
    view { rowsPerPage: 50 }
    displayColumn ( column: @TITLE        layout { sequence: 10 } )
    displayColumn ( column: @SECTOR_NAME  layout { sequence: 20 } )
    displayColumn ( column: @STATUS_LABEL layout { sequence: 30 } )
)
```

The default view is a product decision: the columns a new user needs, in reading order, at a page
size that fits. Support columns (`STATUS_STATE`, `*_URL`) stay `type: hidden` — **with their
`heading` block, which the compiler requires even on hidden columns** — and out of `displayColumn`.
Users personalise on top of that default; they should not have to undo it first.

An actions column is the one place to also set `enableUsersTo { hide: false  sort: false
filter: false }`: a row-action column a user can hide or sort by is a support call.

## Filtering from page items

When the list is pre-filtered by page items (a sector picker, a date range), bind them and declare
them:

```
source { type: sqlQuery  sqlQuery: ```sql
    select ... from v_work_item_browse
     where (:P30_SECTOR is null or sector_id = :P30_SECTOR)```
    pageItemsToSubmit: P30_SECTOR }
```

Missing `pageItemsToSubmit` is the classic stale-list bug: the region renders once against whatever
session state held, and never changes. Normalise text predicates with `LOWER()` on **both** sides
(official rule), and let the IR's own search do free-text — a page item that duplicates the IR search
box is two search boxes disagreeing.

## Common mistakes

| Tempting | Why wrong |
|---|---|
| Hide a column to hide the data | The user can add it back in their own saved report. Filter in the view. |
| Build the status pill in the SQL | Rejected by the compiler; the token goes in the query, the markup in `columnFormatting.htmlExpression` (`analytical-report.md`). |
| A "New" button next to the region instead of in its toolbar | Three pages in, the screen has three competing New buttons in three places. |
| Skip `heading` on a hidden column | The compiler requires it on every IR column, hidden included. |
| Let the IR write (an editable IG "because it is a list") | Editing a list inline is a different archetype with a different write path: `editable-ig-to-package.md`. |

## Verify

`apex-sentinel/checks/browse-search.md`: rows render, a filter actually lowers the count, the row link
opens the right record without a checksum error, and after an edit in the modal the list shows the new
value.
