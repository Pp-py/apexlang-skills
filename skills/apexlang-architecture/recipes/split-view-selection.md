# Recipe: split view — master list (or tree) + detail panes

**Use for:** one screen where the user picks a record on the left and reads it on the right, without
navigating: an employee browser, a request inbox, an equipment register. The detail is several
regions (facts, attributes, KPIs, activity), all following the selected row.

Read-only page: **no write-path package here.** Edits leave to a drawer or modal
(`form-page-to-package.md`, `modal-crud-to-package.md`) and the page refreshes when it closes.
Read the data-side rules in `ui-contracts.md` §8 first.

Oracle's UX Pattern Catalog ships both variants, as *Item Selection* (list + faceted search) and
*Tree Selection*.

**Contents:** shape · `.apx` selection sets a hidden item (`fullRowLink`) · `.apx` the detail side ·
tree variant (`selectedNodePageItem`, no JS) · variant with visible row selection · non-obvious
points · verify.

## Shape

1. Page template: `@/standard` for a plain master-detail workbench; `@/left-side-column` **only**
   when the left column really holds a filter sidebar (faceted search or a search field). The
   official contract reserves the side-column template for filter pages — a master-detail page that
   borrows it without filters is a review finding.
2. Master region in the left column (or the first body columns): a `contentRow` in report mode, or a
   `tree`.
3. A hidden context item — `P33_EMPLOYEE_ID` — holding the selected PK. Nothing else is the source
   of truth.
4. Detail regions, each carrying a shared class (`js-item-refresh`), each parameterised by the
   context item and each listing it in `source.pageItemsToSubmit`.
5. One dynamic action: context item changed → refresh everything with that class.
6. An empty-state region for "nothing selected".

## `.apx` — selection sets a hidden item

```
region employees (
    type: themeTemplateComponent/contentRow
    source { type: sqlQuery  sqlQuery: ```sql
        select employee_id, full_name, sector_name, badge_state, status_label
          from v_employee_browse
         order by full_name``` }
    layout { slot: leftColumn }
    appearance { template: @/standard }
    componentAppearance { display: report }
    settings { title: &FULL_NAME.  overline: &SECTOR_NAME.  displayBadge: true }
    plugin-badge { value: STATUS_LABEL  state: BADGE_STATE  position: end }

    column EMPLOYEE_ID ( source { databaseColumn: EMPLOYEE_ID  primaryKey: true } )

    action select-row (
        position: fullRowLink
        layout { sequence: 10 }
        behavior { target: { page: 33  items: { P33_EMPLOYEE_ID: &EMPLOYEE_ID. } } }
    )
)

pageItem P33_EMPLOYEE_ID ( type: hidden  layout { region: @employees } )

dynamicAction employee-changed (
    execution { sequence: 10 }
    when { event: change  selectionType: item  items: P33_EMPLOYEE_ID }
    action refresh-detail (
        action: refresh
        affectedElements { selectionType: javaScriptExpression  javaScriptExpression: $(".js-item-refresh") }
        execution { sequence: 10  eventScope: dynamic }
    )
)
```

`fullRowLink` writing a hidden item is the official master-detail selection shape: the action targets
**its own page**, passing the row PK into the context item, and it carries no `template` (that is
reserved for `primaryActions` menus). Two things it is **not**: a `redirectUrl` / `f?p=` reload of
the same page (that throws away the rest of the page state), and a visible select list standing in
for the list itself.

## `.apx` — the detail side

```
region key-facts (
    type: classicReport
    source { type: sqlQuery
        sqlQuery: ```sql
            select status_label, badge_state, sector_name, hired_on
              from v_employee_browse where employee_id = :P33_EMPLOYEE_ID```
        pageItemsToSubmit: P33_EMPLOYEE_ID }
    appearance { template: @/contextual-info }
    advanced { cssClasses: js-item-refresh }
)

region no-selection (
    type: staticContent
    appearance { template: @/alert
        templateOptions: [ t-Alert--wizard t-Alert--info t-Alert--removeHeading ] }
    advanced { cssClasses: [ js-selected-item-empty u-hidden u-tC ] }
)
```

Every detail region repeats the same three things: the bind, `pageItemsToSubmit`, and the refresh
class. A region that forgets `pageItemsToSubmit` renders once with a stale session value and then
never changes — the failure looks like "the first row is sticky".

Contextual-info headers are Classic Reports with the contextual-info qualifier returning one
effective row; that is an official constraint, not a stylistic choice. Badges come from the view's
state token (`ui-contracts.md` §2), so the detail and the list cannot disagree about colour.

## Tree variant — the easy one

A `tree` region carries `settings.selectedNodePageItem`, so the selection contract is one property:
no paired items, no JavaScript. Prefer it whenever the data has a natural hierarchy (sector →
employee, warehouse → shelf) or a useful grouping.

```
region employee-tree (
    type: tree
    source { type: sqlQuery  sqlQuery: ```sql
        select -s.sector_id  as node_id, null as parent_id, s.name as node_label,
               null as node_value
          from hr_sectors s where s.active_flag = 'Y'
        union all
        select e.employee_id, -e.sector_id, e.full_name, e.employee_id
          from hr_employees e where e.active_flag = 'Y'``` }
    settings {
        nodeIdColumn: NODE_ID  parentKeyColumn: PARENT_ID
        nodeLabelColumn: NODE_LABEL  nodeValueColumn: NODE_VALUE
        selectedNodePageItem: P24_EMPLOYEE_ID
        orderSiblingsBy: NODE_LABEL
    }
)
```

Grouping nodes get **negative** ids so they can never collide with a real PK, and they project a
null `node_value` so selecting a group selects nothing. A search field over the tree is a
`textField` with `subtype: search` plus a dynamic action on `keyup` with
`execution { type: debounce  time: 200 }` refreshing the region — debounce it or every keystroke is
a query.

## Variant — visible row selection

`fullRowLink` moves the detail but does not leave the chosen row highlighted. When persistent
selection matters (long lists, keyboard navigation, "where was I"), the catalog's contract applies:
`rowSelection.type: singleSelection` with `currentSelectionPageItem`, plus **two** items — the one
the component maintains (`..._ID_UI`) and the canonical one the detail queries read (`..._ID`) —
copied one into the other by a dynamic action that fires only on real change, so they cannot loop.

The cost is reconciliation: after a facet changes or the list pages, the component's selection may
point at a row that is no longer there. Oracle's catalog solves it with a static file
(`js/split-view-selection.js`: reselect the same row silently if it survived the filter, otherwise
select the first row and notify). That file is Oracle sample code, which this skill does not
redistribute — copy it from the catalog app if you have it, or write those twenty lines against the
contract just described. The tree variant above needs none of it.

## Non-obvious points

- **Editing lives elsewhere.** A pencil on the detail opens a drawer; on close,
  `apexafterclosedialog` refreshes the `.js-item-refresh` regions *and* the master list, because the
  row's badge may have changed.
- **Child action buttons belong to the child region's toolbar**, not free-floating in the body grid;
  page-level "Create" belongs in the breadcrumb/title-bar region.
- **Strip debug output.** The catalog's reconcile action still ships a `console.warn` counting rows.
  A pattern that lands in production carries no console logging.
- **One query per detail region, from a view.** Do not fan out five scalar subqueries per region;
  `v_employee_browse` projects what the whole page needs (`ui-contracts.md` §4).

## Verify

`apex-sentinel/checks/split-view.md`: first row selected on load, detail follows a second selection,
detail survives filtering and paging, empty state when the filter matches nothing.
