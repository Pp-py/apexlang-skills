# UX criteria — format, severity, archetypes

Every UI judgement this skill makes is one of the criteria in this directory, by ID. A finding
without an ID is an opinion.

## Format

Each file holds one table; `tests/contract/surface.py` checks every row.

| Column | Meaning |
|---|---|
| **ID** | `<PREFIX>-<SLUG>`, unique across the catalog, prefixed by its file (below). Never reused once published. |
| **Criterion** | what must hold, stated so it can be checked |
| **Sev** | `FAIL` — the UI gate fails when it does not hold · `ADVISE` — reported, never changes the verdict |
| **By** | `static` — read from the `.apx` · `runtime` — observed in the browser · `manual` — a person (or agent) looks and says what they looked at. Several are joined with `+`. |
| **Source** | `WCAG <SC>` (2.2) · `Oracle <policy>` (26.1, anchors in `tests/upstream/citations.md`) · `UT` (Universal Theme) · `repo <file>` · `ex: CAT 26.1.6 <page>` (the UX Pattern Catalog, an example only) |

## Severity policy

`FAIL` is reserved for what a machine can establish without taste, and only these kinds:

- an axe-core violation of impact *serious* or *critical* on a WCAG A/AA rule;
- an item, button or link with no accessible name;
- a destructive action with no confirmation;
- an inline style or colour, or a composed class, in the `.apx`;
- a dialog that traps or loses keyboard focus.

Everything else is `ADVISE`: pattern fidelity, density, wording, secondary empty states, and every
Oracle "MUST" that is a generation convention rather than a user-facing defect. A `FAIL` criterion
is never `manual`. Changing a severity is a catalog change, for every page — never a per-page
exception. Oracle's 26.1 lint stays advisory and never becomes a UI verdict
(`framework/GATES.md`).

## Archetypes

| File | Prefix | Covers (`apexlang-architecture/recipes/`) | Catalog section (example) |
|---|---|---|---|
| [common.md](common.md) | `UX` | every page | Reference, Component Primitives |
| [dashboards.md](dashboards.md) | `UXDASH` | `dashboard-kpis-charts` | Dashboards, Metrics, Charts |
| [browse-search.md](browse-search.md) | `UXBRW` | `browse-interactive-report`, `master-faceted-search`, `analytical-report` | Browse and Search |
| [item-details.md](item-details.md) | `UXDET` | `item-detail-page`, `split-view-selection` | Item Details |
| [data-entry.md](data-entry.md) | `UXENT` | `form-page-to-package`, `modal-crud-to-package`, `editable-ig-to-package`, `master-detail-edit`, `wizard-multi-step`, `versioned-vigency-record` | Data Entry |
| [workflow.md](workflow.md) | `UXWF` | `workflow-state-transitions` | Content Rows — Decision and Action List |

A page takes `common.md` plus its archetype. A page that is two archetypes (a detail page with an
embedded form) takes both.

## What the catalog does not cover

Oracle's 26.1 policies are silent on several things WCAG requires: dialog focus management,
descriptive link text, target size, reflow, chart text alternatives, error identification. Those
criteria cite WCAG alone. The example catalog leaves its Status and Badges, Buttons and Menus,
Form Controls, Empty States and Navigation primitives, and its Sectioned Form, Wizard and Bulk
Edit patterns, as one-line descriptions (26.1.6): only those lines are cited.
