# apexlang-skills

[![CI](https://github.com/Pp-py/apexlang-skills/actions/workflows/ci.yml/badge.svg)](https://github.com/Pp-py/apexlang-skills/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](./LICENSE)
[![Agent Skills](https://img.shields.io/badge/agent--skills-SKILL.md-6e56cf)](https://agentskills.io)

Three agent skills for building **Oracle APEX** apps as **APEXlang** declarative source (`.apx`) — architecture, sync safety, and runtime verification. They close one loop:

**architect → build (`.apx` + package) → sync-check → import → verify in the browser**

| Skill | Question it answers |
|---|---|
| [`apexlang-architecture`](skills/apexlang-architecture/SKILL.md) | **WHERE does logic go?** Every write through one PL/SQL package per table (single write-path), never region-bound Automatic DML. Ships 8 screen-archetype recipes. |
| [`apex-sync-guard`](skills/apex-sync-guard/SKILL.md) | **Is it SAFE to import/export now?** `apex import`/`export` are total silent overwrites. Keeps a syncpoint, gates both directions, drives a 3-way merge when both replicas moved. Wrapper script + blocking `PreToolUse` hook. |
| [`apex-sentinel`](skills/apex-sentinel/SKILL.md) | **Does it WORK?** Drives the running page in a real browser (Playwright CLI/MCP) before any "it works" claim. Never degrades to "validate passed". |

Out of scope: `.apx` grammar, `validate`, `import`, round-trip — that's the official **`apex`** skill (required).

## Install

**Claude Code (plugin):**

```text
/plugin marketplace add Pp-py/apexlang-skills
/plugin install apexlang-toolkit
```

Installs the three skills and auto-registers the sync-guard hook (it no-ops in projects without an `apex-sync.json` — per-project wiring in [`setup.md`](skills/apex-sync-guard/setup.md)).

**Any other agent** (Codex, opencode, Cursor, …): plain-Markdown [Agent Skills](https://agentskills.io) — symlink `skills/*` into your tool's skill directory, or point the agent at [`AGENTS.md`](./AGENTS.md).

## Requirements

- Official `apex` skill (SQLcl) — generate/validate/import `.apx`
- **apex-sentinel:** a browser-automation tool + SQLcl. Playwright CLI preferred and driven through `skills/apex-sentinel/scripts/pw.sh` (no install needed — it falls back to `npx`); any browser-MCP works as a fallback. No browser → it stops and reports; it never fakes verification
- **apex-sync-guard:** `git`, SQLcl, `jq` *or* `python3`

## Examples

Two runnable vertical slices (DDL + write-path package + validate-green `.apx` + browser-verification walkthrough): an editable Interactive Grid and an approval state machine. Start at [`examples/README.md`](skills/apexlang-architecture/examples/README.md) — and still `apex validate` against **your** APEX version before importing.

## Development

```bash
shellcheck skills/*/scripts/*.sh tests/*.sh                 # lint
tests/sync-guard-e2e.sh                                     # offline e2e (stubbed SQLcl)
```

Both also run in CI.

## License

[MIT](./LICENSE) © 2026 Pablo Portillo
