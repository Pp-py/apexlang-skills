# Tests

Four tiers. Each says what its green establishes **and what it does not** — the same
discipline the gates follow ([framework/GATES.md](../framework/GATES.md)).

| Tier | Run | Establishes | Does not establish | Needs | CI |
|---|---|---|---|---|---|
| **contract** | `tests/contract/run.sh` | every schema is valid Draft 2020-12; each fixture validates; each negative — an unsafe result dressed up as safe — is rejected; every sync-result the e2e makes the script emit validates; links, the frozen interface and the deliberately duplicated patterns have not drifted | that any result tells the truth about a real Builder or page | python3 + jsonschema (`apt install python3-jsonschema`) | ubuntu |
| **integration** | `tests/integration/sync-guard-e2e.sh`, `pw-wrapper-smoke.sh`, `config-parity.sh` | the protocols with SQLcl and the Playwright CLI stubbed: verdicts, exit codes, markers, the hook's lanes, several apps, the login verdict, workspaces; both readers of `apex-sync.json` agree | anything about a real SQLcl, APEX instance or browser | bash, git, jq or python3 | ubuntu + Windows (Git Bash) |
| **upstream** | `tests/upstream/verify-citations.sh`, `validate-examples.sh [--lint\|--compiler]` | what this repo quotes from Oracle's skills still says it, at the locked revision; the examples under Oracle's 26.1 lint, or under the SQLcl compiler | anything about an app | Oracle's skills installed (`claude plugin install apex@oracle-skills`, or `APEXLANG_ROOT`); node for the lint; `SQLCL_BIN` for the compiler | no — runs are recorded in [CAPABILITIES.md](../framework/CAPABILITIES.md) §Recorded runs |
| **live** | the checklists in [live/README.md](live/README.md) | the real thing, against a DEV workspace | — | a DEV workspace, a saved SQLcl connection, a browser, a test user | never — and never against PROD |

Every script exits **0 PASS · 1 FAIL · 2 BLOCKED**: a missing prerequisite is BLOCKED and
named, never a pass. `tests/lib/resolve-apexlang-pkg.sh` finds Oracle's skills for the
upstream tier — the cached revision of the lock first — and blocks when there are none.
