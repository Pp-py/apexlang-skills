# Citation anchors — the official APEXlang package

Every sentence this repo quotes from the official `apex` skill, as an anchor `tests/verify-citations.sh`
can check. The point is the failure mode: a line number silently starts pointing at a *different*
sentence when Oracle edits the file above it, while a phrase that no longer exists produces an empty
grep — loud, and greppable.

Verified against **oracle/skills@b0afa3b (2026-09-10)**. Update that stamp when the verifier passes
against a newer package.

Format: `<path relative to the apexlang package> | <anchor phrase, matched with grep -F> | <where we cite it>`
Rules: one row per distinct phrase; each phrase must appear **exactly once** in its file — two hits
means the anchor is ambiguous and must be made longer, which is the signal, not a false positive.
Pick phrases that carry the claim, so a reworded rule breaks the check instead of passing silently.

```citations
references/policies/memory-bank/20-data/apex.logic.md | page processes default to `invokeApi` | SKILL.md §Two decisions
references/policies/memory-bank/20-data/apex.logic.md | Server-side work should be packaged and referenced via `invokeApi` by default | SKILL.md §Two decisions
references/policies/memory-bank/20-data/apex.logic.md | extract it into a package API | SKILL.md §Two decisions (PLSQL_INLINE_BLOCK_001)
references/policies/memory-bank/20-data/apex.logic.md | Do not convert validation requirements into page processes | back-end-conventions.md §2
references/policies/memory-bank/20-data/apex.logic.md | SQL validation (`noRowsReturned`/`rowsReturned`) | back-end-conventions.md §2
templates/business-logic/validations/validations._common.md | optimistic-lock conflicts | back-end-conventions.md §2 and §7
references/policies/memory-bank/30-pages/apex.form.md | exactly one `formAutoRowProcessing` | recipes/form-page-to-package.md, examples/employees-form/README.md
references/policies/memory-bank/30-pages/apex.form.md | offload logic to views or packages when possible | SKILL.md §Two decisions, recipes/form-page-to-package.md
references/policies/memory-bank/30-pages/apex.interactive-grid-page.md | unless invoking a dedicated API | SKILL.md §Two decisions, recipes/editable-ig-to-package.md, recipes/form-page-to-package.md, recipes/master-detail-edit.md
references/policies/memory-bank/30-pages/apex.interactive-grid-page.md | Enable automatic row processing | SKILL.md §Two decisions (non-negotiable rule 6)
```
