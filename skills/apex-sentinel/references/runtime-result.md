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

Save what the page told you through `framework/scripts/evidence.py capture`: it runs the step,
stores its output under `raw/runtime-<alias>/` with session ids, local paths, passwords and connect
strings removed, creates the evidence dir's `.gitignore`, and prints the `evidence` entry with the
file's sha256 — the hash is what makes the result auditable after the fact.

```bash
EV=framework/scripts/evidence.py
python3 $EV capture --gate runtime --app hr --task T-42 ig-duplicate.json -- \
  scripts/pw.sh --app hr eval '() => document.querySelector("#t_Alert_Notification")?.innerText ?? null'
```

## Writing it

Never write the result by hand. Put what you observed in a draft — `check`, `backend`, `login`,
`criteria` (the `evidence` entries `capture` printed; a file entry may omit `sha256`), and
optionally `evidence` and `target` — and let the script write it:

```bash
python3 $EV write --kind runtime --app hr --task T-42 draft.json
```

It adds `kind`, `app`, `context` (`method: agent`; `runtimeUrl` from `apex-sync.json` when the draft
has none) and **derives the status** by the table below; a draft with a `status` is refused. It
hashes every cited file again and refuses one that changed since `capture`, a PASS criterion with
no evidence, a NOT_RUN with no reason, and any field holding a password or a connect string — the
message names the field, never the value. Exit: the status (0 PASS · 1 FAIL · 2 BLOCKED ·
3 UNKNOWN); a refused draft exits 2 and writes nothing.

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
