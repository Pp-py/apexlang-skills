# Recipe: item detail page (summary or tabbed full record)

**Use for:** the page a user lands on after picking a row — one record, everything about it: header
facts, properties, related collections, people, files, comments, activity. A work item, a request, a
contract, an asset.

**REQUIRED BACKGROUND:** `ui-contracts.md` (the data contract) and, because this page is not as
read-only as it looks, `back-end-conventions.md`.

Oracle's UX Pattern Catalog ships two shapes: *Item Detail – Summary* (everything stacked on one
scroll) and *Item Detail – Full* (a marquee header plus tabs and a right rail).

**Contents:** which shape · the data contract (one view per item) · header and key facts · tabs and
what they cost · the actions rail · the collections that write (comments, child records) · the
activity timeline is your audit trail · common mistakes · verify.

## Which shape

| Signal | Shape |
|---|---|
| Under ~15 facts, one or two collections, read-mostly | **summary** — `pageTemplate: @/standard`, regions stacked in `body` |
| Several collections the user switches between; a persistent actions rail | **full** — `pageTemplate: @/marquee`, tabs in `masterDetail`, rail in `rightSideColumn` |
| The user compares records rather than studying one | not this recipe — `split-view-selection.md` |

Start with the summary. The tabbed shape earns its complexity when collections (people, files,
comments, child records) genuinely compete for the same screen.

## The data contract: one view per item

Every region on this page describes the same row. Build **one `v_*` view keyed by the PK** that
projects what the header and the facts need — including the state token — and let the collections
bring their own queries:

```plsql
CREATE OR REPLACE VIEW v_work_item_detail AS
SELECT w.work_item_id, w.title, w.category, s.name sector_name, w.owner_name,
       w.status_code,
       CASE w.status_code WHEN 'BLOCKED'  THEN 'danger'
                          WHEN 'PENDING'  THEN 'warning'
                          WHEN 'DONE'     THEN 'success'
                          ELSE 'info' END AS status_state,
       w.due_date, w.updated_at
  FROM hr_work_items w JOIN hr_sectors s ON s.sector_id = w.sector_id;
```

The token is derived **once, here** — the same view feeds the badge in the header, the badge in the
list the user came from, and the state that decides which actions are legal (`ui-contracts.md` §2 and
§4). Two queries computing "which status is red" is a bug the UI cannot show you.

Every region binds `:P32_WORK_ITEM_ID` and lists it in `source.pageItemsToSubmit`, so the page
survives a refresh after an edit.

## Header and key facts

The header is a `staticContent` region in `breadcrumbBar`; the facts hang off it as a **Classic
Report with the contextual-info qualifier** — an official constraint, not a style choice — returning
exactly one row:

```
region item-header (
    type: staticContent
    layout { sequence: 20  slot: breadcrumbBar }
)

region key-facts (
    type: classicReport
    source { type: sqlQuery
        sqlQuery: ```sql
            select category, owner_name, status_code, status_state, due_date
              from v_work_item_detail where work_item_id = :P32_WORK_ITEM_ID```
        pageItemsToSubmit: P32_WORK_ITEM_ID }
    layout { parentRegion: @item-header  slot: searchFieldAndSmartFilters }
    appearance { template: @/blank-with-attributes-no-grid  cssClasses: app-ContextualInfo }
    componentAppearance { template: @/contextual-info
        templateOptions: [ #DEFAULT#  t-ContextualInfo--hideNulls  t-ContextualInfo-label--stacked ] }

    column STATUS_CODE (
        heading { heading: Status }
        columnFormatting { htmlExpression: ```html
            CLASS:=u-&STATUS_STATE.
            STYLE:=t-Badge--subtle
            SIZE:=t-Badge--sm
            {apply THEME$BADGE/}``` } )
    column STATUS_STATE ( type: hidden  heading { heading: Status state } )
)
```

`{apply THEME$BADGE/}` is the theme's badge macro: assign its parameters as `NAME:=value` lines and
apply it. The state token still comes from the view — the macro renders it, it does not decide it.

Facts belong here only if a user acts on them: owner, classification, status, impact, timing.
Everything else is a property row further down, not header chrome.

## Tabs, and what they cost

The tabbed shape is one `regionDisplaySelector` region plus `advanced.regionDisplaySelector: true` on
every region that should become a tab:

```
region item-detail-tabs (
    type: regionDisplaySelector
    layout { sequence: 60  slot: masterDetail }
)

region child-records (
    type: classicReport
    layout { sequence: 20  slot: body }
    advanced { regionDisplaySelector: true }
)
```

