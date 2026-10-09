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
26.1/apexlang-generation/SKILL.md | Selection is not authorization | framework/PRINCIPLES.md (P9)
SKILL.md | If the version is unknown, use 26.1. | framework/CONTRACTS.md (version routing)
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
```
