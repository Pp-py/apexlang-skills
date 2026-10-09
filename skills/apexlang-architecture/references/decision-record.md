# The decision record

Before the `.apx` and the package are written, record what was decided — an
`architecture-result` (`framework/schemas/architecture-result.schema.json`, experimental) at
`<evidenceDir>/<task>/architecture.json`. It is the Architecture gate's verdict, and the
record alone never PASSes: each decision rests on evidence, and the red-flag scan must have
run.

## Inputs — or BLOCKED

A decision needs the **requirement** (what the screen or operation must do), the **app
context** (which app, its existing packages and the entity each owns) and the **schema**
(tables, constraints, foreign keys). An input that would change a decision and that nobody
has given goes in `missingInputs`, and the result is BLOCKED until someone answers. Ask;
never fill the gap with a plausible guess.

## One decision per rule and per operation

Run the procedures of `../package-boundaries.md` and record the first branch that matched:

| Subject | Procedure | Branch → layer |
|---|---|---|
| a **rule** — uniqueness, a guard, a required field | A | A1 → `constraint` · A2 → `apx` · A3 → the package that owns the operation |
| an **operation** — a save, a transition, a wizard's last step | B | B0 → `read` · B1 → `entity` · B2 → `entity-sequence` or `flow` · B3 → `integration` |

```json
{ "subject": "saving a sector from the grid", "type": "operation", "branch": "B1",
  "layer": "entity", "package": "pkg_sectors",
  "evidence": [ { "kind": "file", "path": "db/pkg_sectors.pkb", "sha256": "<sha256 of that file>" } ] }
```

## The red-flag scan

Run it on the app's source and record each command, with its exit code, as evidence — an
empty `redFlags` means nothing unless the scan ran. Each hit is reviewed, then recorded with
its code and path:

| Red flag (`../SKILL.md`) | `code` | How to look |
|---|---|---|
| Automatic Row Processing, or a region bound to a table for writing | `AUTOMATIC_ROW_PROCESSING` | `grep -rnE 'autoRowProcessing\|formAutoRowProcessing\|interactiveGridAutoRowProcessing' <app-dir>` — the three process types of Oracle's inventory |
| DML in a page process | `DML_IN_PAGE_PROCESS` | `grep -rniE '\b(insert\|update\|delete\|merge)\b' <app-dir>/pages` — then read each hit: a package call is fine, a statement is not |
| a rule a job or REST call could bypass | `RULE_OUTSIDE_PACKAGE` | each page validation against the owning package's guards |
| a package writing a table it does not own | `FOREIGN_TABLE_WRITE` | the DML in each package body against its entity and satellites |
| a `_flow` package issuing DML | `FLOW_ISSUES_DML` | `grep -niE '\b(insert\|update\|delete\|merge)\b' <pkg>_flow` bodies |
| a `_flow` around one entity | `FLOW_WRAPS_ONE_ENTITY` | each `_flow` against Test 2 of `../package-boundaries.md` |
| an update by primary key alone | `NO_VERSION_TOKEN` | each write-path `update` against `../back-end-conventions.md` §7 |

## Which status

PASS — at least one decision, every decision on evidence, the scan ran and found nothing,
nothing missing. FAIL — the scan found a red flag. BLOCKED — an input is missing.
UNKNOWN — the scan could not run (no source to read, a command that failed).
