# UI contracts — what the data layer must project

`back-end-conventions.md` governs the **write** side: one owner per table, rules inside it (and `package-boundaries.md` decides which package is that owner). This
file governs the **read** side: given a declarative UI pattern, *what must the SQL or view project,
and where does that derivation live?*

It is deliberately not a component reference. Region types, valid properties, templates and slots
belong to Oracle's APEXlang skills (`apexlang-inventory`, and the 26.1 policies `40-components/apex.region-contracts.md`,
`apex.region-media.md`, `apex.region-interactions.md`, `30-pages/apex.*.md`). Read it there once;
what follows is only the part no one else owns. How the page looks and whether it is usable —
placement, formatting, CSS, accessibility — is judged by `apex-ux` (`../apex-ux/criteria/`); this
file says what the data layer projects so that it can be.

**Contents:** 1 cards vs content row · 2 row-dependent styling from a closed set · 3 navigation is
a declarative target · 4 where a derived column lives · 5 formatting and directives · 6 custom CSS
(`apex-ux`) · 7 contextual detail actions (`apex-ux`) · 8 selection state on a split view · 9 deviating from an
official default · 10 item defaults in shared components.

## 1. Cards or Content Row

The official contract stops at "prefer `Cards` **or** `Content Row` for browse/list experiences"
(`apex.region-contracts.md`) — it does not separate them. Oracle's UX Pattern Catalog answers it
implicitly, by building the same catalogue of use cases twice: once under *Content Rows* and once
under *Cards*. That is the material for the split:

| Use case | Primitive | Why |
|---|---|---|
| Navigation / launcher grid | either | cards if each entry earns an icon tile; content row for a dense menu |
| Status list (item + state) | content row | vertical scanning of many rows; badge at `position: end` |
| Section overview / compact summary | content row | `style: compact` + `size: extraSmall` avatar fits more rows in the same height |
| Related information (counts) | content row | the payload is a number, not an image |
| Search results | either | cards when a thumbnail helps recognition; content row when the text is the signal |
| Decision & action list (approve/reject) | either | see the full-card trap below |
| Selectable master list | content row | it is the one with a documented selection contract (§8) |
| People / users | either | cards for a directory grid, content row for a sidebar roster |
| Product / media catalog | **cards** | media is the point: `media { source: urlColumn ... }` |
| Timeline / activity feed | **content row** | grouping (`plugin-grouping`) has no cards equivalent |
| Anything the user must filter, sort or export | **interactive report** | neither primitive gives the IR toolbar |

Two traps worth naming:

- **Full-card link vs buttons.** An `action` of `type: fullCard` swallows the row; when the row also
  carries decision buttons, gate the full-card action on the states where those buttons are absent
  (`serverSideCondition` on the state column). Do not ship both unconditionally.
- **KPI tiles are not cards.** Aggregate numbers belong to `themeTemplateComponent/metricCard`, not
  to a `cards` region — the official dashboard policy is explicit, and a KPI query that projects
  `metric_value`-shaped aliases into `cards` will be rejected in review.

## 2. Row-dependent styling comes from a closed set

A status, a threshold or a category changes how a row looks. The value that drives it is projected
by the data layer, and it always comes from a **closed set**, every member written as a literal: a
`CASE` with an explicit `ELSE`, or a column whose `CHECK` constraint proves the set. The component
maps that value as it is — it never builds a class out of pieces. Which set depends on who consumes
it:

| Consumer | Projected value | Mapped as |
|---|---|---|
| a template component's `state` — Badge `settings.state`, Metric Card `plugin-badge.state` | `success`, `warning`, `danger`, `info` | bare alias: `state: BADGE_STATE` |
| a Cards region's `card.cssClasses` (and `iconAndBadge.badgeCssClasses`) | `u-normal`, `u-hot`, `u-info`, `u-success`, `u-warning`, `u-danger`, or `NULL` | `&STATE_CSS.` |
| a report column's badge (`columnFormatting.htmlExpression`) | the same six classes | `<span class="t-Badge #STATE_CSS#">#STATUS#</span>` |

```sql
-- the view projects the state once, next to the status the package writes (§4)
case when r.due_date < trunc(sysdate) then 'u-danger'
     when r.status = 'PENDING'        then 'u-warning'
     else 'u-success'
end as state_css
```

```
card { primaryKeyColumn1: REQUEST_ID  cssClasses: &STATE_CSS. }
iconAndBadge { badgeColumn: STATUS_LABEL }
```

