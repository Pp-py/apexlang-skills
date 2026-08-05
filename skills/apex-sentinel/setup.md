# Setup — connecting a browser backend to an APEX runtime

Pick and configure the backend once (§0), then get the four APEX-specific blockers right (§1–§4).

## 0. Choose and configure the backend

### Playwright CLI — preferred, via `scripts/pw.sh`

```bash
<skill-dir>/scripts/pw.sh open <base-url>   # resolves launcher, pins workspace, writes TLS config
<skill-dir>/scripts/pw.sh eval "() => document.title"
<skill-dir>/scripts/pw.sh close-all         # when the loop is done
```

Run it from anywhere — unlike the raw CLI, it does not care about your working directory. It is a bash script: Linux and macOS natively, Windows through **Git Bash or WSL** (the `--config` path it hands to node is converted with `cygpath`, so a POSIX path is not silently resolved against the wrong drive — which would drop `ignoreHTTPSErrors` and stall the loop on a self-signed cert).

No install step to reason about: the wrapper takes a global `playwright-cli` if there is one and falls back to `npx -y @playwright/cli`, probing on **exit code** (see `SKILL.md` Step 0 — the npx "update available" banner is not a failure).

Why it's the fast path: a daemon keeps the browser (and the APEX login + session token) alive across every check in the loop, and each command writes its accessibility snapshot to disk (`$PW_WORKSPACE/.playwright-cli/page-<timestamp>.yml`) instead of streaming it into your context. **Grep those YAML files — or use `pw.sh find <text>` — never read one whole**; an APEX IG page's tree is tens of thousands of tokens.

Multi-step sequences (login, the IG add-row dance) go through `run-code` — one call runs a whole Playwright snippet (`await page.getByRole(...)...`), replacing 6–10 stepwise commands.

**Three CLI mechanics the wrapper exists to hide.** Know them, because they explain its failure messages:

- **The session is anchored to a directory, not to you.** The daemon session is keyed by a hash of the nearest ancestor directory containing `.playwright/`. An agent shell resets its cwd between calls, so the same command issued from a different directory sees *no* session and fails with `Browser '<name>' is not open` — the CLI's most common false negative. `pw.sh` `cd`s to one fixed workspace (`$PW_WORKSPACE`) on every call and re-opens the session if the daemon died, warning you that the page state — including the APEX session token — was lost.
- **`open` is destructive when the session is already open.** It kills the running browser and starts a new one, silently discarding your login. `pw.sh open` on a live session navigates instead, so it is safe to repeat.
- **Self-signed TLS needs a config file**, `.playwright/cli.config.json`, passed to `open` as `--config <absolute path>`:

  ```json
  { "browser": { "contextOptions": { "ignoreHTTPSErrors": true } } }
  ```

  `pw.sh` writes it once inside `$PW_WORKSPACE`. Set `PW_INSECURE_TLS=0` if the runtime has a valid cert and you want validation enforced.

**Keep the workspace out of the project.** `$PW_WORKSPACE` defaults to a scratchpad directory precisely so a verification run leaves nothing in the user's APEX repo — `.playwright/cli.config.json` has been accidentally *committed* to a consuming repo this way. If you deliberately point `$PW_WORKSPACE` at a repo (to reuse the login across sessions), add `.playwright/`, `.playwright-cli/` and `.playwright-mcp/` to that repo's `.gitignore` **first**.

### Playwright MCP — fallback, only when the CLI probe resolves nothing

Works, but **stock defaults fight this loop**, and none of them are fixable from inside it. A Playwright MCP wired the common way — `npx @playwright/mcp@latest` with no arguments — has TLS validation on and full-snapshot responses on. Hardening it is a **one-time user-side action**: edit the MCP server's launch arguments and restart it. Flags below are from `@playwright/mcp@latest --help`:

