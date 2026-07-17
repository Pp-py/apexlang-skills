# Setup — connecting a browser backend to an APEX runtime

Pick and configure the backend once (§0), then get the four APEX-specific blockers right (§1–§4).

## 0. Choose and configure the backend

### Playwright CLI (recommended)

```bash
npm install -g @playwright/cli
playwright-cli -s apex open <base-url>    # -s apex = a named, isolated browser session
```

Why it's the fast path: a daemon keeps the browser (and the APEX login + session token) alive across every check in the loop, and each command writes its accessibility snapshot to disk (`.playwright-cli/page-<timestamp>.yml`) instead of streaming it into your context. **Grep those YAML files for the element/text you need — never read one whole**; an APEX IG page's tree is tens of thousands of tokens. Use `-s apex` for all commands so parallel work can't steal the session; `close-all` when the loop is done. (No global install needed: `npx -y @playwright/cli <cmd>` works too.)

**Self-signed TLS (verified):** unlike Playwright MCP, the CLI rejects self-signed certs by default (`net::ERR_CERT_AUTHORITY_INVALID`). Fix it in its config file — `.playwright/cli.config.json` **relative to the cwd you run commands from**:

```json
{ "browser": { "contextOptions": { "ignoreHTTPSErrors": true } } }
```

Multi-step sequences (login, the IG add-row dance) go through `run-code` — one call runs a whole Playwright snippet (`await page.getByRole(...)...`), replacing 6–10 stepwise commands.

### Playwright MCP (if that's what the session has connected)

Works, but its defaults fight the loop: it attaches a **full page snapshot to every action response**, which on APEX pages is the single biggest cost (this is what "navigation feels slow" almost always is). Fix it in the MCP config — same spirit as the TLS advice in §1, never in the loop:

- `--image-responses omit` — don't stream screenshots you didn't ask for.
- `--caps=verify` — enables `browser_verify_text_visible` / `browser_verify_element_visible` etc.: assertions that don't return a snapshot.
- `--storage-state <path>` / `--save-session` — persist cookies so a restarted browser doesn't force a fresh APEX login.
- `--headless` — no rendering overhead.
- Newer versions: `--snapshot-mode` (if available) to stop attaching full snapshots to action responses.

Whichever backend: the per-check technique for keeping context small is `SKILL.md` §"Snapshot diet" — targeted `eval` extraction, snapshots only for ref discovery, fixed sequences batched.

## 1. Resolve the base URL and handle TLS

APEX has no fixed topology. The runtime may be ORDS standalone (Jetty), ORDS on Tomcat/WebLogic, any of those behind a reverse proxy (nginx, Apache, a load balancer), or a managed/cloud deployment (Autonomous DB / APEX Service) on a custom domain. **Host, port, scheme, and even the path prefix are whatever that deployment exposes — discover them, don't assume** `:8443` or `/ords`.

Then handle the cert per case:

- **Valid public cert** (typical for cloud/managed, or a proxy terminating TLS with a real cert): nothing to do — navigate straight to the URL.
- **Self-signed / internal cert** (common on DEV/STAGING): the browser may block with `NET::ERR_CERT_*`. In testing, Playwright MCP reached a self-signed `https://...:8443` without a cert wall — its browser accepts it. The **Playwright CLI blocks by default** — see §0 for its `cli.config.json` fix. If your browser-MCP blocks, enable its TLS/cert-bypass option (Playwright MCP: `ignoreHTTPSErrors` at browser launch; other MCPs expose an equivalent). Fix it at the tool config, not in the loop.

## 2. Login — use the right credentials

The APEX **runtime app** login is its own authentication scheme — most commonly APEX accounts (a workspace/application user). It is **not** the ORDS/instance-admin password and **not** the DB schema password; using either typically yields **"Invalid Login Credentials"**. If the app uses SSO/social/custom auth instead, follow that flow.

**Don't assume where the credential lives.** It may be in a project env file, a secrets manager, CI variables, or the APEX workspace user list — read the actual values from *this* project's setup; don't hardcode a path or variable name.

```
navigate   https://<base-url>/r/<workspace>/<APP-ALIAS>/   # <base-url> = whatever §1 resolved, e.g. host[:port]/ords
   → redirects to .../login
snapshot    → find Username / Password textboxes + "Sign In"
fill form   Username=<app-user>  Password=<app-pass>
click       Sign In
   → lands on /home
```

**Login throttling:** failed attempts trigger an escalating wait ("wait 5 / 10 seconds to sign in again"). If you fat-finger the password, wait (~12 s) before retrying — hammering just raises the timer.

## 3. Preserve the session (the #1 gotcha)

APEX ties the session to a token. A fresh navigate (a new page load) to a deep page URL **starts a new anonymous session → bounces to login**. After login, navigate one of two ways:

- **Append the current session token:** read it from the URL after login (`.../home?session=8808821264318`) and reuse it:
  `https://<base-url>/r/<workspace>/<APP-ALIAS>/<page-alias>?session=<token>`
- **Or click in-app nav links** (they already carry the session).

A deep link without the token will silently send you to login — if you land on the login page mid-flow, this is why.

**Keep one browser session for the whole loop.** With the Playwright CLI daemon this is automatic — the browser (and login) survives between commands and between checks. With an MCP, don't close/reopen tabs between checks; hold the tab, and re-login only if you actually get bounced. Logging in is 3–4 round-trips — pay it once.

**Batch the login.** The navigate → fill → click Sign In sequence needs no reasoning between steps: run it as one `run code` snippet (or one batched CLI sequence) instead of stepwise with a snapshot after each action.

## 4. Modal/detail pages need their page items

A modal page (e.g. an edit/resolve dialog) expects a PK item set by its caller. Deep-linking it standalone needs the item in the URL. Prefer reaching it the real way — click the master's edit/link icon — so APEX sets the item and session for you.

## Cleanup after a write

An Interactive Grid with unsaved edits triggers a **beforeunload dialog** when you navigate away — navigate will time out waiting. Handle it with handle dialog (accept). Then confirm no test data persisted with SQLcl (`sql -name <conn>`).
