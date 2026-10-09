# Snapshot diet — why verification feels slow, and how not to

A full accessibility snapshot of an APEX page — especially one with an Interactive Grid — is tens of thousands of tokens, and a naive loop takes one after *every* action (Playwright MCP even attaches one to each action response by default). The check doesn't need any of that: it needs a handful of facts (did rows render? what does the error region say? did the badge flip?). Getting those facts costs tens of tokens if you ask the page directly. Rules, in order:

1. **Extract state with `eval` + the APEX JS API instead of snapshotting.** The runtime exposes everything the checks assert on:
   - grid rendered / row count: `apex.region('<static-id>').call('getViews').grid.model.getTotalRecords()`
   - item values: `apex.item('Px_Y').getValue()`
   - the error/success notification text: `document.querySelector('#t_Alert_Notification')?.innerText` (this is where a leaked `ORA-NNNNN:` prefix shows up)
   - a badge/cell's text: a one-line `querySelector(...).innerText`
2. **Snapshot only to discover refs** — when you must click something you haven't located yet (a toolbar button, an edit icon). With the CLI the snapshot lands on disk: **Grep the YAML for the element, don't read the file whole.** With the MCP, take the one snapshot, note the refs you need, and don't take another until the page structurally changes.
3. **Batch multi-step mechanics into one round-trip.** Login (navigate → fill → click) and the IG add-row dance (Add Row → dblclick cell → type → next cell → Save) are fixed sequences that need no reasoning between steps: run them as one `run code` snippet (MCP: `browser_run_code_unsafe` with `getByRole` locators) or one batched CLI sequence, instead of 6–10 round-trips each dragging a snapshot.
4. **Assert cheaply.** "Text X is on the page" is `wait` for text (MCP: `browser_wait_for`; CLI: `pw.sh find <text>`, which searches the snapshot and returns only matching nodes with context) — not a fresh full snapshot. If your Playwright MCP has the `verify` capability enabled, `browser_verify_text_visible`/`browser_verify_element_visible` are purpose-built for this.

The checks in `../checks/` are written against these rules; `../setup.md` §0 configures the backend so the defaults don't fight you.
