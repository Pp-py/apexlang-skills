---
name: apex-security
description: Use when an APEXlang app or page is designed, changed or reviewed for security — page and action authorization, public pages, page access protection and session state protection, escaping of HTML output, dynamic SQL in the write-path packages, secrets in the repo — and before calling a change safe to deploy.
---

# apex-security

## Contract

- **Does:** judges an APEXlang app's security against a catalog of criteria with IDs (`criteria.md`) — from Oracle's 26.1 security policies and OWASP ASVS 5.0 — statically over the repo's `.apx`, package source and config, and at runtime through probes in the browser.
- **Use when:** a page, an action or a write-path package is added or changed, and before anyone calls a change safe to deploy.
- **Decides:** whether each criterion holds — never where logic lives (`apexlang-architecture`), never whether the page works (`apex-sentinel`), never grammar (Oracle's compiler).
- **Output:** a `security-result` (`framework/schemas/security-result.schema.json`, experimental) per run: per criterion `PASS` · `FAIL` · `NOT_RUN`, plus advisories that never change the verdict.
- **Evidence:** per criterion, the file and line it rests on, or the saved browser output with its sha256 under the task's evidence dir (`framework/EVIDENCE.md`).
- **Gate:** Security — not in `framework/GATES.md` yet (SEC-6).
- **Interface:** the criteria in `criteria.md`; `python3 scripts/sec-scan.py [--app X] [--task <id>] <file-or-dir>…` for the `.apx`, `scripts/plsql-scan.py` (same arguments) for the packages; `scripts/sec-probe.py` for the runtime probes; `scripts/secrets-scan.py` for secrets. Config: `publicPages` and `lowPrivUser` per app in `apex-sync.json` (`apex-sync-guard/setup.md` §1).

## Status — what exists

| Piece | State |
|---|---|
| Threat model and criteria with IDs (`criteria.md`) | **built** (SEC-1) |
| Static scan over `.apx`: authorization, public pages, page and item protection, escaping, URLs | **built** (SEC-2) — see §Static scan |
| Scan of the write-path packages: dynamic SQL, `AUTHID` | **built** (SEC-3) — see §Package scan |
| Runtime probes through `pw.sh`: anonymous access, checksum tampering, role refusal, escaped payload | **built** (SEC-4) — see §Runtime probes |
| Secrets in the repo | **built** (SEC-5) — see §Secrets scan |
| `security-result` schema | **built** (SEC-2, experimental) |
| Security gate: GATES column, order, manifest enums | not built (SEC-6) |

Until the scripts exist, a review cites the criterion IDs it checked and says which it did not. A criterion nobody exercised is `NOT_RUN`, never PASS.

## Static scan

`python3 scripts/sec-scan.py [--app X] [--task <id>] <app-dir>` over the app's `.apx` tree
(`application.apx` included, or `SEC-APP-SSP` is `NOT_RUN`). It checks the nine static `FAIL`
criteria other than `SEC-SQL-BIND` and `SEC-NO-SECRETS`, and reports the session advisories.
`publicPages` comes from the app's entry in `apex-sync.json` (none = no public page but the
login). With `--task` the result lands in `<evidenceDir>/<task>/security-<alias>-static.json`.
Exit 0 PASS · 1 FAIL · 2 BLOCKED · 3 UNKNOWN — a file it could not parse got no page or item
checks; never treat 3 as PASS. Its `.apx` reader is the one apex-ux's scan uses (`framework/lib/`).

What it does not establish: what an authorization scheme's PL/SQL decides, or that the scheme is
the right one for the action; that a reviewed public page is safe to be public; anything in
`.apx` it could not parse; dynamic SQL and secrets (SEC-3, SEC-5); anything at runtime (SEC-4).

## Package scan

`python3 scripts/plsql-scan.py [--app X] [--task <id>] <dir>…` over the packages (`.sql`, `.pks`,
`.pkb`, `.pls`) and the `sql`/`plsql` blocks of the `.apx`, for `SEC-SQL-BIND`, with `SEC-AUTHID` as
an advisory. Comments and literals are masked first; a variable is traced through its `:=`
assignments in the same file. A `security-result` with `scope: plsql`
(`security-<alias>-plsql.json` with `--task`); exit codes as above.

What it does not establish: injection in views, triggers or code outside the scanned files;
whether a reviewed statement is safe (the review comment is a person's claim); JavaScript
injection; anything at runtime.

## Runtime probes

After `pw.sh [--app X] login` and `pw.sh goto <page>`, as the test user:
`python3 scripts/sec-probe.py [--app X] [--task <id>] [--anon <url>]… [--tamper] [--role <url>]… [--xss <token>]`.
Each probe runs only when asked; one not asked is `NOT_RUN`. A refusal is read from the page id
APEX renders (`#pFlowStepId`) against a control — the same URL loaded by the test user — so a
broken link is `UNKNOWN`, never a PASS. `--anon` fetches over plain HTTP with no cookie;
`--tamper` takes the first `cs=` link of the held page into a new tab (intact, without `cs`, with
a value changed); `--role` logs the app's `lowPrivUser` into its own session (password from
`$APEX_TEST_PASSWORD_LOW[_<ALIAS>]`, never argv) and closes it after. For `--xss`, first save a
test record through the page's normal form with a text field holding
`<b data-xss-probe="TOKEN">x</b>` (a fresh token), open the page that shows it, run the probe,
then delete the record. A `security-result` with `scope: runtime`; DEV only.

