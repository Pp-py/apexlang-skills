# Item details — `UXDET`

Recipes: `item-detail-page.md`, `split-view-selection.md`. Runtime companion: `apex-sentinel/checks/split-view.md`.

| ID | Criterion | Sev | By | Source |
|---|---|---|---|---|
| `UXDET-HEADER` | the header names the item and shows its status (as text) and its key attributes before any detail | ADVISE | static + manual | ex: CAT 26.1.6 item-detail-summary |
| `UXDET-BACK` | a standalone detail page has a way back to where the user came from, with an accessible name | ADVISE | static | ex: CAT 26.1.6 item-detail-summary |
| `UXDET-ACTION-HIERARCHY` | one primary action in the header; the rest in an Actions menu, destructive ones last and confirmed (`UX-DESTRUCTIVE-CONFIRM`) | ADVISE | static | Oracle buttons; ex: CAT 26.1.6 item-detail-full (its Delete has no confirmation: do not copy it) |
| `UXDET-NOTHING-SELECTED` | a selection page shows an empty state while nothing is selected ("No item selected — select an item to view its details") | ADVISE | static + runtime | repo `ui-contracts.md` §8; ex: CAT 26.1.6 item-selection, tree-selection |
| `UXDET-SELECTION-STATE` | the selected row is exposed to assistive technology (`aria-selected` or `aria-current`), not only highlighted, and the list is operable from the keyboard | ADVISE | runtime | WCAG 1.3.1, 2.1.1, 4.1.2 |
| `UXDET-SECTIONS` | related information is grouped in titled sections, each with a count or recency and a way to see all | ADVISE | static + manual | ex: CAT 26.1.6 item-detail-full, content-rows ("Section Overview") |
| `UXDET-READ-ONLY-RAIL` | a detail page's navigation rail only navigates; every write opens a form that goes through the package | ADVISE | static | repo `recipes/item-detail-page.md` |
