# Examples — reproducible vertical slices

Three end-to-end slices that demonstrate the skill's core principle (a thin `.apx` front over
a centralized PL/SQL write-path core) and that you can deploy, import, and then verify with
the sibling **apex-sentinel** skill.

| Slice | Archetype | Recipe | Verify with |
|---|---|---|---|
| `sectors-catalog/` | editable Interactive Grid | `recipes/editable-ig-to-package.md` | `apex-sentinel/examples/sectors-catalog.md` |
| `absences-workflow/` | state machine / transitions | `recipes/workflow-state-transitions.md` | `apex-sentinel/examples/absences-workflow.md` |
| `employees-form/` | single-entity form (full page + drawer) | `recipes/form-page-to-package.md` | `apex-sentinel/checks/form-page.md` |

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
- **Lost-update guard** (`back-end-conventions.md` §7): `pkg_sectors` and `pkg_employees` update and
  inactivate only at the `row_version` the page loaded, bump it in the same statement and raise
  `pkg_errors.k_row_changed` when it moved; the pages carry it back (a hidden IG column, a hidden
  item). `pkg_absences` needs no token: each transition locks its row (`FOR UPDATE`) and checks the
  from-state, and no screen edits an absence's other columns; each `UPDATE` says so in a
  `-- lost update review:` line. `scripts/arch-scan.py` over this directory is clean.
- **Package calls:** `invokeApi` processes; the Interactive Grid save and the loaders stay thin
  `executeCode` wrappers, each marked `-- thin wrapper: <reason>` (`framework/CAPABILITIES.md` KC-4).

## Grammar status & gotchas

Two different checks — `tests/upstream/validate-examples.sh` runs both:

- **Oracle's 26.1 local lint** (`apexlang-generation`, release 2026.09.21; Oracle calls it advisory
  "syntax hygiene"): the five `.apx` pass with exactly the documented diagnostics — the app-level
  breadcrumb entry, an Interactive Grid column `lov {}` block, and `type: link` on an Interactive
  Report column, which the compiler requires and the lint forbids (listed in
  `tests/upstream/expected-diagnostics.txt` and in the slice that reports them).
- **The compiler** (SQLcl `apex validate`, the contract of Oracle's `apexlang-compile`): with SQLcl
  26.2.0 on Oracle's 26.1 scaffold they **compile** (`Validation successful`). Three shapes it insists
  on: a breadcrumb region takes the theme's `@/title-bar` template (the breadcrumb itself
  `@/breadcrumb`); a `definedByDynamicAction` button has no `warnOnUnsavedChanges`; an `invokeApi`
  IN parameter needs `value { type: item  item: … }`, while an OUT one takes `ignoreOutput: false`
  and `value { item: … }` with no `type` (`framework/CAPABILITIES.md` UP-4). Lint-clean is still not
  "compiles": run both.

**Security.** Every page declares Oracle's baseline (`authorizationScheme: mustNotBePublicUser`,
`pageAccessProtection: argumentsMustHaveChecksum`, checksums on hidden and key items), and the
destructive actions — Delete employee, Reject absence — are under the role scheme
`@administration-rights`, the one Oracle's 26.1 scaffold ships. **Your** app supplies that scheme
in `shared-components/authorizations.apx`, or the examples' references are changed to the role
that may delete or reject in your app. `skills/apex-security/scripts/sec-scan.py` checks all of it.

Validate against **your** APEX version and SQLcl before `apex import`, and make sure the example page
numbers (30, 41, 42, 60, 62) and aliases don't collide with pages already in your app.

Non-obvious grammar rules these files respect (Oracle's 26.1 lint rejects violations):

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
grammar from these examples (or Oracle's `apexlang-inventory` and 26.1 templates), architecture from
the recipes. Identifiers (`hr_*` tables, `pkg_*` packages) match the recipes 1:1 so you
can read example and recipe side by side.
