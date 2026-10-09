# Operation vocabulary (tool-agnostic, mappable)

This skill names browser operations generically. Map them to your backend; both reference implementations are given.

| Operation | What it does | Playwright CLI via `pw.sh` (preferred) | Playwright MCP |
|---|---|---|---|
| navigate | open a URL | `pw.sh open <url>` / `pw.sh goto <url>` | `browser_navigate` |
| login | sign the test user into the runtime app, once, and hold it | `pw.sh login` → prints the session token | navigate + fill + click, batched into one `browser_run_code_unsafe` |
| snapshot | capture the **accessibility tree** (rows, error regions, state as text) | `pw.sh snapshot` → YAML file on disk (Grep it), or `pw.sh find <text>` | `browser_snapshot` (streams into context — see Snapshot diet) |
| screenshot | pixel capture (fallback when the a11y tree is thin — e.g. canvas charts) | `pw.sh screenshot [ref]` | `browser_take_screenshot` |
| click | click an element | `pw.sh click <ref>` | `browser_click` |
| type | type into a revealed input | `pw.sh type <text>` / `pw.sh fill <ref> <text>` | `browser_type` |
| fill form | set several fields at once | `pw.sh fill` per field, or one `run-code` | `browser_fill_form` |
| eval | run JavaScript in the page, get the return value | `pw.sh eval <func> [ref]` | `browser_evaluate` |
| run code | run a multi-step Playwright snippet in ONE round-trip | `pw.sh run-code [code]` | `browser_run_code_unsafe` |
| handle dialog | accept/dismiss a browser dialog (beforeunload) | `pw.sh dialog-accept` / `pw.sh dialog-dismiss` | `browser_handle_dialog` |
| wait | wait for a condition/time | re-`snapshot` / `eval` a condition | `browser_wait_for` |

`pw.sh` is safe to call repeatedly and from any working directory — it pins the workspace, resolves the launcher, and reuses the live session instead of restarting the browser. Details in `../setup.md` §0.

If your backend offers only screenshots (no accessibility snapshot), every "snapshot + assert" step degrades to **screenshot + visual assertion** — slower, but still real verification. The a11y snapshot is preferred, not mandatory. The browser itself is mandatory.
