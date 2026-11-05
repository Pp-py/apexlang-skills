---
name: apexlang-delivery
description: Use when a change to an APEXlang app is to be delivered and called verified — to run the framework's gates in order for one task (Architecture, Validation, Package, Sync, import, Runtime, Security, UI), read what each produced, and write the task's verification-manifest; and whenever someone asks whether a task is done.
---

# apexlang-delivery

## Contract

- **Does:** orchestrates the other skills' gates for one task, in `framework/GATES.md`'s order, and records the outcome as a `verification-manifest`. It adds no rule of its own (P2, P6).
- **Use when:** a change is to be delivered; before anyone says a task is verified.
- **Decides:** nothing about the app. Each gate's verdict is its owner's; this skill reads them, judges whether they are valid and fresh, and aggregates the required ones.
- **Output:** `<evidenceDir>/<task>/manifest.json` (`framework/schemas/verification-manifest.schema.json`), its status the worst of the required gates.
- **Evidence:** the manifest cites every result it read by path and sha256, and Validation by the compiler's command, exit code and words; nothing of its own.
- **Gate:** none — it is the consumer of all seven (`framework/GATES.md` §The orchestration contract); it may skip a gate only as `required: false` with a reason.
- **Interface:** the agent runs each gate with its owning skill, passing `--app` (and `--env`) and `--task`; then `python3 scripts/delivery.py --task <id> [--app X] [--env E] [--skip <gate>:<reason>]… [--exit <gate>:<code>]… [--page <page>[:dialog]]… [--run <id>]` writes the manifest and says the next step. Exit 0 PASS · 1 FAIL/CONFLICT · 2 BLOCKED · 3 UNKNOWN · 4 NOT_RUN.

## The loop — one task

Pick a task id (`T-42`) and use it for every command; start at step 0. After each gate, run `delivery.py`: it reads the task dir and prints the next gate to run, or the gate to stop at.

Optional (GAP-14): `export APEX_RUN_ID=<id>` (letters, digits, `.`, `_`, `-`; up to 64) before the first
producer, then `delivery.py --task <id> --run <id>`: a result written without that id is `NOT_RUN` (stale);
`--run` alone labels nothing. A new attempt takes a new id and reruns every required producer.

0. **Preflight** — before the first gate, once per task and per machine:
   `apex-sync-check.sh apps` (offline: alias, `appId`, source dir, connection, test user, URL, per app and
   environment) and `apex-sync-check.sh doctor` (tools and connectivity). Exit 2, or no `apex-sync.json` at
   the repo root: **stop and ask the user for the values** (`appId`, alias, source dir, saved connection,
   `runtimeUrl`; `apex-sync-guard/setup.md` §1) — never invent them, never import or export meanwhile: the
   hook watches only a repo with that file, and Sync, Validation and Runtime cannot PASS without it. Read
   which of `packageGate`, `securityGate`, `uiGate` the app sets: a gate that is not required reads
   `not required`, which is not `passed` (stderr ends with `not evaluated: …`). An exit 0 from `apps` or
   `doctor` authorizes nothing — no import, no "verified": only a fresh `check-import` PASS opens the import.
1. **Architecture** — decide with `apexlang-architecture` before building; after the build, its
   result through `framework/scripts/evidence.py write --kind architecture --task <id>`, with
   `arch-scan.py`'s command as evidence.
2. **Validation** — Oracle's compiler, captured:
   `evidence.py capture --gate validation --app X --task <id> validate -- <validate-apex-app.sh> <source dir>`.
   It passes on exit 0 **and** `Validation successful` — nothing else (pin the JVM to English:
   `JAVA_TOOL_OPTIONS='-Duser.language=en -Duser.country=US'`, UP-1). The 26.1 lint never makes it pass.
3. **Package** — when the app sets `packageGate`: `pkg-check.py --app X [--env E] --task <id> <the .apx
   files or directories>` looks up, read-only, the packages and procedures the change names. A change
   that touches no page, or a first import (the app is not in the database yet), is
   `--skip package:<reason>`. A FAIL or an UNKNOWN stops the lane before Sync.
