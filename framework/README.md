# Engineering framework

The six skills each do one job. This directory is what makes them one system: the
rules they share, the contracts between them, the gates they implement and the evidence
each gate leaves behind — so that a person, an agent or a future orchestrator
(`apexlang-delivery`) can tell **what was established, by what, and what was not**.

```text
Oracle Official Skills    apex@oracle-skills (verified revision: oracle-skills.lock.json)
        │ provide: the language · inventory · generation (26.1) · compile · import/export
        ▼
apexlang-skills           apexlang-architecture · apex-sync-guard · apex-sentinel
                          · apex-ux · apex-security · apexlang-delivery
        │ impose
        ▼
Engineering guardrails    single write path · fail-closed gates · evidence, not claims
```

## Read by role

| You are | Read |
|---|---|
| building an app with the skills | the skills themselves; [PRINCIPLES](PRINCIPLES.md) for the why |
| orchestrating them (a pipeline, an agent loop, `apexlang-delivery`) | [CONTRACTS](CONTRACTS.md), then [GATES](GATES.md) |
| auditing a change, or deciding whether to trust a result | [EVIDENCE](EVIDENCE.md), [CAPABILITIES](CAPABILITIES.md) |
| adding a capability (Security, UI/UX) | [GATES](GATES.md) §Adding a gate, [PRINCIPLES](PRINCIPLES.md) P6–P7 |

## What lives here

| File | Holds |
|---|---|
| [PRINCIPLES.md](PRINCIPLES.md) | the ten rules every skill and gate follows, each with where it is enforced |
| [CONTRACTS.md](CONTRACTS.md) | who owns what (Oracle vs this repo), statuses and exit codes, each capability's input and output, where results land, the frozen interface |
| [GATES.md](GATES.md) | the gates — what each establishes and what it does not — their order, aggregation, freshness, and the orchestration contract |
| [EVIDENCE.md](EVIDENCE.md) | what counts as evidence, what a result records about its context, redaction, where evidence lives |
| [CAPABILITIES.md](CAPABILITIES.md) | what is verified, on which Oracle version, with a link to the proof — plus known conflicts with Oracle and declared gaps |
| `schemas/` | JSON Schema (Draft 2020-12) for every result: `sync-result` and `verification-manifest` (stable), `runtime-result`, `architecture-result`, `ui-result`, `security-result` (experimental), `common` |
| `lib/` | the code the scripts share: `apx.py` (the `.apx` reader), `plsql.py` (the PL/SQL lexer), `pw.py` (the Playwright CLI runner), `result.py` (the result envelope, freshness, redaction) |
| `scripts/evidence.py` | how the agent writes its runtime and architecture results, and the raw evidence behind them |
| `oracle-skills.lock.json` | the Oracle skills revision this repo was verified against |

## Dependencies

The framework is the contract *between* the skills, and part of it is code they run. That
code is the **core**:

| Core file | What uses it |
|---|---|
| `lib/` (`apx.py`, `plsql.py`, `pw.py`, `result.py`) | the scripts of apexlang-architecture, apex-ux, apex-security and apexlang-delivery; `evidence.py` |
| `scripts/evidence.py` | apex-sentinel, to save its `runtime-result` and raw evidence |
| `schemas/` | apexlang-delivery, when `jsonschema` is installed (it validates each result against it) |

| Skill | Needs from the core |
|---|---|
| apex-sync-guard | nothing: it runs from its own directory |
| apex-sentinel | `scripts/evidence.py` (and so `lib/`) to save results; `pw.sh` reads `apex-sync.json` itself |
| apexlang-architecture | `lib/` for `arch-scan.py` |
| apex-ux | `lib/` for `ux-scan.py` and `ux-check.py` |
| apex-security | `lib/` for its four scripts |
| apexlang-delivery | `lib/` for `delivery.py`; `schemas/` when `jsonschema` is installed |

**Install units.** The supported ways to install a skill, and what each one means:

- **The whole repo** (the Claude Code plugin, or a clone): every skill, with the core in place.
- **A skill plus the core**, in the same layout: copy `skills/<skill>/` and the core
  (`framework/lib/`, `framework/scripts/evidence.py`, `framework/schemas/`) under one root, keeping
  `skills/` and `framework/` as siblings. The scripts find the core by a path relative to
  themselves (`../../../framework`), so the layout is what matters, not the location.
- **A symlink** of `skills/<skill>/` into a tool's skill directory, with the repo kept in place.
  The kernel resolves `..` through the link, so the core is found.

A skill copied out **without** the core fails on import (`ModuleNotFoundError: No module named 'apx'`).

**What this means for "independent".** Only apex-sync-guard runs with no other file. The other
five need the core, so installing one of them means installing *that skill plus the core*. That
is a supported install, but it is not independence in the strict sense, and this document does not
call it that. Removing the dependency by copying `lib/` into each skill would duplicate code that
the framework keeps single (P2), so that is not proposed here.
