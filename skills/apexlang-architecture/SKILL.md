---
name: apexlang-architecture
description: Use when deciding WHERE business logic, validation, or DML belongs in an Oracle APEX app written as APEXlang (.apx) — routing every write through a PL/SQL package instead of region-bound Automatic DML and deciding which package owns it (one entity, a multi-entity flow, an external system) or whether the rule belongs in a database constraint, the UI, or no package at all, and architecting screens that write (editable Interactive Grids, modal CRUD, full-page and drawer forms, master-detail, workflows, versioned/vigency records) or read (dashboards, faceted search, split-view browsers, analytical reports), including what the SQL/view must project to feed cards, content rows, badges and drill-down links. NOT for .apx grammar/validate/import/round-trip (use the official `apex` skill) or one-off read-only pages with no reuse.
---

# APEXlang Architecture

## Overview

APEXlang turns an APEX app into declarative `.apx` source. Generating components correctly is solved (the official `apex` skill). What stays unsolved is **architecture**: a thin declarative front over a centralized PL/SQL core, instead of DML and rules scattered across pages.

**Core principle: the `.apx` only orchestrates. A PL/SQL package validates and writes. No region performs direct DML.**

The `.apx` may call two packages in sequence. What it never does is decide *where* a rule lives, or
coordinate an operation whose invariant spans entities — that belongs to a flow package
(`package-boundaries.md`).

Same front/back separation every serious web app uses, applied to APEX-as-code — and the part an agent does worst alone: it will bolt automatic table-bound DML onto each grid and call it "simple."

**REQUIRED SUB-SKILL:** Use the official `apex` skill for generating/validating/importing `.apx` (syntax, round-trip). This skill governs *where logic goes*, not `.apx` grammar.

## When to use

- Adding any screen that writes data (CRUD, editable IG, modal form).
- Adding a validation or business rule.
- Building a dashboard, KPI strip, or analytical report.
- Reviewing an APEXlang app for consistency across pages.

**Not for:** pure read-only one-off pages with no write path and no reuse; learning `.apx` grammar (use `apex`).

## The two decisions that matter

**1. Does the region write data?** If yes → every Create/Update/Delete goes through a PL/SQL package (the *single write-path*); the `.apx` process calls it and never issues DML itself, nor uses the built-in *Interactive Grid – Automatic Row Processing (DML)*. If no → reads use inline SQL or a `v_*` view.

**2. Which package owns it?** One package per table is the **default, not the obligation**. An entity
package owns its table and its satellites; a `_flow` package coordinates an operation whose invariant
spans entities and writes nothing itself; a `_api` package isolates one external system. Some rules
belong in a constraint, in the UI, or in no package at all. The ordered procedure is in
`package-boundaries.md` — read it before adding a package, and whenever an operation writes more than
one entity.

```
❌ Anti-pattern (agent default)        ✅ This skill
IG → Automatic Row Processing (DML)    IG → executeCode @afterSubmit
   → table directly                       → pkg_x.save_row(:APEX$ROW_STATUS, ...)
Validation in IG column                Validation + rules inside the package
DML in page processes                  All DML behind the package API
```

**This is not a deviation from the official standard — it is the exception the standard itself names.** `apex.interactive-grid-page.md` lists Automatic Row Processing as non-negotiable rule 6 (line 12), then carves it out under *Process Guidance* (line 49): *"do not substitute custom PL/SQL **unless invoking a dedicated API**."* The package the `.apx` calls — entity or flow — **is** that dedicated API. The per-row process is equally official: `executeCondition: forEachRow`, a property of the process's `serverSideCondition` group (paired with `executionScope`) in the APEXlang grammar — not a workaround.

## Which file to open

Read the **one** recipe the signal points to, plus its background file below. Two recipes at most,
and only when the screen genuinely combines archetypes (a faceted list that opens a drawer). Never
the whole folder "just in case".

**The screen writes** — what shape is the edit?

| Signal | Keywords | Read |
|---|---|---|
| Flat catalog, several rows edited in one sitting | interactive grid, inline edit, bulk edit, `save_row`, `APEX$ROW_STATUS` | `recipes/editable-ig-to-package.md` |
| One row at a time, few fields, opened from a master list | modal, popup, edit icon on a report row | `recipes/modal-crud-to-package.md` |
| Many fields in sections and its own URL — or edited without losing the list behind it | form page, drawer, `dialogFooter`, `pullOutEnd`, `formAutoRowProcessing` | `recipes/form-page-to-package.md` |
| Parent plus its child collection in one screen | master-detail, header + lines, FK stamped on save | `recipes/master-detail-edit.md` |
| The value has a validity period and history matters | vigency, rate/price history, `valid_from`/`valid_to`, append-only | `recipes/versioned-vigency-record.md` |
| Input the user cannot give in one screen | wizard, multi-step, `@/wizard-modal-dialog`, draft row, staging | `recipes/wizard-multi-step.md` |
| The verb is approve / reject / cancel, not "save" | workflow, state machine, status badge, transition guard | `recipes/workflow-state-transitions.md` |

**The screen only reads** — how does the user find the row?

| Signal | Keywords | Read |
|---|---|---|
| Filters over known columns, then browse | faceted search, facets, `filteredRegion`, cards, content row, directory | `recipes/master-faceted-search.md` |
| Pick on the left, read the detail on the right — list or hierarchy | split view, list + detail, `fullRowLink`, tree, `selectedNodePageItem` | `recipes/split-view-selection.md` |
| One record on its own page: facts, collections, comments, activity | item detail, `@/marquee`, tabs, `regionDisplaySelector`, contextual info, timeline | `recipes/item-detail-page.md` |
| Glanceable numbers and trends | dashboard, KPI, `metricCard`, chart, landing page | `recipes/dashboard-kpis-charts.md` |
| The working list of an entity: sort, filter, save a view, act on a row | interactive report, IR, browse list, row actions, `savedReport` | `recipes/browse-interactive-report.md` |
| Aggregated pivots and charts over the same data | analytical report, monthly/weekly view, `v_*` aggregation | `recipes/analytical-report.md` |

