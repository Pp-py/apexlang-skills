# apexlang-skills

[![CI](https://github.com/Pp-py/apexlang-skills/actions/workflows/ci.yml/badge.svg)](https://github.com/Pp-py/apexlang-skills/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](./LICENSE)
[![Agent Skills](https://img.shields.io/badge/agent--skills-SKILL.md-6e56cf)](https://agentskills.io)

Three agent skills for building **Oracle APEX** apps as **APEXlang** declarative source (`.apx`) — architecture, sync safety, and runtime verification.

## What problem does this solve?

APEXlang turns an APEX app into declarative `.apx` source — what makes an APEX app tractable for a coding agent at all. Generating that source correctly is solved, and it belongs to **Oracle's official APEXlang skills** (plugin `apex@oracle-skills`, required): grammar, generation (26.1), `validate`, `import`.

Valid `.apx` is not a sound application, though. Three failure modes survive a clean `validate`:

- **Logic scatters.** Left alone, an agent bolts region-bound Automatic DML onto every grid and calls it simple — leaving no single place where a business rule holds.
- **A sync erases work.** `apex import` replaces the whole app in the Builder; `apex export` replaces the whole working tree. Whichever replica held unsynchronized changes loses them, irreversibly and without a prompt.
- **"It works" gets claimed from a green import.** `validate` proves grammar and `import` loads metadata; neither renders the page — a process can call a package procedure that doesn't exist and still validate.

`apexlang-skills` is the engineering layer over those three:

```text
Oracle's APEXlang skills  →  valid .apx: generate (26.1) · validate · import
apexlang-skills           →  architecture · sync safety · runtime proof
                             ──────────────────────────────────────────
                             an APEX app you can ship with evidence
```

They close one loop: **architect → build (`.apx` + package) → sync-check → import → verify in the browser**

| Skill | Question it answers |
|---|---|
| [`apexlang-architecture`](skills/apexlang-architecture/SKILL.md) | **WHERE does logic go?** Every write through a PL/SQL package (single write-path), never region-bound Automatic DML — plus which package owns it: the entity, a multi-entity flow, or neither. Ships 13 screen-archetype recipes. |
| [`apex-sync-guard`](skills/apex-sync-guard/SKILL.md) | **Is it SAFE to import/export now?** `apex import`/`export` are total silent overwrites. Keeps a syncpoint, gates both directions, and stops on a conflict when both replicas moved — the per-file merge that resolves it is documented, never automatic. Wrapper script + blocking `PreToolUse` hook. |
| [`apex-sentinel`](skills/apex-sentinel/SKILL.md) | **Does it WORK?** Drives the running page in a real browser (Playwright CLI/MCP) before any "it works" claim. Never degrades to "validate passed". |

## Install

**Claude Code (plugin):**

```text
/plugin marketplace add Pp-py/apexlang-skills
/plugin install apexlang-toolkit
```

Installs the three skills and auto-registers the sync-guard hook (it no-ops in projects without an `apex-sync.json` — per-project wiring in [`setup.md`](skills/apex-sync-guard/setup.md)).

**Any other agent** (Codex, opencode, Cursor, …): plain-Markdown [Agent Skills](https://agentskills.io) — symlink `skills/*` into your tool's skill directory, or point the agent at [`AGENTS.md`](./AGENTS.md).

## Requirements

- Oracle's official APEXlang skills (`apex@oracle-skills`; the revision this repo was verified against is pinned in [`framework/oracle-skills.lock.json`](framework/oracle-skills.lock.json)) and SQLcl — generate (26.1) / validate / import `.apx`
- **Platform:** the scripts are bash — Linux and macOS natively, Windows through **Git Bash or WSL** (not PowerShell/cmd; Claude Code's Bash tool on Windows already uses Git Bash). Paths crossing into SQLcl or node are converted with `cygpath`. That constraint is about *running* the scripts; the sync-guard hook itself watches **both** shell tools (`Bash|PowerShell`), and is registered as `bash "<path>"` so it works whichever shell the hook runner picks — `bash` only has to be on PATH
- **apex-sentinel:** a browser-automation tool + SQLcl. Playwright CLI preferred and driven through `skills/apex-sentinel/scripts/pw.sh` (no install needed — it falls back to `npx`); any browser-MCP works as a fallback. No browser → it stops and reports; it never fakes verification. Since APEX apps open on a login page, a **test user** is configuration: `testUser`/`runtimeUrl` in `apex-sync.json`, password from `$APEX_TEST_PASSWORD` / a gitignored `.env` / a json outside the repo, then `pw.sh login` ([`setup.md` §2](skills/apex-sentinel/setup.md))
- **apex-sync-guard:** `git`, SQLcl, `jq` *or* `python3`. Validate a machine with `skills/apex-sync-guard/scripts/apex-sync-check.sh doctor`

## Examples

Three runnable vertical slices (DDL + write-path package + `.apx`; the first two also with a browser-verification walkthrough): an editable Interactive Grid, an approval state machine, and a single-entity form (full page + drawer). Start at [`examples/README.md`](skills/apexlang-architecture/examples/README.md) — and still `apex validate` against **your** APEX version before importing.

Grammar status, measured rather than claimed: Oracle's 26.1 local lint (release 2026.09.21 — Oracle itself calls it advisory "syntax hygiene") passes the five `.apx` with only the diagnostics documented where they occur (the app-level breadcrumb entry, an Interactive Grid column `lov {}` block), while the compiler — SQLcl 26.2.0 `apex validate` on Oracle's 26.1 scaffold — currently **rejects** them. Lint-clean is not "compiles": details and the open conflict in [`examples/README.md`](skills/apexlang-architecture/examples/README.md#grammar-status--gotchas).

## Development

```bash
git ls-files -z -- '*.sh' | xargs -0 shellcheck -x   # lint
tests/contract/run.sh                                # schemas, negatives, every emitted result, docs surface
tests/integration/sync-guard-e2e.sh                  # sync guard + hook, SQLcl stubbed
tests/integration/pw-wrapper-smoke.sh                # pw.sh, Playwright CLI stubbed
tests/integration/config-parity.sh                   # apex-sync.json read alike by the guard and pw.sh
tests/upstream/verify-citations.sh                   # quotes from Oracle's skills still say what we claim
tests/upstream/validate-examples.sh [--compiler]     # the examples under Oracle's 26.1 lint, or SQLcl apex validate
```

What each tier establishes — and what it does not — is in [`tests/README.md`](tests/README.md).
Lint, contract and integration run in CI (integration on Ubuntu and Windows). The `upstream/`
scripts need Oracle's APEXlang skills installed — resolved from the revision pinned in
[`framework/oracle-skills.lock.json`](framework/oracle-skills.lock.json), or
`APEXLANG_ROOT=<path>/apex/apexlang` — and their runs are recorded in
[`framework/CAPABILITIES.md`](framework/CAPABILITIES.md). Exit codes: 0 PASS, 1 FAIL, 2 BLOCKED —
a missing prerequisite never reads as a pass.

## License

[MIT](./LICENSE) © 2026 Pablo Portillo
