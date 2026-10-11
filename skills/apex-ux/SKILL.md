---
name: apex-ux
description: Use when an APEXlang page is designed, changed or reviewed for UI quality and accessibility — labels and accessible names, button hierarchy, destructive-action confirmation, empty states, keyboard and dialog focus, inline styles, dashboards, forms, browse and detail pages — and before calling its UI done.
---

# apex-ux

## Contract

- **Does:** judges an APEXlang page's UI against a catalog of criteria with IDs — from WCAG 2.2 AA, Oracle's 26.1 policies and Universal Theme — statically over the `.apx` and at runtime in the browser.
- **Use when:** a page is designed, changed or reviewed, and before anyone says its UI is done.
- **Decides:** whether each criterion holds — never grammar (Oracle's compiler), never where logic lives (`apexlang-architecture`), never whether the page works (`apex-sentinel`).
- **Output:** per criterion `PASS` · `FAIL` · `NOT_RUN`, plus advisories that never change the verdict. As a gate result (`ui-result`): Phase 3, UX-5 — not built yet.
- **Evidence:** per criterion, the `.apx` lines it rests on, or the saved browser and axe-core output with its sha256 under the task's evidence dir (`framework/EVIDENCE.md`).
- **Gate:** UI — opt-in per app until 1.0.0; when enabled, a non-PASS blocks. Not in `framework/GATES.md` yet (UX-5).
- **Interface:** the criteria in `criteria/`; `python3 scripts/ux-scan.py <file-or-dir>…` for the static FAIL criteria. The runtime checks through `apex-sentinel`'s `pw.sh` with a vendored axe-core (UX-4) are not built yet.

## Status — what exists

| Piece | State |
|---|---|
| Criteria catalog with IDs (`criteria/`) | **built** (UX-2) |
| Static scan over `.apx` | **built** (UX-3) for the five static `FAIL` criteria — see §Static scan; the static `ADVISE` ones are still read by hand |
| Runtime checks: axe-core, keyboard and dialog focus, viewport | not built (UX-4) — apply the `runtime` criteria by hand through `pw.sh` |
| `ui-result` schema, gate, manifest enums | not built (UX-5) |

Until the scripts exist, a review cites the criterion IDs it checked and says which it did not. A criterion nobody exercised is `NOT_RUN`, never PASS.

## Static scan

`python3 scripts/ux-scan.py <file-or-dir>…` (python3 only; without it the scan is BLOCKED). It checks
`UX-ITEM-NAME`, `UX-CONTROL-NAME`, `UX-DESTRUCTIVE-CONFIRM`, `UX-NO-INLINE-STYLE` and
`UX-NO-COMPOSED-CLASS`, and prints JSON per criterion with the file and line of each finding
(provisional format until `ui-result`, UX-5). Exit 0 PASS · 1 FAIL · 2 BLOCKED · 3 UNKNOWN — a
file it could not parse got no item or button checks, so re-read it by hand; never treat 3 as PASS.

What it does not establish: the runtime half of `UX-ITEM-NAME` and `UX-CONTROL-NAME` (the name
the browser actually computes), confirmation done by a dynamic action instead of a
`confirmation` block (reported as FAIL — check it, do not delete the finding), and every
`ADVISE` criterion.

## A PASS is not "WCAG compliant"

Automated checks find a minority of accessibility failures. A UI PASS establishes that every `FAIL`-severity criterion that was run held — not that the page conforms to WCAG 2.2 AA. Conformance needs the `manual` criteria too, and an audit. Never write "accessible" or "WCAG compliant" on the strength of this skill alone.

## Sources, and which wins

1. **WCAG 2.2 AA** (W3C Recommendation) — normative for accessibility.
2. **Oracle's 26.1 generation policies** (`apex@oracle-skills`, the revision in `framework/oracle-skills.lock.json`) — for how APEX expresses it. Anchors in `tests/upstream/citations.md`. They exist only for 26.1; the criteria are version-independent.
3. **Universal Theme** — the classes, templates and template options that already solve a problem.
4. **This repo** — `apexlang-architecture/ui-contracts.md` for what the SQL projects.
5. **An example pattern catalog** — illustrates, never decides.

Grammar keeps its own order (`framework/PRINCIPLES.md` P6): no criterion here makes the compiler wrong.

### The pattern catalog is an example, never a requirement

Oracle's **UX Pattern Catalog** application shows what the patterns look like. Where a criterion draws on it, the criterion is written out in full in this repo and cites the catalog page and version (`ex: CAT 26.1.6 <page>`), so it holds without the app. **This skill never needs a catalog instance to run** — a running copy (in a lab, on any instance) is a convenience for looking, nothing more. Where the catalog's own pages break a criterion (it shows a Delete link with no confirmation), the criterion stands and says so.

## Boundaries

| Owner | What |
|---|---|
| `apexlang-architecture` | what the data layer projects for the UI (`ui-contracts.md`) — state classes, keys, never URLs or markup |
| `apex-sentinel` | that the page works; it owns the browser driver `pw.sh` |
| **`apex-ux`** | whether the UI is usable and accessible — the criteria, the static scan, the runtime UI checks (through `pw.sh`, never a copy of it) |

A recipe in `apexlang-architecture` says how a page is built; the archetype file here says how its UI is judged. The mapping is in `criteria/README.md`.

## How to use it now

1. Pick the archetype file for the page (`criteria/README.md` §Archetypes) and always `criteria/common.md`.
2. Run the static scan; for each other `static` criterion, read the page's `.apx`; for each `runtime` one, drive the page through `apex-sentinel`'s `pw.sh`; for each `manual` one, look, and say what you looked at.
3. Report per criterion ID: PASS, FAIL with what was seen, or NOT_RUN with why. Advisories go in a separate list.

## Red flags — stop

- "It looks fine" without criterion IDs.
- Calling a page accessible because axe found nothing.
- Hiding a status, an action or a field to make a criterion pass.
- Downgrading a `FAIL` criterion to an advisory for this page — severities change in the catalog, for every page, or not at all.
