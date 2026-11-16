# Component catalog — which component for which need

A reports-and-forms app is what an agent builds when it knows only reports and forms. This file is
the whole repertoire — every region, template component and page item APEXlang declares — keyed by
the **need** it answers, so a booking gets a calendar and a product catalog gets pictures.

It decides *which*. It holds no grammar: the properties of each component are Oracle's
(`apexlang-inventory`, and for 26.1 the template family named in the last column, under
`apexlang-generation/templates/`). Where the write goes is `SKILL.md`; what the SQL projects is
`ui-contracts.md`; how the result is judged is `apex-ux`.

**Contents:** 1 by need · 2 regions · 3 template components · 4 page items · 5 not for new pages ·
6 what the status column means.

## 1. By need

Start here. The signal is in the data, not in the user's wording: a row with a date range is a
calendar candidate even when the request says "a list of bookings".

| The need | The data has | Component | Read |
|---|---|---|---|
| Book, schedule, plan: rooms, shifts, appointments, due dates | a start (and end) date per row | `calendar` | `recipes/calendar-scheduling.md` |
| A catalog people recognise by sight: products, properties, vehicles | an image per row | `cards` with `media` | `recipes/media-gallery-catalog.md` |
| Where things are: branches, deliveries, coverage areas | coordinates or a geometry per row | `map` | `recipes/map-locations.md` |
| Find rows by known attributes, then browse | categorical and range columns | `facetedSearch` over cards, content row, **calendar or map** | `recipes/master-faceted-search.md` |
| One box that searches several entities | text across tables | `search` | `recipes/master-faceted-search.md` §Search |
| A working list the user shapes: sort, save a view, export | many comparable columns | `interactiveReport` | `recipes/browse-interactive-report.md` |
| Edit many rows in one sitting | a flat table | `interactiveGrid` | `recipes/editable-ig-to-package.md` |
| A hierarchy: org chart, categories, bill of materials | a parent key | `tree` | `recipes/split-view-selection.md` |
| Numbers at a glance | one aggregate per tile | `themeTemplateComponent/metricCard` | `recipes/dashboard-kpis-charts.md` |
| Trend, comparison, composition | a measure by a dimension | `chart` | `recipes/dashboard-kpis-charts.md`, `recipes/analytical-report.md` |
| What happened to a record, and who said what | dated events, comments | content row grouped by date, `themeTemplateComponent/comments` | `recipes/item-detail-page.md` |
| A decision per row: approve, reject | a state column | content row or cards with actions | `recipes/workflow-state-transitions.md` |
| A value's history over time | validity dates | form + history report | `recipes/versioned-vigency-record.md` |
| A file on a record | a BLOB | `fileUpload` item | `recipes/attachments-to-package.md` |
| A photo the user takes or crops | a BLOB | `imageUpload` item | `recipes/media-gallery-catalog.md` §Upload |

Two archetypes on one page are normal (a faceted calendar, a map beside its report): read both recipes.

## 2. Regions

| `type:` | Use when | Not when → use | Status | Oracle 26.1 family |
|---|---|---|---|---|
| `calendar` | the row's meaning is *when* | rows have no date, or columns are compared → `interactiveReport` | recipe | `region-components/calendar` |
| `map` | the row's meaning is *where* | only a text address, no coordinates → a list; geocode first | recipe | `region-components/map` |
| `cards` | each record is a distinct, recognisable thing; media | many columns to compare → `interactiveReport`; dense scanning → content row | recipe | `region-components/cards` |
| `facetedSearch` | filters over known columns, shown beside the results | little room, few filters → `smartFilters` | recipe | `region-components/faceted-search` |
| `smartFilters` | the same filtering in one compact bar | many filters the user must see at once → `facetedSearch` | Oracle template | `region-components/smart-filter-search` |
| `search` | one box over several entities, ranked results | one entity → `facetedSearch` with a search facet | Oracle template | `region-components/search-config` |
| `interactiveReport` | the user shapes the list | fixed presentation → `classicReport`, cards, content row | recipe | `region-components/interactive-report` |
| `interactiveGrid` | several rows edited in one sitting | one row at a time → a form in a dialog | recipe | `region-components/interactive-grid` |
| `classicReport` | a fixed table, no user options | the user sorts or filters → `interactiveReport` | recipe | `region-components/classic-report` |
| `chart` | a trend, a comparison, a composition | a single number → `metricCard` | recipe | `region-components/chart` |
| `form` | one record created or edited | — | recipe | `region-components/form` |
| `tree` | a hierarchy that is navigated | one level → `list` or content row | recipe | — (inventory) |
| `list` | navigation: a menu, shortcuts, wizard steps | business rows → cards or content row | Oracle template | `region-components/list` |
| `staticContent` | a container, fixed text, an alert, a hero | — | recipe | `region-components/static-content` |
| `regionDisplaySelector` | tabs over the regions of one page | — | recipe | `region-components/region-display-selector` |
| `breadcrumb` | where the page is, and its title | — | recipe | `region-components/breadcrumb` |
| `helpText` | the page's help | — | Oracle template | `region-components/help-text` |
| `dynamicContent` | markup a template component cannot produce | almost always → a template component; the query never projects HTML (`ui-contracts.md` §2) | Oracle template | `region-components/dynamic-content` |
| `url` | another site's content embedded | — | inventory only | — |
| `workflowDiagram` | the state of an APEX Workflow instance | the state is a column of yours → a badge | inventory only | — |