What it does not establish: anything on URLs, links or pages it was not given; that the right
role *is* let in (a refusal proves only the refusal); payloads other than the one stored;
anything an attacker would try beyond these four probes.

## Secrets scan

`python3 scripts/secrets-scan.py [--app X] [--task <id>] [<path>…]` — with no path, every file
git tracks. `SEC-NO-SECRETS` FAILs on a tracked `.env`, a wallet or key store, a private key, a
password or token assigned a literal, a connect string with credentials, or a known token
format; the finding names file, line and kind, never the value. Placeholders (`<…>`, `${VAR}`,
`$VAR`, `***`, stock examples such as `scott/tiger`) are not secrets; a line that must keep a
lookalike carries `secrets-scan: allow <reason>` on it or the line above. A `security-result`
with `scope: secrets`. A finding means rotate the secret, not only delete the line: it is in the
history already.

What it does not establish: anything in git history (use gitleaks for that), in ignored or
untracked files, in formats it does not know, or whether an allowed line really holds no secret.

## Threat model

What this skill defends against, for an APEX app built from this repo's source:

| Threat | Criteria |
|---|---|
| A visitor reaches a page or an action without logging in | `SEC-PAGE-AUTHZ`, `SEC-PUBLIC-DECLARED`, `SEC-ANON-REDIRECT` |
| A logged-in user reaches what their role does not allow | `SEC-ACTION-AUTHZ`, `SEC-ROLE-REFUSED`, `SEC-NO-SSC-AUTHZ`, `SEC-DATA-SCOPE` |
| A user edits a URL or session state to act on another record | `SEC-PAGE-CHECKSUM`, `SEC-APP-SSP`, `SEC-ITEM-SSP`, `SEC-CHECKSUM-TAMPER` |
| Stored or reflected HTML/JavaScript runs in another user's browser | `SEC-ESCAPE-COLUMN`, `SEC-ESCAPE-SUBST`, `SEC-URL-SAFE`, `SEC-XSS-ESCAPED`, `SEC-CSP` |
| A value reaches SQL as code | `SEC-SQL-BIND` |
| A credential leaks through the repo | `SEC-NO-SECRETS` |

The test users come from `apex-sentinel`: `testUser` (a normal user) and, optionally,
`lowPrivUser` — a user without the app's roles, password in `$APEX_TEST_PASSWORD_LOW` or
`$APEX_TEST_PASSWORD_LOW_<ALIAS>`, never in `apex-sync.json`. Without it, `SEC-ROLE-REFUSED` is
`NOT_RUN`. Probes run against DEV only, and leave no test record behind.

## A Security PASS is not a pentest

A PASS establishes that every `FAIL` criterion that was run held, on the source and the pages it
was run on. It does **not** establish: resistance to an attacker (no fuzzing, no scanning, no
pentest); what the PL/SQL behind an authorization scheme decides; database grants, network, TLS,
the identity provider or the instance's security settings; pages, actions or roles not probed;
the Builder's state beyond what Sync guarantees (the gate reads the repo, never the database).
Never write "secure" on the strength of this skill alone.

## Sources, and which wins

1. **Oracle's 26.1 generation policies** (`apex@oracle-skills`, the revision in `framework/oracle-skills.lock.json`) — the security baseline APEX expects; anchors in `tests/upstream/citations.md`. Its lint enforces part of it (`SECURITY_BASELINE_REQUIRED_001` and others), as advisory signals; the criteria here are version-independent and hold on 26.2, which ships no policies.
2. **OWASP ASVS 5.0** — for what Oracle's policies do not cover (runtime refusal, injection, output encoding).
3. **The inventory** — the property names and values (`security { … }` on app, page, item, button, process, column).
4. **This repo** — the single write path (`apexlang-architecture`), P10 for secrets (`framework/PRINCIPLES.md`).

Grammar keeps its own order (`framework/PRINCIPLES.md` P6): no criterion here makes the compiler wrong.

## Boundaries

| Owner | What |
|---|---|
| `apexlang-architecture` | where logic and DML live — the write path a security criterion cites, never restates |
| `apex-sentinel` | that the page works; the browser driver `pw.sh` and the test users |
| `apex-ux` | the UI: a confirmation before a destructive action (`UX-DESTRUCTIVE-CONFIRM`) is UX, its authorization is here |
| **`apex-security`** | whether the app refuses what it must — the criteria, the scans and the probes (through `pw.sh`, never a copy of it) |

## Red flags — stop

- "It's behind the login" as the answer for a destructive action, a role, or a URL with a key.
- A hidden region, a server-side condition or a disabled button as the only access control.
- `escapeSpecialChars: false` or a bare `&X.` "because the data is ours".
- A public page that is not in both places, or a password anywhere in the repo.
- Calling an app secure because the criteria passed.