**Alongside the recipe, always:**

| Read when | File |
|---|---|
| Anything writes | `back-end-conventions.md` — single write-path, `-20xxx` catalog, no-COMMIT, views, soft delete, vigencies |
| Anything reads | `ui-contracts.md` — state tokens, drill-down URLs, derived columns, `cards` vs `contentRow`, selection state, deviating from an official default |
| An operation writes more than one table | `package-boundaries.md` — which layer owns it (entity / `_flow` / `_api`), the satellite and cross-entity tests, when NOT a package, the god-package threshold |

Unsure which term the source uses? Search before opening:

```bash
grep -rln "drawer\|closeDialog" skills/apexlang-architecture/recipes/
grep -rn  "badgeCssClasses\|BADGE_STATE" skills/apexlang-architecture/
```

Three runnable end-to-end slices (DDL + package + `.apx`, deploy-and-verify) live in `examples/` — start at `examples/README.md`. Recipe snippets are architectural shorthand, not import-ready grammar; the examples' `.apx` are `apex validate`-green — copy grammar from them (or the official `apex` skill), architecture from the recipes.

## Where each layer's authority comes from

Three sources, three jobs — do not blur them:

| Question | Authority |
|---|---|
| Is this valid `.apx`? Which properties, templates, slots exist? | official `apex` skill (APEXlang 2026.08.01) |
| What should this pattern look like, and when is it the right pattern? | Oracle's UX Pattern Catalog app (26.1.4) |
| Where does the logic live, what must the data layer project, and when may we deviate? | **this skill** |

The read-side recipes were built against that catalog. It is an Oracle sample app, not part of this skill, so recipes name its **patterns** (*Item Detail – Full*, *Faceted Search – Cards*) and never its page numbers, which are version-specific; a recipe cites it only where the citation carries an argument — usually a place where this skill deliberately does something else. Where the catalog and the official page standards disagree — and they do, on the faceted-search results region, on hidden region headers, on projecting theme classes from SQL — the disagreement is resolved in `ui-contracts.md`, and any deviation must carry its reason in the region's `comments` block.

## Common mistakes (from agent baselines)

| Rationalization | Reality |
|---|---|
| "Simple catalog, no business rules — just use Automatic DML" | Catalogs get FK-referenced fast. The day you must block "delete a sector that has employees" or enforce unique code with a friendly message, the rule needs a home. The write-path package is that home — create the seam now, it's one thin adapter. |
| "A package is ceremony / over-engineering" | The package is ~30 lines. The cost of *not* having it is DML and rules smeared across UI processes — untestable, inconsistent, duplicated per page. |
| "I'll add the package later when real rules appear" | Retrofitting a write-path after pages already do direct DML means rewriting every page that touched the table. Start with the seam. |
| "Uniqueness belongs in an IG column validation" | UI validations fire only in that grid — bypassed by jobs, SQLcl, REST, and your next page. The rule must live in the package (DB constraint as backstop), surfaced to the UI, not the other way around. |
| "It's read-only, so put the package there too" | No. Reads use inline SQL or a `v_*` view. Packages are the *write* path only. Don't invert it. |
| "The order is the centre of the business, so it all goes in `pkg_orders`" | That package now writes inventory, payments and customers — it is a flow package wearing an entity's name. One entity package per entity, one `_flow` to coordinate them (`package-boundaries.md` §God package). |
| "Every operation should have a service layer" | A `_flow` wrapping a single entity, or an `_api` with no external system, is a layer with nothing to abstract. Two tables is not by itself a reason for a third package (`package-boundaries.md` §When NOT a package). |

## Report contracts the live compiler enforces

Two rules break generated reports at `apex validate`, and both are easy to get wrong because Oracle's own templates still show the old form:

- **The link belongs to the column, never to the region.** A report-level `link { linkColumn / target / linkIcon }` is rejected (`REPORT_REGION_LINK_BLOCK_UNSUPPORTED_001`) for Classic and Interactive Reports alike. On an IR the linked column stays `type: plainText` and carries `link { target {…} linkText: … }`; `type: link` is Classic-Report-only.
- **`source.sqlQuery` is data-only.** Projecting markup is rejected (`REPORT_SQL_HTML_LITERAL_FORBIDDEN_001`). Select the value plus a plain CSS token and build the badge in `columnFormatting.htmlExpression` — see `workflow-state-transitions.md`.

Page-level validations follow a fixed skeleton — static ID prefixed `VAL_`, blocks in the order `name` → `execution` → `validation` → `error` → optional `serverSideCondition { whenButtonPressed: @<button> }` — and one page per file, named `p<5-digit>-<alias>.apx`.

## Red flags — move the write and the rule into the table's package

- You used `Automatic Row Processing (DML)`, or bound a region directly to a table for writing.
- An `executeCode` process contains `INSERT`/`UPDATE`/`DELETE` instead of a package call.
- A business rule (uniqueness, "in use" guard) lives in a page/validation a job or REST call could bypass, instead of once in the package.
- A package writes a table it does not own — neither its own entity nor one of that entity's satellites.
- A `_flow` package contains `INSERT`/`UPDATE`/`DELETE` instead of calling the entity packages.
- A `_flow` package wraps a single entity, or an operation the `.apx` could just call in sequence.
