# Examples — verification walkthroughs

Concrete, runnable instantiations of the `checks/` against the example pages built by the
sibling **apexlang-architecture** skill (`apexlang-architecture/examples/`). Each walkthrough
is one check applied to one shipped page, so you can see the whole architect → build → verify
loop close on a real artifact.

| Walkthrough | Verifies | Against the page built in | Based on check |
|---|---|---|---|
| `sectors-catalog.md` | IG routes writes through `pkg_sectors`; duplicate → friendly error | `apexlang-architecture/examples/sectors-catalog/` (page 30) | `checks/editable-ig.md` |
| `absences-workflow.md` | transitions are guarded package verbs; illegal transition blocked | `apexlang-architecture/examples/absences-workflow/` (page 60/62) | `checks/workflow-state.md` |

## Before you start

1. Build and import the corresponding slice first (see each slice's README under
   `apexlang-architecture/examples/`).
2. Read `../setup.md` — backend choice/config, base-URL/TLS resolution, login, session
   preservation.
3. **Step 0 every time:** run the launcher probe in `../SKILL.md` §Prerequisites — resolve the
   Playwright CLI (global binary *or* npx; `which playwright-cli` alone is not the test), and
   only fall back to a browser-MCP if it resolves nothing. No browser → stop and report; never
   claim verification from `validate`/`import` alone.

Both walkthroughs lead with the **rejection / illegal path**, which exercises the full write
path and the business rule **without persisting test data**.