- `--ignore-https-errors` — accept a self-signed runtime cert. Without it, `browser_navigate` to an internal `https://` APEX instance dies on `net::ERR_CERT_AUTHORITY_INVALID` with no in-loop remedy.
- `--image-responses omit` — don't stream screenshots you didn't ask for.
- `--caps=verify` — enables `browser_verify_text_visible` / `browser_verify_element_visible` etc.: assertions that don't return a snapshot.
- `--storage-state <path>` — persist cookies so a restarted browser doesn't force a fresh APEX login.
- `--headless` — no rendering overhead.

Note where that config actually lives. If the MCP comes from a plugin, its `.mcp.json` sits in a **plugin cache directory that is overwritten on every plugin update** — edits there are not durable. Put the hardened entry somewhere the update cannot clobber (a user- or project-level MCP config), or accept that the CLI path is the reliable one.

Whichever backend: the per-check technique for keeping context small is `SKILL.md` §"Snapshot diet" — targeted `eval` extraction, snapshots only for ref discovery, fixed sequences batched.

## 1. Resolve the base URL and handle TLS

APEX has no fixed topology. The runtime may be ORDS standalone (Jetty), ORDS on Tomcat/WebLogic, any of those behind a reverse proxy (nginx, Apache, a load balancer), or a managed/cloud deployment (Autonomous DB / APEX Service) on a custom domain. **Host, port, scheme, and even the path prefix are whatever that deployment exposes — discover them, don't assume** `:8443` or `/ords`.

Then handle the cert per case:

- **Valid public cert** (typical for cloud/managed, or a proxy terminating TLS with a real cert): nothing to do — navigate straight to the URL.
- **Self-signed / internal cert** (common on DEV/STAGING): **assume either backend will block** with `NET::ERR_CERT_*` until configured otherwise. Both validate certs by default; what differs is how far away the fix is:

  | Backend | Where the bypass lives | Reachable mid-loop? |
  |---|---|---|
  | Playwright CLI | `.playwright/cli.config.json` (`ignoreHTTPSErrors`), passed to `open --config` | **Yes** — `pw.sh` writes it for you |
  | Playwright MCP | `--ignore-https-errors` server launch flag | **No** — edit the MCP config, restart the server |

  So a self-signed runtime is a reason to **prefer the CLI**, not to avoid it: it is the only backend whose cert wall you can clear without leaving the loop.

**Never route around a cert wall by changing the URL.** Dropping `https://host:8443` to a plain `http://host:8080` that happens to answer will make the page load, and it invalidates the run: you are then verifying a different transport than the one under test, and blind to every defect that only shows on the real one (mixed content, `secure` cookies, proxy-only rewrites, HSTS). Same for swapping host or port. Fix the backend's TLS setting, or stop and report — see `SKILL.md` §"Red flags".

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

**Keep one browser session for the whole loop.** With the Playwright CLI daemon this is automatic *as long as every command resolves the same workspace* — which is what `pw.sh` guarantees; the browser and login then survive between commands and between checks. Never issue a bare `open` mid-loop to "make sure" the browser is up: on a live session that restarts it and throws the login away (`pw.sh open` handles this for you). With an MCP, don't close/reopen tabs between checks; hold the tab, and re-login only if you actually get bounced. Logging in is 3–4 round-trips — pay it once.

**Batch the login.** The navigate → fill → click Sign In sequence needs no reasoning between steps: run it as one `run code` snippet (or one batched CLI sequence) instead of stepwise with a snapshot after each action.

## 4. Modal/detail pages need their page items

A modal page (e.g. an edit/resolve dialog) expects a PK item set by its caller. Deep-linking it standalone needs the item in the URL. Prefer reaching it the real way — click the master's edit/link icon — so APEX sets the item and session for you.

## Cleanup after a write

An Interactive Grid with unsaved edits triggers a **beforeunload dialog** when you navigate away — navigate will time out waiting. Handle it with handle dialog (accept). Then confirm no test data persisted with SQLcl (`sql -name <conn>`).

Close the browser at the end (`pw.sh close-all`). Snapshot and console artifacts live in `$PW_WORKSPACE` — outside the project by default, so there is nothing to clean up in the repo. Check `git status` in the APEX project anyway before you report done: a run must leave it untouched.
