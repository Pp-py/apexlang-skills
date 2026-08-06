---
name: apex-sentinel
description: Use when an APEXlang page or component was just imported or changed and needs confirming in the running app — verifying an Interactive Grid saves, a modal closes, a workflow transition lands, or a KPI/report renders — before claiming the change works.
---

# apex-sentinel

## Overview

`apex validate` proves **grammar**. `apex import` loads **metadata**. Neither proves the page **renders or works** — validate doesn't even resolve PL/SQL references (a process can call a package procedure that doesn't exist and still validate). The browser is the only gate that proves behavior.

**Principle: a change isn't done at "import succeeded." It's done when you've driven the running page in a browser and watched the expected behavior happen.**

This skill is the runtime verification gate for the APEXlang loop. It does **not** export/validate/import — that's the official `apex` skill. It pairs with `apexlang-architecture`: each check here confirms the behavior a construction recipe there promises (an editable IG routes writes through its package; a duplicate raises a *friendly* error; a modal closes; a KPI renders a number).

The official APEXlang package ships its own post-import check (`apexctl runtime verify-ui`), but it is **off by default, never blocks a successful import, and through the CLI only fetches the page's HTML** — it does not replace this gate; see *Relationship to `apexctl runtime verify-ui`* below.

**REQUIRED SUB-SKILL:** `apex` (official) for the (re-)import. **PAIRS WITH:** `apexlang-architecture`. **REINFORCES (optional, if installed):** `superpowers:verification-before-completion`.

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

### Operation vocabulary (tool-agnostic, mappable)

This skill names browser operations generically. Map them to your backend; both reference implementations are given.

| Operation | What it does | Playwright CLI via `pw.sh` (preferred) | Playwright MCP |
|---|---|---|---|
| navigate | open a URL | `pw.sh open <url>` / `pw.sh goto <url>` | `browser_navigate` |
| snapshot | capture the **accessibility tree** (rows, error regions, state as text) | `pw.sh snapshot` → YAML file on disk (Grep it), or `pw.sh find <text>` | `browser_snapshot` (streams into context — see Snapshot diet) |
| screenshot | pixel capture (fallback when the a11y tree is thin — e.g. canvas charts) | `pw.sh screenshot [ref]` | `browser_take_screenshot` |
| click | click an element | `pw.sh click <ref>` | `browser_click` |
| type | type into a revealed input | `pw.sh type <text>` / `pw.sh fill <ref> <text>` | `browser_type` |
| fill form | set several fields at once | `pw.sh fill` per field, or one `run-code` | `browser_fill_form` |
| eval | run JavaScript in the page, get the return value | `pw.sh eval <func> [ref]` | `browser_evaluate` |
| run code | run a multi-step Playwright snippet in ONE round-trip | `pw.sh run-code [code]` | `browser_run_code_unsafe` |
| handle dialog | accept/dismiss a browser dialog (beforeunload) | `pw.sh dialog-accept` / `pw.sh dialog-dismiss` | `browser_handle_dialog` |
| wait | wait for a condition/time | re-`snapshot` / `eval` a condition | `browser_wait_for` |

`pw.sh` is safe to call repeatedly and from any working directory — it pins the workspace, resolves the launcher, and reuses the live session instead of restarting the browser. Details in `setup.md` §0.

If your backend offers only screenshots (no accessibility snapshot), every "snapshot + assert" step degrades to **screenshot + visual assertion** — slower, but still real verification. The a11y snapshot is preferred, not mandatory. The browser itself is mandatory.

## Snapshot diet — why verification feels slow, and how not to

A full accessibility snapshot of an APEX page — especially one with an Interactive Grid — is tens of thousands of tokens, and a naive loop takes one after *every* action (Playwright MCP even attaches one to each action response by default). The check doesn't need any of that: it needs a handful of facts (did rows render? what does the error region say? did the badge flip?). Getting those facts costs tens of tokens if you ask the page directly. Rules, in order:

1. **Extract state with `eval` + the APEX JS API instead of snapshotting.** The runtime exposes everything the checks assert on:
   - grid rendered / row count: `apex.region('<static-id>').call('getViews').grid.model.getTotalRecords()`
   - item values: `apex.item('Px_Y').getValue()`
   - the error/success notification text: `document.querySelector('#t_Alert_Notification')?.innerText` (this is where a leaked `ORA-NNNNN:` prefix shows up)
   - a badge/cell's text: a one-line `querySelector(...).innerText`
