---
name: apex-ux
description: Use when an APEXlang page is designed, changed or reviewed for UI quality and accessibility — labels and accessible names, button hierarchy, destructive-action confirmation, empty states, keyboard and dialog focus, inline styles, dashboards, forms, browse and detail pages — and before calling its UI done.
---

# apex-ux

## Contract

- **Does:** judges an APEXlang page's UI against a catalog of criteria with IDs — from WCAG 2.2 AA, Oracle's 26.1 policies and Universal Theme — statically over the `.apx` and at runtime in the browser.
- **Use when:** a page is designed, changed or reviewed, and before anyone says its UI is done.
- **Decides:** whether each criterion holds — never grammar (Oracle's compiler), never where logic lives (`apexlang-architecture`), never whether the page works (`apex-sentinel`).
- **Output:** a `ui-result` (`framework/schemas/ui-result.schema.json`) per run: per criterion `PASS` · `FAIL` · `NOT_RUN`, plus advisories that never change the verdict.
- **Evidence:** per criterion, the `.apx` lines it rests on, or the saved browser and axe-core output with its sha256 under the task's evidence dir (`framework/EVIDENCE.md`).
- **Gate:** UI (`framework/GATES.md`), after Runtime — required for an app with `"uiGate": true` in `apex-sync.json`, opt-in until 1.0.0; when required, a non-PASS blocks.
- **Interface:** the criteria in `criteria/`; `python3 scripts/ux-scan.py [--app X] [--task <id>] <file-or-dir>…` for the static FAIL criteria. `python3 scripts/ux-check.py [--app X] [--env E] [--task <id>] [--dialog <selector>]…` for the runtime ones, through `apex-sentinel`'s `pw.sh` with a vendored axe-core.

## Status — what exists

| Piece | State |
|---|---|
| Criteria catalog with IDs (`criteria/`) | **built** (UX-2) |
| Static scan over `.apx` | **built** (UX-3) for the five static `FAIL` criteria — see §Static scan; the static `ADVISE` ones are still read by hand |
| Runtime checks: axe-core, dialog focus | **built** (UX-4) for the runtime `FAIL` criteria — see §Runtime checks |
| Runtime `ADVISE` checks: reflow, focus visible, target size | not built — apply them by hand through `pw.sh` |
| `ui-result` schema, UI gate, manifest enums | **built** (UX-5) — see §The UI gate |

Until the scripts exist, a review cites the criterion IDs it checked and says which it did not. A criterion nobody exercised is `NOT_RUN`, never PASS.

## Static scan

`python3 scripts/ux-scan.py <file-or-dir>…` (python3 only; without it the scan is BLOCKED). It checks
`UX-ITEM-NAME`, `UX-CONTROL-NAME`, `UX-DESTRUCTIVE-CONFIRM`, `UX-NO-INLINE-STYLE` and
`UX-NO-COMPOSED-CLASS`, and prints JSON per criterion with the file and line of each finding
(a `ui-result`, scope `static`). Exit 0 PASS · 1 FAIL · 2 BLOCKED · 3 UNKNOWN — a
file it could not parse got no item or button checks, so re-read it by hand; never treat 3 as PASS.

What it does not establish: the runtime half of `UX-ITEM-NAME` and `UX-CONTROL-NAME` (the name
the browser actually computes), confirmation done by a dynamic action instead of a
`confirmation` block (reported as FAIL — check it, do not delete the finding), and every
`ADVISE` criterion.

## Runtime checks

After `pw.sh [--app X] [--env E] login` and `pw.sh goto <page>`, run
`python3 scripts/ux-check.py [--app X] [--env E] [--dialog <selector>]… [--raw <evidence-dir>/raw/ux-<alias>/axe.json]`
on the page the session holds. It runs axe-core (`vendor/`, pinned in `vendor/axe-core.lock.json`)
in every frame, on the page and with each dialog open, for `UX-AXE-SERIOUS`, `UX-ITEM-NAME` and
`UX-CONTROL-NAME`. For each `--dialog` opener (a selector pw.sh can click: `#id`, `text=Edit`) it
checks `UX-DIALOG-FOCUS`: focus moves in, Tab and Shift+Tab stay in, Esc closes, focus returns.
No `--dialog` leaves that criterion `NOT_RUN`. Minor violations and axe's "incomplete" are
advisories, and so is a finding in markup APEX itself renders that `oracle-owned.json` lists for
the APEX version the page reports (`UX-ORACLE-OWNED`; entries are measured, one version each). A `ui-result` (scope `runtime`) on stdout, never a node's HTML or a session id;
`--raw` keeps axe's full output with its sha256. Exit 0 PASS · 1 FAIL · 2 BLOCKED (axe missing or
not matching its lock, opener not found, a login page) · 3 UNKNOWN (dead session, no verdict).

What it does not establish: anything on a page or dialog it was not pointed at, a dialog's
behaviour after the keyboard has moved through it (axe runs as it opens), and every `ADVISE`
runtime criterion except the axe advisories.

Updating axe-core: take a release at least two weeks old, check the npm tarball against its
`integrity`, copy `axe.min.js` and its licences into `vendor/axe-core/` unchanged, and update
version, tarball, integrity and sha256 in the lock. `tests/integration/ux-check.sh` checks the
file against the lock.

## The UI gate

With `--task <id>` both scripts also write their `ui-result` under the task's evidence dir
(`evidenceDir` in `apex-sync.json`, default `.apex-evidence/`): `ui-<alias>-static.json`, and
`ui-<alias>-runtime-<page>.json` per page, with axe's raw output in `raw/ui-<alias>/`. `--app` names
the app; with one app in `apex-sync.json` it may be left out. An app with `environments` also
takes `--env` (the one the page belongs to); its files are keyed `<alias>.<env>`. The gate passes on the static
result PASS and a runtime result PASS for each page the change touched; a consumer cites all of
them in the manifest (`framework/GATES.md` §Order). Run the static scan over the app's `.apx` and
`ux-check.py` on every page and dialog the change touched — a page not checked is not covered.

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

Where `apexlang-architecture` states a data-side rule (the closed set of classes, the link's form), a criterion here cites it and checks it — it never restates it. A recipe in `apexlang-architecture` says how a page is built; the archetype file here says how its UI is judged. The mapping is in `criteria/README.md`.

## How to use it now

1. Pick the archetype file for the page (`criteria/README.md` §Archetypes) and always `criteria/common.md`.
2. Run the static scan and the runtime checks; for each other `static` criterion, read the page's `.apx`; for each other `runtime` one, drive the page through `apex-sentinel`'s `pw.sh`; for each `manual` one, look, and say what you looked at.
3. Report per criterion ID: PASS, FAIL with what was seen, or NOT_RUN with why. Advisories go in a separate list.

## Red flags — stop

- "It looks fine" without criterion IDs.
- Calling a page accessible because axe found nothing.
- Hiding a status, an action or a field to make a criterion pass.
- Downgrading a `FAIL` criterion to an advisory for this page — severities change in the catalog, for every page, or not at all.
- Adding to `oracle-owned.json` a defect your `.apx` causes, or one not measured on that APEX version.
