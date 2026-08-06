---
name: apexlang-architecture
description: Use when deciding WHERE business logic, validation, or DML belongs in an Oracle APEX app written as APEXlang (.apx) — routing every write through one PL/SQL package per table instead of region-bound Automatic DML, and architecting screens that write (editable Interactive Grids, modal CRUD, master-detail, workflows, versioned/vigency records) or read (dashboards, faceted search, analytical reports). NOT for .apx grammar/validate/import/round-trip (use the official `apex` skill) or one-off read-only pages with no reuse.
---

# APEXlang Architecture

## Overview

APEXlang turns an APEX app into declarative `.apx` source. Generating components correctly is solved (the official `apex` skill). What stays unsolved is **architecture**: a thin declarative front over a centralized PL/SQL core, instead of DML and rules scattered across pages.

**Core principle: the `.apx` only orchestrates. A PL/SQL package validates and writes. No region performs direct DML.**

Same front/back separation every serious web app uses, applied to APEX-as-code — and the part an agent does worst alone: it will bolt automatic table-bound DML onto each grid and call it "simple."

**REQUIRED SUB-SKILL:** Use the official `apex` skill for generating/validating/importing `.apx` (syntax, round-trip). This skill governs *where logic goes*, not `.apx` grammar.

## When to use

- Adding any screen that writes data (CRUD, editable IG, modal form).
- Adding a validation or business rule.
- Building a dashboard, KPI strip, or analytical report.
- Reviewing an APEXlang app for consistency across pages.

**Not for:** pure read-only one-off pages with no write path and no reuse; learning `.apx` grammar (use `apex`).

## The one decision that matters

**Does the region write data?** If yes → route every Create/Update/Delete through one package per table (the *single write-path*); the `.apx` process calls it and never issues DML itself, nor uses the built-in *Interactive Grid – Automatic Row Processing (DML)*. If no → reads use inline SQL or a `v_*` view.

```
❌ Anti-pattern (agent default)        ✅ This skill
IG → Automatic Row Processing (DML)    IG → executeCode @afterSubmit
   → table directly                       → pkg_x.save_row(:APEX$ROW_STATUS, ...)
Validation in IG column                Validation + rules inside the package
DML in page processes                  All DML behind the package API
```

**This is not a deviation from the official standard — it is the exception the standard itself names.** `apex.interactive-grid-page.md` lists Automatic Row Processing as non-negotiable rule 6 (line 12), then carves it out under *Process Guidance* (line 49): *"do not substitute custom PL/SQL **unless invoking a dedicated API**."* The write-path package **is** that dedicated API. The per-row process is equally official: `executeCondition: forEachRow`, a property of the process's `serverSideCondition` group (paired with `executionScope`) in the APEXlang grammar — not a workaround.

## Recipes (one per screen archetype)

| Building | Recipe |
|---|---|
| Editable catalog (inline add/edit/delete) | `recipes/editable-ig-to-package.md` |
| Master list + create/edit modal | `recipes/modal-crud-to-package.md` |
| Parent + child collection edited together | `recipes/master-detail-edit.md` |
| Time-versioned value (rate/price history) | `recipes/versioned-vigency-record.md` |
| Request/approval state machine | `recipes/workflow-state-transitions.md` |
| Searchable master with filters | `recipes/master-faceted-search.md` |
| Home dashboard (KPIs + charts) | `recipes/dashboard-kpis-charts.md` |
| Analytical report (IRs + charts) | `recipes/analytical-report.md` |

The PL/SQL core conventions every recipe relies on — single write-path, error catalog, no-COMMIT, views, vigencies/soft-delete — are in `back-end-conventions.md`. **Read it before the recipes.**

Two runnable end-to-end slices (DDL + package + `.apx`, deploy-and-verify) live in `examples/` — start at `examples/README.md`. Recipe snippets are architectural shorthand, not import-ready grammar; the examples' `.apx` are `apex validate`-green — copy grammar from them (or the official `apex` skill), architecture from the recipes.

## Common mistakes (from agent baselines)

| Rationalization | Reality |
|---|---|
| "Simple catalog, no business rules — just use Automatic DML" | Catalogs get FK-referenced fast. The day you must block "delete a sector that has employees" or enforce unique code with a friendly message, the rule needs a home. The write-path package is that home — create the seam now, it's one thin adapter. |
| "A package is ceremony / over-engineering" | The package is ~30 lines. The cost of *not* having it is DML and rules smeared across UI processes — untestable, inconsistent, duplicated per page. |
| "I'll add the package later when real rules appear" | Retrofitting a write-path after pages already do direct DML means rewriting every page that touched the table. Start with the seam. |
| "Uniqueness belongs in an IG column validation" | UI validations fire only in that grid — bypassed by jobs, SQLcl, REST, and your next page. The rule must live in the package (DB constraint as backstop), surfaced to the UI, not the other way around. |
| "It's read-only, so put the package there too" | No. Reads use inline SQL or a `v_*` view. Packages are the *write* path only. Don't invert it. |

## Report contracts the live compiler enforces

Two rules break generated reports at `apex validate`, and both are easy to get wrong because Oracle's own templates still show the old form:

- **The link belongs to the column, never to the region.** A report-level `link { linkColumn / target / linkIcon }` is rejected (`REPORT_REGION_LINK_BLOCK_UNSUPPORTED_001`) for Classic and Interactive Reports alike. On an IR the linked column stays `type: plainText` and carries `link { target {…} linkText: … }`; `type: link` is Classic-Report-only.
- **`source.sqlQuery` is data-only.** Projecting markup is rejected (`REPORT_SQL_HTML_LITERAL_FORBIDDEN_001`). Select the value plus a plain CSS token and build the badge in `columnFormatting.htmlExpression` — see `workflow-state-transitions.md`.

Page-level validations follow a fixed skeleton — static ID prefixed `VAL_`, blocks in the order `name` → `execution` → `validation` → `error` → optional `serverSideCondition { whenButtonPressed: @<button> }` — and one page per file, named `p<5-digit>-<alias>.apx`.

## Red flags — move the write and the rule into the table's package

- You used `Automatic Row Processing (DML)`, or bound a region directly to a table for writing.
- An `executeCode` process contains `INSERT`/`UPDATE`/`DELETE` instead of a package call.
- A business rule (uniqueness, "in use" guard) lives in a page/validation a job or REST call could bypass, instead of once in the package.