2. **Snapshot only to discover refs** — when you must click something you haven't located yet (a toolbar button, an edit icon). With the CLI the snapshot lands on disk: **Grep the YAML for the element, don't read the file whole.** With the MCP, take the one snapshot, note the refs you need, and don't take another until the page structurally changes.
3. **Batch multi-step mechanics into one round-trip.** Login (navigate → fill → click) and the IG add-row dance (Add Row → dblclick cell → type → next cell → Save) are fixed sequences that need no reasoning between steps: run them as one `run code` snippet (MCP: `browser_run_code_unsafe` with `getByRole` locators) or one batched CLI sequence, instead of 6–10 round-trips each dragging a snapshot.
4. **Assert cheaply.** "Text X is on the page" is `wait` for text (MCP: `browser_wait_for`; CLI: `pw.sh find <text>`, which searches the snapshot and returns only matching nodes with context) — not a fresh full snapshot. If your Playwright MCP has the `verify` capability enabled, `browser_verify_text_visible`/`browser_verify_element_visible` are purpose-built for this.

The checks in `checks/` are written against these rules; `setup.md` §0 configures the backend so the defaults don't fight you.

## The loop

1. **Connect** — resolve runtime URL, log in, hold the session. See `setup.md` (this is where the friction is — do it first).
2. **Navigate** to the changed page, preserving the session (append `?session=<token>`; a bare `goto` drops it → login).
3. **Read the page state cheaply** — `eval` the specific facts you need (see *Snapshot diet*); take a full snapshot only to discover refs you must click. Screenshot only when the text tree is insufficient (canvas charts).
4. **Exercise** the archetype's behavior (interact + assert, fixed sequences batched into one round-trip) — see `checks/`.
5. **On fail**, report the user-visible symptom + likely owning layer, fix via the `apex` skill, re-import, re-verify. **On pass**, confirm the data side with SQLcl when a write was involved.

## Checks (by archetype)

| Page archetype | Check |
|---|---|
| Editable Interactive Grid | `checks/editable-ig.md` |
| Master + create/edit modal | `checks/modal-crud.md` |
| Workflow / state transition | `checks/workflow-state.md` |
| Dashboard / analytical report | `checks/dashboard-report.md` |

**Read `setup.md` before any check** — base-URL/TLS resolution, login, session preservation, and IG inline-edit mechanics are non-obvious and block everything.

## Prefer non-mutating checks

Verify the **rejection/negative path** first (duplicate code → error, illegal transition → blocked): it exercises the full write path + business rule **without persisting test data**. When you must write, use an obvious throwaway value and clean up; confirm the DB with SQLcl (`sql -name <conn>`) — UI "saved" and the row existing are two different claims.

## When NOT to use

- Backend-only changes with no page to drive (pure PL/SQL or view work) — there's nothing to render.
- No running instance reachable — see Prerequisites; stop and report, don't fake it.
- Grammar / validate / import / round-trip questions — that's the official `apex` skill.
- Generic "did I finish?" checks with no APEX runtime — that's `superpowers:verification-before-completion`.

## Relationship to `apexctl runtime verify-ui`

The APEXlang package ships its own post-import browser check (`apexctl … runtime verify-ui`), **opt-in** via `--require-runtime-verification` — without that flag the runtime roundtrip records *"Post-import runtime verification is disabled by default."* Its own contract (`references/ops/runtime-gates.md` §Canonical Validation 10–11) places it **after** `import_status = pass` and treats its findings as **diagnostics**: *"do not rewrite a successful import to fail."* The implementation agrees — a non-zero verification result only appends a note and a recommended next action; the roundtrip still exits 0.

That is the shallow lane, and it agrees with this skill's sequencing — verification is post-import, never a pre-import gate (the pre-import gate is `apex-sync-guard`). Where they differ is **scope**: `verify-ui` advertises a `chrome-devtools-mcp` provider, but the CLI path never wires one up, so every run falls back to HTTP — it fetches the page's HTML, checks status/redirects/expected text, and reports *"Console inspection is unavailable in the HTTP fallback provider."* It records that a page responded; it never drives the UI. This skill holds one logged-in APEX session across the whole loop, drives the archetype's actual interaction (save the grid, close the modal, land the transition), and confirms the row in the database afterwards. If your team already runs `verify-ui`, keep it — and still run this loop before saying the change works, because "reported no findings" is not "I saw it save".

## Red flags — you have NOT verified

- You answered "done / it works" after `validate`/`import` without opening the browser.
- **You changed the URL's scheme, port or host to get past a cert or connection error** — e.g. dropping to `http://…:8080` because `https://…:8443` threw `ERR_CERT_AUTHORITY_INVALID`. That verifies a different transport than the one under test, and hides exactly the class of defect (mixed content, secure-cookie, proxy-only rewrite) that only appears on the real one. Fix the backend's TLS setting (`setup.md` §1) or stop and report.
- You asserted on an optimistic client state without a reload or a SQL read.
- You saw "an error appeared" and stopped — without checking it's the *right*, *friendly* error (a raw `ORA-NNNNN:` prefix leaking to the user is a defect, see `checks/editable-ig.md`).
- You only tested the happy path; the rejection path is unverified.
