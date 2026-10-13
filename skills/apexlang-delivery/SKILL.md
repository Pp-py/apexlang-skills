---
name: apexlang-delivery
description: Use when a change to an APEXlang app is to be delivered and called verified — to run the framework's gates in order for one task (Architecture, Validation, Sync, import, Runtime, Security, UI), read what each produced, and write the task's verification-manifest; and whenever someone asks whether a task is done.
---

# apexlang-delivery

## Contract

- **Does:** orchestrates the other skills' gates for one task, in `framework/GATES.md`'s order, and records the outcome as a `verification-manifest`. It adds no rule of its own (P2, P6).
- **Use when:** a change is to be delivered; before anyone says a task is verified.
- **Decides:** nothing about the app. Each gate's verdict is its owner's; this skill reads them, judges whether they are valid and fresh, and aggregates the required ones.
- **Output:** `<evidenceDir>/<task>/manifest.json` (`framework/schemas/verification-manifest.schema.json`), its status the worst of the required gates.
- **Evidence:** the manifest cites every result it read by path and sha256, and Validation by the compiler's command, exit code and words; nothing of its own.
- **Gate:** none — it is the consumer of all six (`framework/GATES.md` §The orchestration contract); it may skip a gate only as `required: false` with a reason.
- **Interface:** the agent runs each gate with its owning skill, passing `--app` (and `--env`) and `--task`; then `python3 scripts/delivery.py --task <id> [--app X] [--env E] [--skip <gate>:<reason>]… [--exit <gate>:<code>]…` writes the manifest and says the next step. Exit 0 PASS · 1 FAIL/CONFLICT · 2 BLOCKED · 3 UNKNOWN · 4 NOT_RUN.

## The loop — one task

Pick a task id (`T-42`) and use it for every command. After each gate, run `delivery.py`: it reads the task dir and prints the next gate to run, or the gate to stop at.

1. **Architecture** — decide with `apexlang-architecture` before building; after the build, its
   result through `framework/scripts/evidence.py write --kind architecture --task <id>`, with
   `arch-scan.py`'s command as evidence.
2. **Validation** — Oracle's compiler, captured:
   `evidence.py capture --gate validation --app X --task <id> validate -- <validate-apex-app.sh> <source dir>`.
   It passes on exit 0 **and** `Validation successful` — nothing else (pin the JVM to English:
   `JAVA_TOOL_OPTIONS='-Duser.language=en -Duser.country=US'`, UP-1). The 26.1 lint never makes it pass.
3. **Sync** — `apex-sync-check.sh check-import --app X [--env E] --task <id>`.
4. **Import** — the import lane, each step only on the previous one's exit 0, never chained
   with `;`: Validation PASS → `check-import` PASS (it lapses in 5 minutes, and speaks only for
   the LOCAL it compared) → `apex import` (or Oracle's deploy script) → `record-sync`. Nothing
   imports into an environment the user did not name, or into a `protected` one: those are the
   user's to run. Nothing enforces Validation before Oracle's deploy script (GAP-3): this
   order does.
5. **Runtime** — the `apex-sentinel` walkthrough as the test user (log in again after the
   import: it ended every session), its result through `evidence.py write --kind runtime`.
6. **Security** — when the app sets `securityGate`: `sec-scan.py`, `plsql-scan.py`,
   `secrets-scan.py` and `sec-probe.py`, each with `--task`.
7. **UI** — when the app sets `uiGate`: `ux-scan.py`, and `ux-check.py` on each page the change
   touched, each with `--task`.

### Who does what

| Gate | Run by | Command (with `--app`, `--env`, `--task`) | Leaves in the task dir |
|---|---|---|---|
| Architecture | the agent (judgment), `arch-scan.py` (four red flags) | `evidence.py write --kind architecture` | `architecture.json` |
| Validation | Oracle's script, captured | `evidence.py capture --gate validation … validate -- <script> <dir>` | `raw/validation-<alias>/validate` and `.exit.json` |
| Sync | script | `apex-sync-check.sh check-import` | `sync-<key>-check-import.json` |
| Import | the agent, by the lane above; `record-sync` after | `apex import` / the deploy script; `apex-sync-check.sh record-sync` | `sync-<key>-record-sync.json` |
| Runtime | the agent in the browser (`pw.sh`) | `evidence.py capture`, then `write --kind runtime` | `runtime-<key>.json`, `raw/runtime-<key>/` |
| Security | scripts | `sec-scan.py`, `plsql-scan.py`, `secrets-scan.py`, `sec-probe.py` | `security-<alias>-{static,plsql,secrets}.json`, `security-<key>-runtime.json` |
| UI | scripts | `ux-scan.py`, `ux-check.py` per page | `ui-<alias>-static.json`, `ui-<key>-runtime-<page>.json` |
| The manifest | script | `delivery.py` | `manifest.json` |

`<key>` is the alias, or `<alias>.<env>` for an app with environments.

**Stop at the first required gate that is not PASS**, and report it with its result. What
happens next — fix and re-run, or not — is the user's call (P9). A re-run replaces the old
result; a gate skipped is `--skip <gate>:<reason>`, recorded as not required, never left out.

## What `delivery.py` reads, and how

Per gate, the files its producer writes in the task dir (the script's header lists them). Each
is validated — with `jsonschema` when it is installed, otherwise with the script's own checks of
what a verdict rests on (kind, status vocabulary, task, criteria against status); the manifest's
`schemaCheck` says which — and must be **fresh**: made for this task, on the working tree as it
is now (`GATES.md` §Freshness). Invalid → `UNKNOWN`. Missing or stale → `NOT_RUN`: a change to
any tracked or untracked file — `apex-sync.json` included — makes the earlier results stale, and
they are run again. Security and UI are required only when the app opts in (until 1.0.0).

## A pipeline

[`docs/examples/ci/apexlang-static-gates.yml`](../../docs/examples/ci/apexlang-static-gates.yml)
is a GitHub Actions workflow to copy into a project: on each pull request it runs the five
static scans at a pinned release and uploads their results. Validation, Sync, Runtime and the
runtime scopes need SQLcl, the Builder or a browser, so they stay in this loop; a green
pipeline is the static scopes holding, never a verified task.

## What a PASS here does not establish

Anything its gates do not (each gate's "PASS does NOT establish" row); that a gate the user
skipped did not matter; anything about another app, environment or task. `delivery.py` sees
files, not commands: pass a gate's exit with `--exit <gate>:<code>` whenever you just ran it —
a result it did not leave is then `BLOCKED` (exit 2) or `UNKNOWN`, and a result whose command's
exit disagrees with it is `UNKNOWN`; without `--exit`, a missing result reads `NOT_RUN`.

## Red flags — stop

- Importing because "the checks passed earlier" — the Sync PASS is minutes old at most, and for the LOCAL it compared.
- Calling a task verified on anything but `delivery.py` exit 0.
- Writing or editing a result, the manifest, a marker or a ref by hand; `record-sync --force`.
- Re-running a gate until it passes without saying it was re-run.
- Promoting an advisory (the 26.1 lint, `UX-AXE-MINOR`, `UX-ORACLE-OWNED`) to a verdict, or a verdict to an advisory.
