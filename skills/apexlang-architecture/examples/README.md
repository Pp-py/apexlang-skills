# Examples — reproducible vertical slices

Two end-to-end slices that demonstrate the skill's core principle (a thin `.apx` front over
a centralized PL/SQL write-path core) and that you can deploy, import, and then verify with
the sibling **apex-sentinel** skill.

| Slice | Archetype | Recipe | Verify with |
|---|---|---|---|
| `sectors-catalog/` | editable Interactive Grid | `recipes/editable-ig-to-package.md` | `apex-sentinel/examples/sectors-catalog.md` |
| `absences-workflow/` | state machine / transitions | `recipes/workflow-state-transitions.md` | `apex-sentinel/examples/absences-workflow.md` |

## Shared core (deploy once)

| File | What |
|---|---|
| `00-pkg_errors.sql` | centralized error catalog, one reserved `-20xxx` band per domain |
| `00-error_handling_function.sql` | app EHF that strips the `ORA-20xxx:` prefix → friendly messages |

Deploy the shared core first, then each slice's `01-` / `02-` / `03-` in order. Each slice's
README has the exact commands.

## Conventions these examples follow

- **Single write-path:** all DML for a table lives behind one package; the `.apx` only orchestrates.
- **No COMMIT in the package:** APEX commits on page submit.
- **Rules in the package, not the UI:** uniqueness, legal-state guards, required fields — raised
  as `-20xxx` errors, surfaced friendly via the EHF.
- **DB constraints as backstop:** unique index / CHECK guarantee correctness; the package gives
  the friendly message.

## Grammar status & gotchas

Both `.apx` files pass `apex validate` against APEX 26.1 (SQLcl 26.1). Still re-validate
against **your** APEX version before `apex import`, and make sure the example page numbers
(30, 60, 62) and aliases don't collide with pages already in your app.

Non-obvious grammar rules these files respect (the parser rejects violations):

- **No `#` comments** anywhere in `.apx` — annotations go in PL/SQL comments inside
  ` ```plsql ` blocks, or in a README.
- **Expanded blocks only**: one property per line; compact one-liners like
  `execution { sequence: 10 }` are syntax errors.
- **Required properties**: pages need `appearance.pageTemplate` (or
  `pageMode`/`dialogTemplate` for modals), regions need `layout.sequence`/`layout.slot`
  and `appearance.template`, buttons need `appearance.buttonTemplate`, processes need a
  `name`.
- An **Interactive Grid requires at least one `savedReport`** child (with its
  `displayColumn` list); an Interactive Report does not.
- In an IR `link`, write `target: {` and `items: {` (with colon).

The recipes intentionally show snippets in a compact shorthand to stay readable — copy
grammar from these examples (or the official `apex` skill's templates), architecture from
the recipes. Identifiers (`hr_*` tables, `pkg_*` packages) match the recipes 1:1 so you
can read example and recipe side by side.
