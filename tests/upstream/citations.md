# Citation anchors — Oracle's APEXlang skills

Every passage this repo quotes from Oracle's APEXlang skills, or whose exact wording our behavior depends on,
as an anchor `tests/upstream/verify-citations.sh` can check. The point is the failure mode: a line number
silently starts pointing at a *different* sentence when Oracle edits the file above it, while a phrase that no
longer exists produces an empty grep — loud, and greppable.

Verified against the commit pinned in [`framework/oracle-skills.lock.json`](../../framework/oracle-skills.lock.json)
(`verifiedAt` there is only set by a run against that exact commit).

Format: `<path relative to the version router, apex/apexlang/> | <anchor phrase, matched with grep -F> | <where we cite it>`
Rules: one row per distinct phrase; each phrase must appear **exactly once** in its file — two hits means the
anchor is ambiguous and must be made longer, which is the signal, not a false positive. Pick phrases that carry
the claim, so a reworded rule breaks the check instead of passing silently. Policies, the lint and `apexctl`
exist only in the 26.1 bundle (`26.1/apexlang-generation/`); 26.2 ships compile, deploy, inventory and examples.

```citations
26.1/apexlang-generation/references/policies/memory-bank/20-data/apex.logic.md | page processes default to `invokeApi` | apexlang-architecture references/official-standard.md
26.1/apexlang-generation/references/policies/memory-bank/20-data/apex.logic.md | Server-side work should be packaged and referenced via `invokeApi` by default | apexlang-architecture references/official-standard.md
26.1/apexlang-generation/references/policies/memory-bank/20-data/apex.logic.md | extract it into a package API | apexlang-architecture references/official-standard.md (PLSQL_INLINE_BLOCK_001)
26.1/apexlang-generation/references/policies/memory-bank/20-data/apex.logic.md | Do not convert validation requirements into page processes | apexlang-architecture back-end-conventions.md §2
26.1/apexlang-generation/references/policies/memory-bank/20-data/apex.logic.md | SQL validation (`noRowsReturned`/`rowsReturned`) | apexlang-architecture back-end-conventions.md §2
26.1/apexlang-generation/templates/business-logic/validations/validations._common.md | optimistic-lock conflicts | apexlang-architecture back-end-conventions.md §2 and §7
26.1/apexlang-generation/references/policies/memory-bank/30-pages/apex.form.md | exactly one `formAutoRowProcessing` | apexlang-architecture recipes/form-page-to-package.md, examples/employees-form/README.md
26.1/apexlang-generation/references/policies/memory-bank/30-pages/apex.form.md | offload logic to views or packages when possible | apexlang-architecture references/official-standard.md, recipes/form-page-to-package.md
26.1/apexlang-generation/references/policies/memory-bank/30-pages/apex.interactive-grid-page.md | unless invoking a dedicated API | apexlang-architecture SKILL.md, references/official-standard.md, recipes/editable-ig-to-package.md, recipes/form-page-to-package.md, recipes/master-detail-edit.md
26.1/apexlang-generation/references/policies/memory-bank/30-pages/apex.interactive-grid-page.md | Enable automatic row processing | apexlang-architecture references/official-standard.md (non-negotiable rule 6)
26.1/apexlang-generation/references/policies/memory-bank/10-global/apex.global.md | Prefer ARP for simple CRUD | apexlang-architecture references/official-standard.md (the deviation, stated)
26.1/apexlang-generation/SKILL.md | Selection is not authorization | apexlang-architecture references/decision-record.md (missingInputs block)
SKILL.md | If the version is unknown, use 26.1. | README.md (Requirements: the version Oracle's router defaults to)
26.1/apexlang-generation/references/ops/runtime-gates.md | --import-intent validate-and-import | apex-sync-guard references/import-lanes.md, scripts/apex-sync-hook.sh
26.1/apexlang-generation/tools/apexctl.mjs | readOption(args, "--runtime-action", "validate-only") | apex-sync-guard scripts/apex-sync-hook.sh (default intent; --runtime-action alias)
26.1/apexlang-generation/references/ops/runtime-gates.md | Normalize every `.apx` source file from CRLF or CR to LF | apex-sync-guard references/model.md (the E status)
26.1/apexlang-generation/references/ops/runtime-gates.md | Treat local repo validation as syntax hygiene | framework/GATES.md (Validation: lint is advisory), tests/upstream/validate-examples.sh
26.1/apexlang-generation/references/ops/runtime-gates.md | `local_validate` remains an advisory/helper phase | framework/GATES.md (Validation: lint is advisory)
26.1/apexlang-generation/references/ops/runtime-gates.md | Browser/runtime verification is not a pre-import gate | apex-sentinel references/oracle-verify-ui.md
26.1/apexlang-generation/references/ops/runtime-gates.md | do not rewrite a successful import to fail | apex-sentinel references/oracle-verify-ui.md
26.1/apexlang-generation/runtime/runtime.bundle.mjs | Post-import runtime verification is disabled by default. | apex-sentinel references/oracle-verify-ui.md
26.1/apexlang-generation/runtime/runtime.bundle.mjs | Chrome DevTools MCP runtime verification is not available in this CLI execution path | apex-sentinel references/oracle-verify-ui.md
26.2/apexlang-deploy/scripts/deploy-apex-app.sh | apex import -input "$app_directory" | apex-sync-guard references/import-lanes.md, scripts/apex-sync-hook.sh (deploy lane)
26.1/apexlang-deploy/scripts/deploy-apex-app.sh | apex import -input "$app_directory" | apex-sync-guard references/import-lanes.md (identical in 26.1)
26.2/apexlang-compile/scripts/validate-apex-app.sh | grep -Fq "Validation successful" | framework/CONTRACTS.md (Validation signal), tests/upstream/validate-examples.sh --compiler
26.2/apexlang-compile/scripts/validate-apex-app.sh | report APEXLang validation errors while still returning status 0 | framework/CONTRACTS.md (exit 0 alone is not a PASS)
26.2/apexlang-inventory/assets/app/page/process/plugin-variants/interactive-grid-auto-row-processing/interactive-grid-auto-row-processing.md | interactiveGridAutoRowProcessing:"Interactive Grid - Automatic Row Processing (DML)" | apexlang-architecture references/decision-record.md (red-flag scan)
26.2/apexlang-inventory/assets/app/page/process/plugin-variants/form-auto-row-processing/form-auto-row-processing.md | formAutoRowProcessing:"Form - Automatic Row Processing (DML)" | apexlang-architecture references/decision-record.md (red-flag scan)
26.2/apexlang-inventory/assets/app/page/process/plugin-variants/auto-row-processing/auto-row-processing.md | autoRowProcessing:"Automatic Row Processing (DML)" | apexlang-architecture references/decision-record.md (red-flag scan)
26.1/apexlang-generation/references/policies/memory-bank/30-pages/apex.cards-page.md | project only `u-normal`, `u-hot`, `u-info`, `u-success`, `u-warning`, `u-danger`, or `NULL` | apexlang-architecture ui-contracts.md §2
26.1/apexlang-generation/references/policies/memory-bank/40-components/apex.region-contracts.md | connect drilldown through nearby report/card links rather than chart or metric actions | apexlang-architecture ui-contracts.md §3, recipes/dashboard-kpis-charts.md
26.1/apexlang-generation/references/policies/memory-bank/40-components/apex.region-interactions.md | Metric Card supports one row-level action position, `link`. Use a declarative behavior target | apexlang-architecture ui-contracts.md §3, recipes/dashboard-kpis-charts.md
26.1/apexlang-generation/references/policies/memory-bank/40-components/apex.region-interactions.md | Use declarative `behavior.target` for redirects | apexlang-architecture ui-contracts.md §3
26.1/apexlang-generation/references/policies/memory-bank/20-data/apex.sql.md | MUST: Use process type: invokeApi with invoke | framework/CAPABILITIES.md (KC-4)
26.1/apexlang-generation/references/policies/memory-bank/20-data/apex.sql.md | MUST NOT: Use executeCode to call packages via plsqlCode | framework/CAPABILITIES.md (KC-4)
26.1/apexlang-generation/references/policies/memory-bank/10-global/apex.global.md | MUST: Allow a thin page-level `executeCode` wrapper for packaged calls | framework/CAPABILITIES.md (KC-4)
26.1/apexlang-compile/scripts/validate-apex-app.sh | grep -Fq "Validation successful" | framework/CONTRACTS.md (Validation signal, identical in 26.1)
26.1/apexlang-compile/scripts/validate-apex-app.sh | report APEXLang validation errors while still returning status 0 | framework/CONTRACTS.md (identical in 26.1)
26.1/apexlang-inventory/assets/app/page/process/plugin-variants/interactive-grid-auto-row-processing/interactive-grid-auto-row-processing.md | interactiveGridAutoRowProcessing:"Interactive Grid - Automatic Row Processing (DML)" | apexlang-architecture references/decision-record.md (identical in 26.1)
26.1/apexlang-inventory/assets/app/page/process/plugin-variants/form-auto-row-processing/form-auto-row-processing.md | formAutoRowProcessing:"Form - Automatic Row Processing (DML)" | apexlang-architecture references/decision-record.md (identical in 26.1)
26.1/apexlang-inventory/assets/app/page/process/plugin-variants/auto-row-processing/auto-row-processing.md | autoRowProcessing:"Automatic Row Processing (DML)" | apexlang-architecture references/decision-record.md (identical in 26.1)
26.1/apexlang-generation/references/policies/memory-bank/30-pages/apex.cards-page.md | Do not concatenate arbitrary CSS | apexlang-architecture ui-contracts.md §2
26.1/apexlang-generation/references/policies/memory-bank/30-pages/apex.cards-page.md | Reject HTTP, dynamic target substitutions | apexlang-architecture ui-contracts.md §3
26.1/apexlang-generation/references/policies/memory-bank/30-pages/apex.report-column-rendering.md | SQL/PLSQL source must remain data-only. | apexlang-architecture ui-contracts.md §2, references/oracle-26.1-lint.md, recipes/workflow-state-transitions.md
26.1/apexlang-generation/references/policies/memory-bank/30-pages/apex.report-column-rendering.md | htmlExpression: <span class="t-Badge">#SOME_COL#</span> | apexlang-architecture ui-contracts.md §2 (the report badge)
26.1/apexlang-generation/templates/template-components/badge/badge._common.md | whose values are restricted to `danger`, `warning`, `success`, or `info`; emit only when the user requests a semantic state | apexlang-architecture ui-contracts.md §2
26.1/apexlang-generation/templates/template-components/comments/comments._template_options.md | prompt=`Apply Theme Colors` | apexlang-architecture ui-contracts.md §2, recipes/item-detail-page.md
26.1/apexlang-inventory/assets/app/page/region/column-c1/column-c1.md | - `target` — `<COMPLEX>`; —; Yes; —; —; —; `column[identification.type] = link`; | apexlang-architecture recipes/modal-crud-to-package.md (an IR column link needs `type: link`)
26.1/apexlang-generation/references/policies/memory-bank/10-global/apex.global.md | Every item requires an accessible name. Prefer visible labels. | apex-ux criteria/common.md (UX-ITEM-NAME)
26.1/apexlang-generation/references/policies/memory-bank/10-global/apex.global.md | Placeholders are never a substitute for labels. | apex-ux criteria/common.md (UX-ITEM-NAME)
26.1/apexlang-generation/references/policies/memory-bank/10-global/apex.global.md | Avoid color-only cues; provide text or icons with accessible names. | apex-ux criteria/common.md (UX-NO-COLOR-ONLY)
26.1/apexlang-generation/references/policies/memory-bank/10-global/apex.global.md | All interactions must be keyboard-operable. | apex-ux criteria/common.md (UX-DIALOG-FOCUS)
26.1/apexlang-generation/references/policies/memory-bank/10-global/apex.global.md | Ensure focus outlines are visible and keyboard traversal is complete. | apex-ux criteria/common.md (UX-FOCUS-VISIBLE)
26.1/apexlang-generation/references/policies/memory-bank/10-global/apex.global.md | Adhere to UT accessible palette. | apex-ux criteria/common.md (UX-NO-INLINE-STYLE)
26.1/apexlang-generation/references/policies/memory-bank/40-components/apex.region-media.md | Use icons to reinforce navigation/action meaning, not as the only accessible label. | apex-ux criteria/common.md (UX-CONTROL-NAME)
26.1/apexlang-generation/references/policies/memory-bank/40-components/apex.buttons.md | If requiresConfirmation = true then include confirmation block with message and style | apex-ux criteria/common.md (UX-DESTRUCTIVE-CONFIRM)
26.1/apexlang-generation/references/policies/memory-bank/40-components/apex.buttons.md | single primary actions belong next to the title | apex-ux criteria/common.md (UX-ONE-PRIMARY)
26.1/apexlang-generation/references/policies/memory-bank/30-pages/apex.form.md | uses apex.confirm(...); databaseAction: delete | apex-ux criteria/common.md (UX-DESTRUCTIVE-CONFIRM)
26.1/apexlang-generation/references/policies/memory-bank/30-pages/apex.form.md | Default single-row create/edit form pages launched from reports to drawer end/right | apex-ux criteria/data-entry.md (UXENT-PRESENTATION)
26.1/apexlang-generation/references/policies/memory-bank/30-pages/apex.form.md | Ensure responsive behavior (stacking on small screens) is not impeded. | apex-ux criteria/common.md (UX-REFLOW)
26.1/apexlang-generation/references/policies/governance/00-governance.md | Never invent CSS classes to solve structure, spacing, alignment, or framing. | apex-ux criteria/common.md (UX-NO-INLINE-STYLE, UX-NO-INVENTED-CLASS)
26.1/apexlang-generation/references/policies/memory-bank/40-components/apex.templates.md | Treat non-structural skinning as out of active scope | apex-ux criteria/common.md (UX-NO-INLINE-STYLE)
26.1/apexlang-generation/references/policies/memory-bank/40-components/apex.templates.md | Breadcrumb/title-bar regions must not expose generic chrome labels | apex-ux criteria/common.md (UX-TITLEBAR-NAME)
26.1/apexlang-generation/references/policies/memory-bank/40-components/apex.templates.md | Use `@/required-floating` for required visible form items. | apex-ux criteria/data-entry.md (UXENT-REQUIRED)
26.1/apexlang-generation/references/policies/memory-bank/30-pages/apex.classic-report.md | Default pagination is `rowRangesXToYNoPagination` with a `whenNoDataFound` message | apex-ux criteria/common.md (UX-EMPTY-STATE)
26.1/apexlang-generation/references/policies/memory-bank/30-pages/apex.interactive-report.md | include `messages.whenNoDataFound` | apex-ux criteria/common.md (UX-EMPTY-STATE)
26.1/apexlang-generation/references/policies/memory-bank/30-pages/apex.interactive-report.md | normalize both sides of user-entered text predicates with `LOWER()` | apex-ux criteria/browse-search.md (UXBRW-SEARCH-CASE)
26.1/apexlang-generation/references/policies/memory-bank/40-components/apex.items.md | Every user-editable item and every filter/control item should carry concise help by default | apex-ux criteria/common.md (UX-HELP-EDITABLE)
26.1/apexlang-generation/references/policies/memory-bank/30-pages/apex.page.md | Inline HTML event handlers (onclick, onload, etc.) | apex-ux criteria/common.md (UX-NO-INLINE-HANDLER)
26.1/apexlang-generation/references/policies/memory-bank/30-pages/apex.layout.md | Prefer 2-6 KPIs in one row when labels are short and content is single-value. | apex-ux criteria/dashboards.md (UXDASH-KPI-COUNT)
26.1/apexlang-generation/references/policies/memory-bank/30-pages/apex.dashboard.md | Do not emit aggregate KPI tiles as `classicReport` regions. | apex-ux criteria/dashboards.md (UXDASH-KPI-METRICCARD)
26.1/apexlang-generation/references/policies/memory-bank/30-pages/apex.dashboard.md | Do not literally stack multiple dashboard charts | apex-ux criteria/dashboards.md (UXDASH-CHART-ROWS)
26.1/apexlang-generation/references/policies/memory-bank/30-pages/apex.faceted-search.md | Use consistent facet sequencing: search → categorical facets → range facets. | apex-ux criteria/browse-search.md (UXBRW-FACET-ORDER)
26.1/apexlang-generation/references/policies/memory-bank/30-pages/apex.smart-filter-search.md | Give every search/refinement child a concise visible label | apex-ux criteria/browse-search.md (UXBRW-FILTER-LABELS)
26.1/apexlang-generation/references/policies/memory-bank/20-data/apex.logic.md | Messages: concise, user-friendly, and associated to items. | apex-ux criteria/common.md (UX-MESSAGES)
```
