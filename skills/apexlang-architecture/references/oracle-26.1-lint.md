# Report rules Oracle's 26.1 lint enforces

Two rules Oracle's 26.1 lint rejects (whether the SQLcl compiler does is unverified — `framework/CAPABILITIES.md` KC-6), both easy to get wrong because Oracle's own templates still show the old form:

- **The link belongs to the column, never to the region.** A report-level `link { linkColumn / target / linkIcon }` is rejected (`REPORT_REGION_LINK_BLOCK_UNSUPPORTED_001`) for Classic and Interactive Reports alike. On an IR the linked column stays `type: plainText` and carries `link { target {…} linkText: … }`; `type: link` is Classic-Report-only.
- **`source.sqlQuery` is data-only.** Projecting markup is rejected (`REPORT_SQL_HTML_LITERAL_FORBIDDEN_001`). Select the value plus a plain CSS token and build the badge in `columnFormatting.htmlExpression` — see `../recipes/workflow-state-transitions.md`.

Page-level validations follow a fixed skeleton — static ID prefixed `VAL_`, blocks in the order `name` → `execution` → `validation` → `error` → optional `serverSideCondition { whenButtonPressed: @<button> }` — and one page per file, named `p<5-digit>-<alias>.apx`.

The lint is advisory — Oracle calls it "syntax hygiene" — and never a Validation verdict;
the compiler is (`framework/GATES.md`). Where the two disagree on the examples:
`framework/CAPABILITIES.md` KC-7.
