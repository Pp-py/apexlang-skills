# Recording a runtime-result

A verification ends in a `runtime-result` — `framework/schemas/runtime-result.schema.json`
(experimental) — written to `<evidenceDir>/<task>/runtime-<alias>.json`, with raw evidence
under `<evidenceDir>/<task>/raw/runtime-<alias>/`. The orchestrator reads that file, not your
summary of it.

## One entry per criterion

Each check in `../checks/` lists its pass criteria with an ID (`IG-RENDER`, `WF-ILLEGAL-BLOCKED`, …).
Record every one you were asked to verify:

```json
{ "id": "IG-REJECT-DUPLICATE", "required": true, "status": "PASS",
  "observed": "A sector with code PROD already exists.",
  "evidence": [
    { "kind": "file", "path": ".apex-evidence/T-42/raw/runtime-hr/ig-duplicate.json", "sha256": "<sha256 of that file>" },
    { "kind": "sql", "statement": "select count(*) from hr_sectors where upper(code) = 'PROD'", "exitCode": 0, "result": "1" } ] }
```

Save what the page told you **by redirection**, then hash the file — the hash is what makes
the result auditable after the fact:

```bash
R=.apex-evidence/T-42/raw/runtime-hr; mkdir -p "$R"
scripts/pw.sh --app hr eval '() => document.querySelector("#t_Alert_Notification")?.innerText ?? null' > "$R/ig-duplicate.json"
sha256sum "$R/ig-duplicate.json"          # macOS: shasum -a 256
```

## Which status

| Situation | Status |
|---|---|
| no browser backend runs (`backend.kind: none`) | the result is **BLOCKED** — never faked |
| `pw.sh login` did not exit 0 (rejected, wrong user, unverifiable, landed on login) | `login.status` is not PASS, and the result is **BLOCKED** |
| a step exited 3 (`pw.sh` reopened a dead browser: the page was logged out) | that criterion is **UNKNOWN** until the step is repeated after a re-login |
| the criterion held, on evidence you saved | **PASS** — `observed` and `evidence` are required |
| it did not hold — including a raw `ORA-NNNNN:` prefix reaching the user | **FAIL** |
| the only evidence is a screenshot | **UNKNOWN** — except a canvas chart, where "it drew" is the criterion |
| you did not exercise it | **NOT_RUN**, with a `notApplicableReason` |

The result is PASS only when at least one required criterion exists and every required one
PASSed; any required FAIL makes it FAIL. CONFLICT never appears here — it belongs to the sync
gate.

## What never goes in

No session ids (strip `?session=` from any URL you record), no passwords, no customer data
in `observed` — prefer an `eval` of the one value under test to a full-page snapshot. Raw
files stay under `raw/`, which is never committed (`framework/EVIDENCE.md`).
