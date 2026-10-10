# Report rules: what Oracle's 26.1 lint enforces, and what the compiler does

The lint and the compiler disagree on report links and markup, and that was measured: probe pages
on Oracle's 26.1 scaffold, run under the 26.1 lint and under SQLcl 26.2.0.181.2110 `apex validate`
on 2026-10-10 (`framework/CAPABILITIES.md` §Recorded runs). Here is what each one accepts:

| Form | 26.1 lint | SQLcl compiler | This skill |
|---|---|---|---|
| HTML literal in `source.sqlQuery` | rejects (`REPORT_SQL_HTML_LITERAL_FORBIDDEN_001`) | accepts | **never** — Oracle's `apex.report-column-rendering.md` rule 1 and `ui-contracts.md` §2: project data plus a class from a closed set, and build the markup in `columnFormatting.htmlExpression` (`../recipes/workflow-state-transitions.md`) |
| report-level `link { linkColumn / target / linkIcon }` | rejects (`REPORT_REGION_LINK_BLOCK_UNSUPPORTED_001`, which says a live 26.1 import refuses it) | accepts | **never** — until an import proves the lint wrong |
| Interactive Report column `type: link` + `link { target, linkText }` | rejects (`INTERACTIVE_REPORT_LINK_COLUMN_TYPE_FORBIDDEN_001`) | accepts | **the form to use**, on Classic and Interactive Reports alike |
| Interactive Report column `type: plainText` + `link { target, linkText }` | accepts | **rejects** (`Invalid property: target`, `linkText`) | never |

The REPORT rules therefore do not gate anything: they are lint-level guidance (Oracle calls the
lint *"syntax hygiene"*). This skill keeps two of them as its own rules, data-only SQL and no
region-level link, because each has a reason that does not depend on the toolchain. Where the lint
contradicts the compiler, as with `type: link` on an IR column, the compiler wins
(`framework/PRINCIPLES.md` P6). The examples carry that lint finding as a documented diagnostic
(`tests/upstream/expected-diagnostics.txt`).

Page-level validations follow a fixed skeleton — static ID prefixed `VAL_`, blocks in the order `name` → `execution` → `validation` → `error` → optional `serverSideCondition { whenButtonPressed: @<button> }` — and one page per file, named `p<5-digit>-<alias>.apx`.

The lint is advisory — Oracle calls it "syntax hygiene" — and never a Validation verdict;
the compiler is (`framework/GATES.md`). What still keeps the examples from compiling:
`framework/CAPABILITIES.md` KC-7.