4. **Sync** — `apex-sync-check.sh check-import --app X [--env E] --task <id>`.
5. **Import** — the import lane, each step only on the previous one's exit 0, never chained
   with `;`: Validation PASS → `check-import` PASS (it lapses in 5 minutes, and speaks only for
   the LOCAL it compared) → `apex import` (or Oracle's deploy script) → `record-sync`. Nothing
   imports into an environment the user did not name, or into a `protected` one: those are the
   user's to run. Nothing enforces Validation before Oracle's deploy script (GAP-3): this
   order does. `record-sync --task <id>` leaves the result the Runtime gate reads next.
6. **Runtime** — the `apex-sentinel` walkthrough as the test user, **after** the `record-sync` (log
   in again after the import: it ended every session), its result through `evidence.py write
   --kind runtime`. Run `record-sync` again later in the task and this walkthrough's verdict reads
   as older than it: write it again. A task with no import has no `record-sync`: `--skip
   runtime:<reason>`, or a no-op `record-sync` (basis `builder-unchanged`) before the walkthrough.
7. **Security** — when the app sets `securityGate`: `sec-scan.py`, `plsql-scan.py`,
   `secrets-scan.py` and `sec-probe.py`, each with `--task`.
8. **UI** — when the app sets `uiGate`: `ux-scan.py`, and `ux-check.py` on each page the change
   touched, each with `--task`. Then tell `delivery.py` which pages those are: `--page <page>` for
   each (the `<page>` of `ui-<key>-runtime-<page>.json`: the f?p= page id or the URL's last
   segment), `--page <page>:dialog` for one that opens a dialog (its `--dialog` opener must
   have been exercised). It cannot derive them: with no `--page` the UI gate is `NOT_RUN`.

### Who does what

| Gate | Run by | Command (with `--app`, `--env`, `--task`) | Leaves in the task dir |
|---|---|---|---|
| Architecture | the agent (judgment), `arch-scan.py` (four red flags) | `evidence.py write --kind architecture` | `architecture.json` |
| Validation | Oracle's script, captured | `evidence.py capture --gate validation … validate -- <script> <dir>` | `raw/validation-<alias>/validate` and `.exit.json` |
| Package | script, read-only SQL | `pkg-check.py` | `package-<key>.json` |
| Sync | script | `apex-sync-check.sh check-import` | `sync-<key>-check-import.json` |
| Import | the agent, by the lane above; `record-sync` after | `apex import` / the deploy script; `apex-sync-check.sh record-sync` | `sync-<key>-record-sync.json` (read by Runtime, not by Sync) |
| Runtime | the agent in the browser (`pw.sh`), after `record-sync` | `evidence.py capture`, then `write --kind runtime` | `runtime-<key>.json`, `raw/runtime-<key>/` |
| Security | scripts | `sec-scan.py`, `plsql-scan.py`, `secrets-scan.py`, `sec-probe.py` | `security-<alias>-{static,plsql,secrets}.json`, `security-<key>-runtime.json` |
| UI | scripts; the pages by `--page` | `ux-scan.py`, `ux-check.py` per page | `ui-<alias>-static.json`, `ui-<key>-runtime-<page>.json` |
| The manifest | script | `delivery.py` | `manifest.json` |

`<key>` is the alias, or `<alias>.<env>` for an app with environments.

**Stop at the first required gate that is not PASS**, and report it with its result. What
happens next — fix and re-run, or not — is the user's call (P9). A re-run replaces the old
result; a gate skipped is `--skip <gate>:<reason>`, recorded as not required, never left out.

## What `delivery.py` reads, and how

Per gate, the files its producer writes in the task dir (the script's header lists them). Each
is validated against the core's schemas with `jsonschema`, which this skill **requires**
(`apt install python3-jsonschema`, or `python -m pip install jsonschema`): without it, or without
`framework/schemas/`, `delivery.py` stops `BLOCKED` (`NO_JSONSCHEMA`, `NO_SCHEMAS`) and writes no
manifest — there is no weaker check. The result must also be **fresh**: made for this task, on the
working tree as it is now (`GATES.md` §Freshness). Invalid → `UNKNOWN`. Missing or stale → `NOT_RUN`: a change to
any tracked or untracked file — `apex-sync.json` included — makes the earlier results stale, and
they are run again. Package, Security and UI are required only when the app opts in (until 1.0.0).
The Runtime gate reads two results, `runtime-<key>.json` and `sync-<key>-record-sync.json`, and is `NOT_RUN`
when `record-sync` is missing, is not `operation: record-sync`, or when the walkthrough's verdict (`context.timestamp`)
is earlier than the `record-sync`'s (the same second is in order; a timestamp that cannot be read as a UTC time is
`UNKNOWN`). Only the runtime result is marked stale; `--exit runtime:<code>` speaks for it alone. The Sync gate stays
`check-import` alone: its PASS is what authorizes the import, so it cannot wait for the `record-sync` that follows it.
A valid, fresh result must also be *this destination's*: its `operation` or `scope`, `app.appAlias`
and, for Package, Sync, Runtime and the runtime scopes, `app.environment` and `app.appId` must match what
the file's name stands for; otherwise it reads `NOT_RUN` ("misfiled"), never PASS. The UI gate
reads exactly the page files `--page` names, each valid, fresh and with its own `runtimeUrl`
naming that page (a copy of another page's result is misfiled); a repeated or malformed
`--page` stops `BLOCKED` (`BAD_PAGE`). Other `ui-<key>-runtime-*.json` in the task still count in
the gate's worst status. `--skip ui:<reason>` skips the whole gate and wins over `--page`; a page is never skipped.
A gate that is not required carries `excludedBy` in the manifest (`config`: the app did not opt in; `skip`: `--skip`),
and stderr ends the gate list with `not evaluated: …`: read it before reporting a PASS. Every manifest lists the Package gate (`required: false` unless
the app sets `packageGate`). Setting `packageGate`, `securityGate` and `uiGate` to `true` at the top of
`apex-sync.json` is already the profile that requires all three.

## A pipeline

[`docs/examples/ci/apexlang-static-gates.yml`](../../docs/examples/ci/apexlang-static-gates.yml)
is a GitHub Actions workflow to copy into a project: on each pull request it runs the five
static scans at a pinned release and uploads their results. Validation, Sync, Runtime and the
runtime scopes need SQLcl, the Builder or a browser, so they stay in this loop; a green
pipeline is the static scopes holding, never a verified task.

## What a PASS here does not establish

Anything its gates do not (each gate's "PASS does NOT establish" row); that a gate the user
skipped did not matter; that the pages declared with `--page` are all the pages the change touched
(your declaration, not a diff); that the import ran (a `record-sync` PASS records a syncpoint after a fresh
check — it also passes after an omitted import, and after an export, which writes the same file); that the walkthrough
was observed after the import (its timestamp is when the verdict was written, to the second); anything about another app, environment or task. `delivery.py` sees
files, not commands: pass a gate's exit with `--exit <gate>:<code>` whenever you just ran it —
a result it did not leave is then `BLOCKED` (exit 2) or `UNKNOWN`, and a result whose command's
exit disagrees with it is `UNKNOWN`; without `--exit`, a missing result reads `NOT_RUN`.

## Red flags — stop

- Importing because "the checks passed earlier" — the Sync PASS is minutes old at most, and for the LOCAL it compared.
- Calling a task verified on anything but `delivery.py` exit 0.
- Writing or editing a result, the manifest, a marker or a ref by hand; `record-sync --force`.
- Re-running a gate until it passes without saying it was re-run.
- Running `record-sync` again after the walkthrough was written, or `--skip runtime:<reason>` to get past a missing `record-sync` on a task that did import.
- Promoting an advisory (the 26.1 lint, `UX-AXE-MINOR`, `UX-ORACLE-OWNED`) to a verdict, or a verdict to an advisory.
