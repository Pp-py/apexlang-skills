---
name: apexlang-architecture
description: Use when deciding WHERE business logic, validation, or DML belongs in an Oracle APEX app written as APEXlang (.apx) — routing every write through a PL/SQL package instead of region-bound Automatic DML and deciding which package owns it (one entity, a multi-entity flow, an external system) or whether the rule belongs in a database constraint, the UI, or no package at all, and architecting screens that write (editable Interactive Grids, modal CRUD, full-page and drawer forms, master-detail, workflows, versioned/vigency records) or read (dashboards, faceted search, split-view browsers, analytical reports), including what the SQL/view must project to feed cards, content rows, badges and drill-down links. NOT for .apx grammar/validate/import/round-trip (use Oracle's APEXlang skills) or one-off read-only pages with no reuse.
---

# APEXlang Architecture

## Contract

- **Does:** decides where each rule lives and which package owns each write, before the `.apx` and the package are built.
- **Use when:** a screen writes data, a rule or validation is added, a read-side screen needs its data contract, or a page is reviewed.
- **Decides:** the single write path — a rule goes to a constraint, the UI or the owning package; an operation to an entity, `_flow` or `_api` package, or to no package at all (`package-boundaries.md`).
- **Output:** an `architecture-result` decision record (`<evidenceDir>/<task>/architecture.json`) — `references/decision-record.md`.
- **Evidence:** each decision tied to the code that implements it; the red-flag scan's commands and their output.
- **Gate:** Architecture (`framework/GATES.md`) — discipline. A missing input BLOCKS; a red flag FAILS.

## Overview

APEXlang turns an APEX app into declarative `.apx` source. Generating and validating components is Oracle's job (its APEXlang skills, `apex@oracle-skills`, routed by APEX version). What stays unsolved is **architecture**: a thin declarative front over a centralized PL/SQL core, instead of DML and rules scattered across pages.

**Core principle: the `.apx` only orchestrates. A PL/SQL package validates and writes. No region performs direct DML.**

The `.apx` may call two packages in sequence; it never decides *where* a rule lives, nor coordinates an operation whose invariant spans entities — that is a flow package's job (`package-boundaries.md`). Left alone, an agent bolts automatic table-bound DML onto each grid and calls it "simple."

**REQUIRED SUB-SKILL:** Oracle's APEXlang skills (`apexlang-inventory`, `apexlang-compile`, `apexlang-deploy`) for grammar, generation (26.1), validation and import. This skill governs *where logic goes*.

## When NOT to use

- A read-only one-off page with no write path and no reuse.
- `.apx` grammar, validation or import questions — Oracle's APEXlang skills.

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

**This is a deliberate deviation from Oracle's default**, resting on an exception Oracle's own standard names: the 26.1 policies say *"Prefer ARP for simple CRUD"*, and the Interactive Grid page rule that requires Automatic Row Processing also says *"do not substitute custom PL/SQL **unless invoking a dedicated API**"* — the package the `.apx` calls **is** that API. Everywhere else the standard already points this way (`invokeApi` by default, inline PL/SQL extracted into a package API). The argument, quoted and anchored: `references/official-standard.md`. Calling the package through `invokeApi` or a thin `executeCode` wrapper both satisfy the single write path (`framework/CAPABILITIES.md` KC-4).

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
| Anything writes | `back-end-conventions.md` — the write path, the validation ladder, `-20xxx` catalog, no COMMIT, views, soft delete, vigencies, version token |
| Anything reads | `ui-contracts.md` — state tokens, drill-down URLs, derived columns, `cards` vs `contentRow`, selection state, deviating from an official default |
| An operation writes more than one table | `package-boundaries.md` — which layer owns it, the satellite and cross-entity tests, when NOT a package, the god-package threshold |

Three runnable slices (DDL + package + `.apx`) live in `examples/` — start at `examples/README.md`. Recipe snippets are architectural shorthand, not import-ready grammar: copy grammar from Oracle's `apexlang-inventory` first and the examples second (they pass the 26.1 lint, the SQLcl compiler currently rejects them — KC-7), architecture from the recipes.

## Where each layer's authority comes from

Three sources, three jobs: Oracle for whether `.apx` is valid (the compiler, then the 26.1 lint, then the inventory, policies and templates — `framework/PRINCIPLES.md` P6); Oracle's UX Pattern Catalog app for what a pattern looks like; **this skill** for where the logic lives, what the data layer projects, and when to deviate — `references/official-standard.md`.

## Common mistakes (from agent baselines)

| Rationalization | Reality |
|---|---|
| "Simple catalog, no business rules — just use Automatic DML" | Catalogs get FK-referenced fast; the day "delete a sector that has employees" must be refused with a friendly message, the rule needs a home. The package is that home — create the seam now, one thin adapter. |
| "A package is ceremony / over-engineering" | The package is ~30 lines. The cost of *not* having it is DML and rules smeared across UI processes — untestable, inconsistent, duplicated per page. |
| "I'll add the package later when real rules appear" | Retrofitting a write-path after pages already do direct DML means rewriting every page that touched the table. Start with the seam. |
| "Uniqueness belongs in an IG column validation" | It fires only in that grid — bypassed by jobs, SQLcl, REST and the next page, and racy under concurrency. The rule lives in the package (a constraint as backstop), surfaced to the UI; why Oracle's validation ladder does not make the page its owner: `back-end-conventions.md` §2. |
| "It's read-only, so put the package there too" | No. Reads use inline SQL or a `v_*` view. Packages are the *write* path only. Don't invert it. |
| "The order is the centre of the business, so it all goes in `pkg_orders`" | That package now writes inventory, payments and customers — it is a flow package wearing an entity's name. One entity package per entity, one `_flow` to coordinate them (`package-boundaries.md` §God package). |
| "Every operation should have a service layer" | A `_flow` wrapping a single entity, or an `_api` with no external system, is a layer with nothing to abstract. Two tables is not by itself a reason for a third package (`package-boundaries.md` §When NOT a package). |

## Report rules

A report's link belongs to a column of `type: link`, never to the region. `source.sqlQuery` projects data, never markup. Page validations follow a fixed skeleton. Oracle's 26.1 lint enforces the first two, and SQLcl's compiler enforces neither (measured). This skill keeps both as its own rules. Where the lint contradicts the compiler, the compiler wins: the lint forbids `type: link` on an Interactive Report column, and that is the form the compiler requires. The measured table is in `references/oracle-26.1-lint.md`.

## Red flags — move the write and the rule into the table's package

- You used `Automatic Row Processing (DML)`, or bound a region directly to a table for writing.
- An `executeCode` process contains `INSERT`/`UPDATE`/`DELETE` instead of a package call.
- A business rule (uniqueness, "in use" guard) lives in a page/validation a job or REST call could bypass, instead of once in the package.
- A package writes a table it does not own — neither its own entity nor one of that entity's satellites.
- A `_flow` package contains `INSERT`/`UPDATE`/`DELETE` instead of calling the entity packages.
- A `_flow` package wraps a single entity, or an operation the `.apx` could just call in sequence.
- A write-path package updates by PK alone, with no version token — the lost-update guard that Automatic Row Processing used to provide (`back-end-conventions.md` §7).

How to scan for each of these, and how to record what was decided: `references/decision-record.md`.