The six `u-*` classes are Oracle's allowlist for Cards (`apex.cards-page.md`: *project only
`u-normal`, `u-hot`, `u-info`, `u-success`, `u-warning`, `u-danger`, or `NULL`*). They are
Universal Theme's semantic states rather than colour names, and because every value is a literal,
both a review and a theme upgrade can find them with one grep. Project the status text as
well, next to the class: the UI shows both (`apex-ux` `UX-NO-COLOR-ONLY`).

Three things are out:

- **Composing a class.** `badgeCssClasses: u-&BADGE_STATE.`, `'u-color-' || MOD(...)`,
  `u-color-#RULE_COLOR#-text`: no single literal in the source says which classes can reach the
  page, so the set is unprovable. Oracle rules this out on Cards (*"Do not concatenate arbitrary
  CSS"*), and this skill applies the same rule to every component. This skill states the rule;
  `apex-ux`'s static scan checks it (`UX-NO-COMPOSED-CLASS`).
- **A raw class column.** A column holding whatever class someone typed into a table is user input
  reaching `class=""`.
- **Markup.** The query never projects HTML. Oracle's `apex.report-column-rendering.md` makes it
  non-negotiable rule 1 and the 26.1 lint rejects it (`REPORT_SQL_HTML_LITERAL_FORBIDDEN_001`).
  SQLcl's compiler does not (§Report rules in `SKILL.md`), so it is a rule to keep, not one the
  toolchain enforces.

A **non-semantic classification**, such as a rule type or a category, follows the same rule: a
`CASE` returns whole Universal Theme classes (`'u-color-11-text'`), and the column maps
`#RULE_CSS#`. An avatar colour is not a classification at all. Comments and avatars colour
themselves (`settings.applyThemeColors`), so leave it to the component.

## 3. Navigation is a declarative target

A link is a component property, not data: `behavior.target` (or a report column's `link.target`)
names the page, the items and the cache to clear, and APEX builds the URL, including its checksum.
The query projects only the **values** the target needs, which is almost always the row's key.

| Component | Shape | Row value |
|---|---|---|
| Cards | `action open ( type: fullCard  behavior { type: redirectThisApp  target: { page: 41  items: { P41_EMPLOYEE_ID: &EMPLOYEE_ID. }  clearCache: 41 } } )` | `&COL.` |
| Metric Card, Badge | `action open ( position: link  behavior { type: redirectThisApp  target: {…} } )` | `&COL.` |
| Classic / Interactive Report | `column EMPLOYEE_ID ( type: link  link { target: {…}  linkText: … } )` | `#COL#` |

Never project a URL for the UI: no `apex_page.get_url(...) as edit_link` mapped into a target,
and no `f?p=` string. Oracle's contract is *"use declarative `behavior.target` for redirects"*
(`apex.region-interactions.md`) and it rejects dynamic target substitutions on Cards
(`apex.cards-page.md`). A projected URL hides the destination from review and moves the checksum
into code you maintain. `apex_page.get_url` still belongs where no component exists to own the link:
an e-mail body, a notification payload, PL/SQL-rendered output.

If the destination differs from row to row, write one action per destination, each gated on the
state column with a `serverSideCondition`. Every destination is then declared and reviewable.

The catalog's `targetUrl: #` is demo scaffolding. It never ships.

`chart` regions own no links, and Oracle routes drill-down from a KPI or a chart *"through nearby
report/card links rather than chart or metric actions"* (`apex.region-contracts.md`). The narrow
exception is a Metric Card whose cards all open **one** page, each with its own key (`P10_STATUS:
&STATUS_CODE.`). It gets its `position: link` action. Cards that go to different pages get a
header action instead (`apex-ux` `UXDASH-DRILLDOWN`) — `recipes/dashboard-kpis-charts.md` has both.

## 4. Where a derived display column lives

| Derivation | Home |
|---|---|
| Used by one region on one page | inline `source.sqlQuery` |
| Reused across pages, or joins/aggregates | `v_*` view (`back-end-conventions.md` §5) |
| State → closed-set value (§2) | **once**, next to the status the package writes |
| A target's key values (§3) | wherever the row already comes from — usually the PK, already projected |
| Initials, counts | wherever the row already comes from; never a second query per row |

The state derivation is the one that must not be duplicated: a workflow's legal states live in
the package (`recipes/workflow-state-transitions.md`), so their presentation mapping lives once in
the view that exposes them. Two pages disagreeing about which status is `u-danger` is a bug the UI
cannot see.

Avoid a scalar subquery per row for badges and counts; aggregate in the view instead. Dashboards are
where this bites first ("avoid expensive per-card queries", `apex.dashboard.md`).

## 5. Formatting and directives belong to the component

Conditional markup, loops over a delimited column, escaping — all of it is a component attribute:
`columnFormatting.htmlExpression` on report columns, `advancedFormatting: true` + `htmlExpression`
on cards/content-row text blocks. The query projects values; the component decides how they look.

**The substitution trap:** report columns use `#COLUMN#`, cards `htmlExpression` uses `&COLUMN.`
(and `&COLUMN!HTML.` for text that could contain markup). Two official rules in two different files,
and the wrong one fails silently by rendering the literal token.

How numbers, dates and durations must read is `apex-ux`'s (`UX-FORMAT`, `UXDASH-KPI-CONTEXT`).

## 6. Custom CSS — `apex-ux`

Presentation, not a data contract: `UX-NO-INVENTED-CLASS` (one scoped pattern class) and
`UX-NO-INLINE-STYLE` in `../apex-ux/criteria/common.md`.

## 7. Contextual detail actions — `apex-ux`

Where a summary region's way through to its data sits, and in which form, is `UXDASH-DRILLDOWN`
and `UX-ACTION-PLACEMENT`. The link itself is a declarative target (§3).

## 8. Selection state on a split-view page

A list that drives detail regions on the same page needs a contract, and there are two:

- **Default — `fullRowLink`:** the row action sets a hidden context item, a dynamic action refreshes
  the dependent regions, and every dependent region lists that item in `source.pageItemsToSubmit`.
  No JavaScript. This is the official master-detail shape (`apex.region-interactions.md`).
- **Variant — component selection:** `rowSelection.type: singleSelection` with
  `currentSelectionPageItem` keeps a *visible* selected row, at the cost of two page items (the one
  the component maintains, and the canonical one the detail queries read) plus reconciliation after
  every filter or page change.

Either way the detail side is the same: regions marked with a shared class (`js-item-refresh`),
parameterised by the canonical item, with an empty-state region for "nothing selected".
`recipes/split-view-selection.md` has the full shape and the tree variant, which needs neither
contract (`settings.selectedNodePageItem` is the whole mechanism).

## 9. Deviating from an official default

The official page standards are prescriptive and allow exceptions only when they are *explicitly
documented* — for example, a faceted-search results region is a Classic Report by default, and
hiding a region header is listed as an anti-pattern, yet the catalog's own browse patterns use
`cards` and `contentRow` with the header hidden because the pattern puts the count and the active
facets in the title bar instead.

**The rule for this skill: a deviation is allowed when the reason is written in the region's
`comments` block.** Not in a commit message, not in a README — in the source, where the next reader
and the next review find it:

```
comments {
    comments: |
        Results are cards, not the default Classic Report: rows are recognised by
        image, and the row count lives in the title bar (totalRowCountSelector).
}
```

No reason in the source means take the default.

## 10. Item defaults belong to shared components

A `componentSetting` fixes an item type's behaviour once for the whole app, in
`shared-components/component-settings.apx`:

```
componentSetting (
    type: item
    name: switch
    settings { onValue: Y }
)

componentSetting (
    type: item
    name: checkbox
    settings { uncheckedValue: N }
)
```

This looks like a preference and is a **data contract**. The value a switch stores has to agree with
the `CHECK (active_flag IN ('Y','N'))` on the column and with every `WHERE active_flag = 'Y'` in the
app (`back-end-conventions.md` §6). Declared once, that agreement lives in one file and changes in
one place. Declared per item, it is restated on every page — and the fiftieth item is the one that
stores `'YES'`.

`uncheckedValue` deserves its own line, because an unchecked HTML checkbox posts **nothing**. That
setting is what makes "unchecked" mean `N` rather than null. Without it a `NOT NULL` column rejects
the row at runtime, and a nullable one quietly grows a third state the model does not have.

Override on the item only when that entity genuinely stores something else, and say why in its
`comments` (§9).

One hygiene note: enabling a component is a decision, not a default. Oracle's catalog ships settings
for `map`, `geocodedAddress` and REST sources that no page uses — dead configuration advertising
capabilities the app does not have. Keep the file to what the app actually uses.
