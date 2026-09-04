# UI contracts — what the data layer must project

`back-end-conventions.md` governs the **write** side: one package per table, rules inside it. This
file governs the **read** side: given a declarative UI pattern, *what must the SQL or view project,
and where does that derivation live?*

It is deliberately not a component reference. Region types, valid properties, templates and slots
belong to the official `apex` skill (`40-components/apex.region-contracts.md`,
`apex.region-media.md`, `apex.region-interactions.md`, `30-pages/apex.*.md`). Read it there once;
what follows is only the part no one else owns.

**Contents:** 1 cards vs content row · 2 state tokens, never CSS classes · 3 drill-down URLs as a
projected column · 4 where a derived column lives · 5 formatting and directives · 6 scoped custom
CSS · 7 contextual detail actions · 8 selection state on a split view · 9 deviating from an
official default.

## 1. Cards or Content Row

The official contract stops at "prefer `Cards` **or** `Content Row` for browse/list experiences"
(`apex.region-contracts.md`) — it does not separate them. Oracle's UX Pattern Catalog builds the same
catalogue of use cases twice, once per primitive (`p01100-content-rows`, `p01110-cards`), which is
the material for the split:

| Use case | Primitive | Why |
|---|---|---|
| Navigation / launcher grid | either | cards if each entry earns an icon tile; content row for a dense menu |
| Status list (item + state) | content row | vertical scanning of many rows; badge at `position: end` |
| Section overview / compact summary | content row | `style: compact` + `size: extraSmall` avatar fits more rows in the same height |
| Related information (counts) | content row | the payload is a number, not an image |
| Search results | either | cards when a thumbnail helps recognition; content row when the text is the signal |
| Decision & action list (approve/reject) | either | see the full-card trap below |
| Selectable master list | content row | it is the one with a documented selection contract (§7) |
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

## 2. State columns project a token, never a CSS class

For status and badge use cases the semantic states are `success`, `danger`, `warning` and `info`:
they carry colour *and* accessibility semantics, so they are states, not colour names. The rule:

```sql
-- the view/query projects the token
case when r.due_date < trunc(sysdate) then 'danger'
     when r.status = 'PENDING'        then 'warning'
     else 'success'
end as badge_state
```

```
iconAndBadge { badgeColumn: STATUS_LABEL  badgeCssClasses: u-&BADGE_STATE. }
```

The class is composed **in the attribute**; the SQL stays free of presentation. Projecting
`'u-success'` from the query (as `p01110-cards` does, while `p00210` does it right) puts theme
class names in the data layer, where a theme upgrade cannot find them.

Same rule, stronger: **never project HTML.** The live compiler rejects it
(`REPORT_SQL_HTML_LITERAL_FORBIDDEN_001`) and it is non-negotiable rule 1 of
`apex.report-column-rendering.md`.

For non-semantic classification (a rule type, a category color) project a short token too and
compose around it: `<span class="u-color-#RULE_COLOR#-text">`.

## 3. Drill-down URLs are a projected column

The official cards policy requires `action.behavior.target: &EDIT_LINK` with the URL built in the
SELECT list:

```sql
apex_page.get_url(p_page => 41, p_items => 'P41_EMPLOYEE_ID', p_values => e.employee_id) as edit_link
```

Architecturally that makes navigation **a derived column like any other** — same as the `LINK`
column a `metricCard` strip already needs (`recipes/dashboard-kpis-charts.md`). So it follows §4:
one page uses it, keep it inline; three pages link to the same detail screen, it belongs in the
view.

The catalog's `targetUrl: #` is demo scaffolding. It never ships.

Note the division of labour the official contract draws: `metricCard` and `chart` regions do not
own links or actions — drill-down hangs off a neighbouring card, report column, or button
(`apex.region-interactions.md`).

## 4. Where a derived display column lives

| Derivation | Home |
|---|---|
| Used by one region on one page | inline `source.sqlQuery` |
| Reused across pages, or joins/aggregates | `v_*` view (`back-end-conventions.md` §5) |
| State → token (§2) | **once**, next to the status the package writes |
| Drill-down URL (§3) | inline for a page-local link, view when shared |
| Initials, avatar colour, counts | wherever the row already comes from; never a second query per row |

The state-token derivation is the one that must not be duplicated: a workflow's legal states live in
the package (`recipes/workflow-state-transitions.md`), so their presentation mapping lives once in
the view that exposes them. Two pages disagreeing about which status is `danger` is a bug the UI
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

Numbers meant for scanning carry a thousands separator, and dates, percentages and durations keep
one format per region — a `formatMask` or `to_char()`, decided once for the region, not per row.

## 6. Custom CSS is scoped to the pattern

The official dashboard standard puts it flatly: "do not invent CSS classes". The honest reading is
that the theme owns appearance, and a page may still need a local geometry fix. When it does:

- one class on the region, named after the pattern (`app-MetricCards`), never after the tweak;
- every selector prefixed with it, so no other Universal Theme component is touched;
- a one-line comment saying what it fixes.

Anything larger than a geometry fix (a palette, a new component look) is not a CSS problem — pick a
different template or template option.

## 7. Contextual detail actions

A summary region — a chart, a compact list, a KPI strip — often needs one way through to the data
behind it. It goes in the region header's **`slot: edit`**, where it stays attached to the region
instead of competing with the content:

- a text link or text button when the detail path is a common follow-up;
- an icon button when it should be available but is not the point;
- nothing at all when the region is purely informational — a drill-down that leads nowhere useful is
  worse than no affordance.

One action per region, and it links to a page that answers the question the region raises. This is
also the escape hatch for `metricCard` and `chart` regions, which own no actions of their own (§3).

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