## 3. Template components

All are `type: themeTemplateComponent/<name>`; family under `template-components/`.

| Name | Use when | Not when → use | Status |
|---|---|---|---|
| `metricCard` | a KPI tile | a list of records → cards | recipe |
| `contentRow` | compact rows: status lists, activity, decisions, a selectable master | media is the point → cards | recipe |
| `comments` | a conversation on a record | — | recipe (`item-detail-page.md`) |
| `badge` | a state or category next to a value | the state is the whole row → the row's `state` | recipe (`ui-contracts.md` §2) |
| `avatar` | a person or entity, by image or initials | — | Oracle template |
| `timeline` | events with a user, a date and a title | the events need date-group headers → content row with grouping (`item-detail-page.md`) | Oracle template |
| `mediaList` | a list or a 2-to-5-column grid of title + description with an avatar or icon | the image is a stored BLOB → cards (Oracle: *"do not infer BLOB contracts"*) | Oracle template |
| `actions` | a row's secondary actions as a menu | one action → a link or a button | Oracle template |
| `button` | a button rendered inside a report row | a page-level action → a page `button` | Oracle template |
| `flexboxContainer` | aligning sibling regions without custom CSS | — | Oracle template |

## 4. Page items

Family under `items/<name>` unless the status says otherwise.

| The input is | Item | Not when → use | Status |
|---|---|---|---|
| short text | `textField` | a closed list of values → `selectList` | Oracle template |
| long text | `textarea` | formatting → `markdownEditor` | inventory only |
| text with suggestions, free value allowed | `combobox`, `textFieldWithAutocomplete` | the value must exist in the list → `selectOne` | Oracle template · inventory only |
| one of a few, all visible | `radioGroup` | more than about seven → `selectList` | Oracle template |
| one of a short list | `selectList` | hundreds of rows → `popupLov` | Oracle template |
| one of a long list, searched | `selectOne` | the row needs several columns to be recognised → `popupLov` | Oracle template |
| several of a few | `checkboxGroup` | a long list → `selectMany` | inventory only |
| several of a long list | `selectMany` | the user must see what is left out, or order matters → `shuttle` | Oracle template |
| several, seeing available and chosen | `shuttle` | under about ten options → `checkboxGroup` | Oracle template |
| free values the user types | `listManager` | the values come from a table → `selectMany` | Oracle template |
| yes or no | `switch` | a third "not set" state → `radioGroup` | Oracle template |
| agreeing to one thing | `checkbox` | — | Oracle template |
| a date, a date and time | `datePicker` | choosing a slot among others → a `calendar` region | Oracle template |
| a number, an amount | `numberField` | — | Oracle template |
| a rating | `starRating` | the scale has words → `radioGroup` | Oracle template |
| a colour | `colorPicker` | it encodes a state → a state token (`ui-contracts.md` §2) | Oracle template |
| a password | `password` | — | inventory only |
| an image the user uploads or crops | `imageUpload` | any file → `fileUpload` | Oracle template |
| a file | `fileUpload` | — | recipe (`attachments-to-package.md`) |
| formatted text, stored as Markdown | `markdownEditor` | — | Oracle template |
| formatted text, stored as HTML | `richTextEditor` | prefer Markdown: stored HTML must be sanitised on the way out | Oracle template |
| an address checked against a geocoder | `geocodedAddress` | no geocoding service is configured | inventory only |
| *shown, not entered:* a value | `displayOnly` | — | Oracle template |
| a stored image | `displayImage` | several images → cards with `media` | inventory only |
| progress as a percentage | `percentGraph` | — | inventory only |
| one point on a map | `displayMap` | several points → a `map` region | inventory only |
| a QR code of a value | `qrCode` | — | inventory only |
| a key or version token the page carries | `hidden` | — | inventory only |

## 5. Not for new pages

The inventory's `type` enum still lists `classicTree`, `legacyCalendar`, `tabform`, `listView`,
`reflowReport`, `columnToggleReport`, `simpleChart`, `svgChart` and `plSqlDynamicContent`. They
exist so old applications export; a new page uses the current region above.

## 6. Status

| Status | Means |
|---|---|
| recipe | a recipe in this repo says where its logic lives and what its SQL projects |
| Oracle template | Oracle's 26.1 generation skill has a family for it; this repo adds no rule and has not built one |
| inventory only | the component type is declared in `apexlang-inventory` and nothing more: 26.1 has no template, and the inventory lists no property specific to it. Take its properties from an export of a page that uses it. |

No row here is evidence that a component compiles or runs on a given version — that is
`framework/CAPABILITIES.md`. The "use when" column is this repo's judgement, informed by Oracle's
sample applications for APEX 26.2 (Calendar, Cards, Maps, Application Search, Faceted Search
Patterns): of their page items, twenty of the thirty types appear at least once, and ten never do
— `starRating`, `shuttle`, `combobox`, `colorPicker`, `imageUpload`, `listManager`,
`markdownEditor`, `qrCode`, `displayMap`, `textFieldWithAutocomplete`. A component no one has
shown you working is one to try on a page before promising it.
