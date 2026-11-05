---
name: apex-sentinel
description: Use when an APEXlang page or component was just imported or changed and needs confirming in the running app — verifying an Interactive Grid saves, a modal closes, a workflow transition lands, or a KPI/report renders — before claiming the change works.
---

# apex-sentinel

## Contract

- **Does:** drives the running page in a real browser, as a verified test user, through the archetype's pass criteria — and reads the data side back with SQLcl.
- **Use when:** a page was imported or changed and someone is about to say it works.
- **Decides:** whether each required criterion holds on the running app — never grammar, never sync safety.
- **Output:** a `runtime-result` (`<evidenceDir>/<task>/runtime-<alias>[.<env>].json`): PASS · FAIL · BLOCKED (no browser, login not verified) · UNKNOWN — `references/runtime-result.md`; and, from `scripts/pkg-check.py`, a `package-result` (`package-<alias>[.<env>].json`).
- **Evidence:** per criterion, saved `eval` output or snapshots under `raw/runtime-<alias>[.<env>]/` with their sha256, and SQL reads — saved and written through `framework/scripts/evidence.py`, never by hand.
- **Gate:** Runtime (`framework/GATES.md`) — discipline, no hook; and Package, opt-in per app (`packageGate`) until 1.0.0.
- **Interface:** `scripts/pw.sh [--app <alias>] [--env <name>] login|open|goto|eval|run-code|snapshot|find|…|close-all` (exit 0 · 2 refused / login unverified · 3 recovered on a logged-out page); `scripts/pkg-check.py [--app <alias>] [--env <name>] [--task <id>] <file-or-dir>…` (exit 0 PASS · 1 FAIL · 2 BLOCKED · 3 UNKNOWN)

## Overview

`apex validate` proves **grammar**. `apex import` loads **metadata**. Neither proves the page **renders or works** — validate doesn't even resolve PL/SQL references (a process can call a package procedure that doesn't exist and still validate; the Package gate below looks it up). The browser is the only gate that proves behavior.

**Principle: a change isn't done at "import succeeded." It's done when you've driven the running page in a browser and watched the expected behavior happen.**

This skill is the runtime verification gate for the APEXlang loop. It does **not** export/validate/import — that's Oracle's APEXlang skills (`apexlang-compile`, `apexlang-deploy`). It pairs with `apexlang-architecture`: each check here confirms the behavior a construction recipe there promises (an editable IG routes writes through its package; a duplicate raises a *friendly* error; a modal closes; a KPI renders a number).

Oracle's 26.1 `apexlang-generation` ships its own post-import check (`apexctl runtime verify-ui`; 26.2 ships none), but it is **off by default, never blocks a successful import, and through the CLI only fetches the page's HTML** — it does not replace this gate (`references/oracle-verify-ui.md`).

**REQUIRED SUB-SKILL:** Oracle's APEXlang skills for the (re-)import, behind `apex-sync-guard`. **PAIRS WITH:** `apexlang-architecture`. **REINFORCES (optional, if installed):** `superpowers:verification-before-completion`.

## Prerequisites — hard, this skill does NOT degrade gracefully

The browser IS the gate. This skill requires a **browser-automation tool**. The two backends are **ranked, not interchangeable** — take the first that runs:

1. **Playwright CLI** (`@playwright/cli`), driven through `scripts/pw.sh` in this skill's directory — **use this whenever it runs at all.** A daemon keeps one browser alive across every check (the APEX login and session token survive the whole loop), and snapshots are written to **disk** as YAML for you to Grep — not streamed into your context (roughly 4× cheaper per check). Decisively: on a self-signed APEX instance its TLS bypass is a **config file the wrapper writes for you, in-loop**.
2. **A browser-automation MCP** — Playwright MCP is the reference; any MCP exposing navigate / accessibility-snapshot / click / type / dialog-handling works. A legitimate fallback, but its TLS bypass and snapshot settings are **server-launch flags you cannot change mid-loop** — a cert wall here has no in-loop fix, only a config edit plus a restart.

Also requires **SQLcl** (`sql -name <conn>`) for the data-side confirmation.

**Step 0 — before the loop:** resolve a **launcher**, not a binary. `which playwright-cli` is **not** the test — the CLI is very often available only through `npx`, and stopping at a missing global binary is the single most common reason this skill ends up on the slower MCP path:

```bash
# prints the resolved launcher, or nothing if the CLI genuinely cannot run
command -v playwright-cli >/dev/null 2>&1 && playwright-cli --version >/dev/null 2>&1 \
  && echo "playwright-cli" \
  || { npx -y @playwright/cli --version >/dev/null 2>&1 && echo "npx -y @playwright/cli"; }
```

Branch on the **exit code, never on the output text** — npx prints an "update available" banner that reads like a failure but is not one. `scripts/pw.sh` already does exactly this; just use it. Only if that probe resolves nothing may you fall back to a browser MCP.

If **neither** backend is available, **STOP and report**: "runtime verification impossible — no browser automation available." Do **not** substitute `apex validate`/`import` as proof of behavior; they prove grammar/metadata, not rendering. Faking verification is the exact failure this skill exists to prevent — so here, absence of the tool means *abort*, never *degrade*.

### Operation vocabulary

This skill names browser operations generically — navigate, login, snapshot, screenshot, click, type, fill form, eval, run code, handle dialog, wait — and maps each to the Playwright CLI (through `pw.sh`) and to Playwright MCP in `references/operations.md`. `pw.sh` is safe to call repeatedly and from any directory: it pins the workspace (one per project and app), resolves the launcher, and reuses the live session instead of restarting the browser. A backend with screenshots but no accessibility snapshot still verifies — slower. The browser itself is mandatory.