**The selector switches visibility, it does not defer queries.** Every tab's source runs on page
load, so a tab over an unbounded history is a page-load cost the user pays even when they never open
it. Cap those collections (`pagination`, a `where` on the last N), or move them to their own page and
link out. This is the one architectural decision the tabbed shape forces, and the catalog — with
synthetic `sys.dual` data — cannot show it.

A tab kept in the source but not yet in use belongs behind `config { buildOption: @<option> }` or a
`serverSideCondition`, not commented out.

## The actions rail

The right rail is a **List region** bound to a shared list — navigation only. The official contract
is explicit: list regions bind to shared list entries and must not emit data sources, filters,
columns, links or actions of their own.

```
region side-actions (
    type: list
    source { list: @item-actions }
    layout { sequence: 10  slot: rightSideColumn }
    componentAppearance { listTemplate: @/links-list
        templateOptions: [ #DEFAULT#  t-LinksList--showArrow  t-LinksList--actions ] }
)
```

Architecturally that keeps the rail honest: **it navigates, it never writes.** Each entry opens a
drawer or modal that routes through the package (`form-page-to-package.md`,
`workflow-state-transitions.md`). Two consequences worth wiring:

- Entries that only make sense in some states carry a condition on the state token — the same token
  the header badge uses, so the rail and the badge can never disagree.
- Destructive entries carry an `authorizationScheme`. A rule enforced only by hiding a link is not
  enforced: the package still refuses the transition.

## The collections that write

This page looks read-only and is not. Two regions mutate, and both go through a package like anything
else:

- **Comments** (`themeTemplateComponent/comments`, `settings.style: chatSpeechBubbles`) is an
  append-only child table. The "Add comment" button submits to an `executeCode` process calling
  `pkg_item_comments.add_comment(...)` — never an inline `INSERT`. The avatar is presentation derived
  in SQL (`apex_string.get_initials(username)`, and a deterministic colour class such as
  `'u-color-' || MOD(ORA_HASH(username), 10)`), which is exactly the derived-display-column rule
  (`ui-contracts.md` §4).
- **Child records** (`classicReport`) get their create/edit buttons in the **region's own toolbar**,
  not floating in the body grid, and the page refreshes them on `apexafterclosedialog` after the
  modal closes (`modal-crud-to-package.md`).

## The activity timeline is your audit trail

The timeline is a `contentRow` in report mode with `plugin-grouping` for the date headers, and its
`settings.overline` composes the actor and action with template directives:

```
componentAppearance { display: report  cssClasses: app-ActivityTimeline }
settings { overline: ```html
    {if ACTIONED_BY/}&ACTIONED_BY.{if ACTION_TYPE/} &middot; &ACTION_TYPE.{endif/}
    {elseif ACTION_TYPE/}&ACTION_TYPE.{endif/}``` }
plugin-grouping { title: <div class="u-text-uppercase u-text-muted-color">&ACTIVITY_GROUP.</div> }
```

The rendering is the easy half. The hard half is architectural: **those rows have to come from
somewhere.** The catalog fabricates them; a real page reads an event table that the write-path
packages populate as part of the same transaction that changed the row — one insert per meaningful
transition, written by the package, never by the page. If the packages do not write it, the timeline
is a decoration that quietly lies about what happened.

That event table is a **satellite** of the entity — `NOT NULL` FK to it, no other entity writes it,
meaningless without it — so the entity's own package owns it (`package-boundaries.md` §Test 1). It
needs no package of its own and no flow to coordinate it.

A union view over "comments + status changes + file uploads" is a legitimate shape for the read side;
what is not legitimate is deriving activity by diffing audit columns at render time.

## Common mistakes

| Tempting | Why wrong |
|---|---|
| A query per region, each re-joining the same tables | The header, facts and badge disagree the day one query changes. One view per item, bound by PK. |
| Status badge coloured by a `CASE` inside each region | The token belongs to the view; the region renders it (`ui-contracts.md` §2). |
| Editing fields inline on the detail page | This page shows a record. Edits leave to a drawer or modal so the write keeps one path. |
| Hiding an action to enforce a rule | Hiding is UX. The package must still refuse the transition. |
| A tab over the full history "because it is just a tab" | Every tab queries on page load. Cap it or move it out. |
| Writing a comment with an inline `INSERT` | A comment is a row in a table: `pkg_item_comments`, same as everything else. |

## Verify

Browser-side, before claiming it works: open the page with a PK and assert the header badge, the
contextual-info row and at least one collection rendered for **that** record (spot-check one value
against SQLcl — a detail bound to the wrong item renders plausible data from the wrong row). Switch
every tab and assert each shows content rather than an empty frame. Add a comment and assert the row
reaches the table and the region shows it after refresh. Then open an action from the rail, cancel it,
and assert nothing changed.
