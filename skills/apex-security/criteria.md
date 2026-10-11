# Security criteria

Every security judgement this skill makes is one of these criteria, by ID. Format as in
`apex-ux/criteria/README.md`: **Sev** `FAIL` (the Security gate fails when it does not hold) or
`ADVISE` (reported, never changes the verdict); **By** `static` (read from the `.apx`, the package
source or the repo), `runtime` (probed in the browser through `apex-sentinel`'s `pw.sh`) or
`manual`. `tests/contract/surface.py` checks every row.

**Severity policy.** `FAIL` only for what a machine can establish without judgement — the same
ground as Oracle's lint-enforced MUSTs, version-independent here. A `FAIL` is never `manual`.
Page 0 (the global page) and the login page are outside the page rules, as in Oracle's policy.
Changing a severity is a catalog change, for every app — never a per-app exception.

| ID | Criterion | Sev | By | Source |
|---|---|---|---|---|
| `SEC-PAGE-AUTHZ` | every page except page 0 and the login page declares `security { authorizationScheme }`: bare `mustNotBePublicUser`, or a stricter `@<static-id>` scheme | FAIL | static | Oracle governance, `SECURITY_BASELINE_REQUIRED_001` |
| `SEC-PUBLIC-DECLARED` | a page with `authentication: public` other than the login page is declared twice, and both agree: a comment `public page review: <reason>` in its `.apx`, and its number in the app's `publicPages` in `apex-sync.json`. A public page missing from either, or a listed page that is not public, fails | FAIL | static | Oracle governance, `PUBLIC_PAGE_REVIEW_REQUIRED_001`; repo decision (both places) |
| `SEC-PAGE-CHECKSUM` | every page except page 0 sets `pageAccessProtection`, and never `unrestricted`; `argumentsMustHaveChecksum` by default | FAIL | static | Oracle governance, form, `SECURITY_BASELINE_REQUIRED_001` |
| `SEC-APP-SSP` | the application enables Session State Protection (`sessionStateProtection { }`); without it no item checksum is enforced | FAIL | static | Oracle governance, `SECURITY_BASELINE_REQUIRED_001` |
| `SEC-ITEM-SSP` | every hidden item, and every item named like a key (`P<n>_…_ID`, `_PK`, `_KEY`, `_ROWID`), declares `sessionStateProtection` with a checksum level; `unrestricted` only with a comment naming the same-page dynamic action that owns its value | FAIL | static | Oracle governance, `HIDDEN_ITEM_SSP_REQUIRED_001` |
| `SEC-ESCAPE-COLUMN` | no report or grid column sets `escapeSpecialChars: false` | FAIL | static | Oracle governance, `REPORT_ESCAPE_REQUIRED_001` |
| `SEC-ESCAPE-SUBST` | a column or item substituted into HTML (an HTML expression, static content, link text, a template) is escaped: `&X!HTML.` (or `!ATTR.`, `!JS.` where it lands), never a bare `&X.` | FAIL | static | Oracle cards-page, `CARDS_SECURITY_REQUIRED_001`; OWASP ASVS 5.0 V1 (output encoding) |
| `SEC-URL-SAFE` | no link or target is `javascript:`, `data:`, protocol-relative, or an external `http://` URL; external targets are HTTPS literals | FAIL | static | Oracle cards-page |
| `SEC-ACTION-AUTHZ` | a destructive button, action or process — delete, reject, remove, purge, revoke, deactivate, cancel a record — is under a role scheme: `security { authorizationScheme: @<static-id> }` on it or on its page. `mustNotBePublicUser` does not count: every page already requires it | FAIL | static | Oracle logic ("SSC is not authorization"); repo `apexlang-architecture/recipes/item-detail-page.md` |
| `SEC-SQL-BIND` | no SQL is built by concatenating a value: no `EXECUTE IMMEDIATE`, `OPEN … FOR` or `DBMS_SQL.PARSE` on a string assembled with `\|\|` from a variable or parameter, in the write-path packages or in the `.apx`. Dynamic SQL binds its values (`USING`) and checks identifiers with `DBMS_ASSERT` | FAIL | static | Oracle sql §6, logic guardrails; OWASP ASVS 5.0 V1 (injection) |
| `SEC-NO-SECRETS` | no tracked file holds a password, a connect string with credentials, a private key, a wallet or an API token — `.apx`, `.sql`, `apex-sync.json`, scripts, docs; a committed `.env` fails | FAIL | static | repo `framework/PRINCIPLES.md` P10 |
| `SEC-ANON-REDIRECT` | an unauthenticated request for a page that is not public ends on the login page, never on the page's content | FAIL | runtime | OWASP ASVS 5.0 V8 (authorization) |
| `SEC-CHECKSUM-TAMPER` | a URL to a page with `argumentsMustHaveChecksum`, with an item value changed or the checksum removed, is refused | FAIL | runtime | Oracle form; OWASP ASVS 5.0 V8 |
| `SEC-ROLE-REFUSED` | a page or action under an `@<static-id>` scheme refuses the app's `lowPrivUser`; without one configured the criterion is `NOT_RUN`, never PASS | FAIL | runtime | OWASP ASVS 5.0 V8 |
| `SEC-XSS-ESCAPED` | a markup payload saved through the page's write path, on a test record that is removed afterwards, renders as text wherever the page shows it | FAIL | runtime | OWASP ASVS 5.0 V1 (output encoding) |
| `SEC-SESSION-TIMEOUTS` | `sessionManagement` sets `maxSessionIdleTime` (≤ 3600 s) and `maxSessionLength` (≤ 28800 s) | ADVISE | static | Oracle governance |
| `SEC-SESSION-REJOIN` | `rejoinSessions` is `false`, and `deepLinking` is a deliberate choice | ADVISE | static | Oracle inventory (app `sessionManagement`, `security`) |
| `SEC-DOWNLOAD-AUTHZ` | report and grid downloads of sensitive data sit behind an authorization scheme, or are off | ADVISE | static + manual | Oracle global |
| `SEC-CSP` | the application sends a Content Security Policy that names its allowed origins | ADVISE | static + manual | Oracle global |
| `SEC-AUTHID` | every write-path package states `AUTHID` explicitly; definer rights is the default and a decision, not an accident | ADVISE | static | Oracle PL/SQL Language Reference (invoker's and definer's rights) |
| `SEC-NO-SSC-AUTHZ` | who may see or do something is an authorization scheme, never only a server-side condition or a hidden region | ADVISE | static + manual | Oracle logic |
| `SEC-DATA-SCOPE` | which rows a user may see is enforced in the data layer (a view, VPD, the package), never by a UI-only predicate | ADVISE | manual | Oracle sql §12 |