## Snapshot diet — why verification feels slow, and how not to

A full accessibility snapshot of an APEX page is tens of thousands of tokens; a check needs a handful of facts. **Ask the page with `eval` and the APEX JS API** (`apex.region(…).call('getViews').grid.model.getTotalRecords()`, `apex.item('Px_Y').getValue()`, `#t_Alert_Notification`), **snapshot only to discover refs** (and Grep the YAML on disk, never read it whole), **batch fixed sequences** (login, the IG add-row dance) into one `run code` round-trip, and **assert cheaply** (`pw.sh find <text>`, a wait for text). The rules and their reasons: `references/snapshot-diet.md`.

## The loop

1. **Connect** — resolve runtime URL, log in (`pw.sh login`, with the test user configured per `setup.md` §2), hold the session. See `setup.md` (this is where the friction is — do it first).
2. **Navigate** to the changed page, preserving the session (append `?session=<token>`; a bare `goto` drops it → login).
3. **Read the page state cheaply** — `eval` the specific facts you need (see *Snapshot diet*); take a full snapshot only to discover refs you must click. Screenshot only when the text tree is insufficient (canvas charts).
4. **Exercise** the archetype's behavior (interact + assert, fixed sequences batched into one round-trip) — see `checks/`.
5. **On fail**, report the user-visible symptom + likely owning layer, fix it (`.apx` through Oracle's APEXlang skills, logic in the package), re-import through the sync gate, re-verify. **On pass**, confirm the data side with SQLcl when a write was involved.
6. **Record the verdict** — one entry per criterion ID, each on saved evidence, in a `runtime-result` (`references/runtime-result.md`). A criterion you did not exercise is NOT_RUN, never PASS.

## Checks (by archetype)

| Page archetype | Check |
|---|---|
| Editable Interactive Grid | `checks/editable-ig.md` |
| Master + create/edit modal | `checks/modal-crud.md` |
| Full-page / drawer form | `checks/form-page.md` |
| Split view (list or tree + detail) | `checks/split-view.md` |
| Browse & faceted search | `checks/browse-search.md` |
| Workflow / state transition | `checks/workflow-state.md` |
| Dashboard / analytical report | `checks/dashboard-report.md` |

**Read `setup.md` before any check** — base-URL/TLS resolution, login, session preservation, and IG inline-edit mechanics are non-obvious and block everything.

## The Package gate — no browser

Where the app sets `packageGate`, run `scripts/pkg-check.py --app X [--env E] --task <id> <the .apx files or directories>` after Validation and before Sync. It reads, with `SELECT`s only, whether the packages and procedures the `.apx` names (`invokeApi` processes and workflow activities, named-notation calls in its sql/plsql blocks) exist in the app's parsing schema, are `VALID` with no compile error, and declare the procedure called: criteria `PKG-EXISTS`, `PKG-COMPILED`, `PKG-PROC-EXISTS`, all three needed for a PASS. It never runs DDL or recompiles; a `protected` environment may be read. FAIL: absent or broken. UNKNOWN: `INVALID` with no error to read, not visible to the session's user, a synonym, a name it cannot follow: compile through your usual database path and run it again, never read it as PASS. BLOCKED: nothing to look up, no SQLcl, no connection, the app not in the database yet. PASS is not "the PL/SQL is right": the walkthrough above is. Criteria, reasons and limits: `checks/package.md`; connection: `setup.md` §5.

## Prefer non-mutating checks

Verify the **rejection/negative path** first (duplicate code → error, illegal transition → blocked): it exercises the full write path + business rule **without persisting test data**. When you must write, use an obvious throwaway value and clean up; confirm the DB with SQLcl (`sql -name <conn>`) — UI "saved" and the row existing are two different claims.

## When NOT to use

- Backend-only changes with no page to drive (pure PL/SQL or view work) — there's nothing to render (the Package gate still reads the names a `.apx` calls, and a change naming none is `--skip package:<reason>`).
- No running instance reachable — see Prerequisites; stop and report, don't fake it.
- Grammar / validate / import / round-trip questions — that's Oracle's APEXlang skills.
- Generic "did I finish?" checks with no APEX runtime — that's `superpowers:verification-before-completion`.

## Relationship to `apexctl runtime verify-ui`

Oracle's opt-in post-import check fetches the page's HTML through the CLI and reports diagnostics; it never drives the UI and never fails an import. Keep it if your team runs it — and still run this loop before saying the change works: "reported no findings" is not "I saw it save" (`references/oracle-verify-ui.md`).

## Red flags — you have NOT verified

- You answered "done / it works" after `validate`/`import` without opening the browser.
- **You changed the URL's scheme, port or host to get past a cert or connection error** — e.g. dropping to `http://…:8080` because `https://…:8443` threw `ERR_CERT_AUTHORITY_INVALID`. That verifies a different transport than the one under test, and hides exactly the class of defect (mixed content, secure-cookie, proxy-only rewrite) that only appears on the real one. Fix the backend's TLS setting (`setup.md` §1) or stop and report.
- You asserted on an optimistic client state without a reload or a SQL read.
- You saw "an error appeared" and stopped — without checking it's the *right*, *friendly* error (a raw `ORA-NNNNN:` prefix leaking to the user is a defect, see `checks/editable-ig.md`).
- You only tested the happy path; the rejection path is unverified.
