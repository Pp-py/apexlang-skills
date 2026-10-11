# Engineering framework

The three skills each do one job. This directory is what makes them one system: the
rules they share, the contracts between them, the gates they implement and the evidence
each gate leaves behind — so that a person, an agent or a future orchestrator
(`apexlang-delivery`) can tell **what was established, by what, and what was not**.

```text
Oracle Official Skills    apex@oracle-skills (verified revision: oracle-skills.lock.json)
        │ provide: the language · inventory · generation (26.1) · compile · import/export
        ▼
apexlang-skills           apexlang-architecture · apex-sync-guard · apex-sentinel
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
| `schemas/` | JSON Schema (Draft 2020-12) for every result: `sync-result` (stable), `runtime-result`, `architecture-result`, `verification-manifest` (experimental), `common` |
| `oracle-skills.lock.json` | the Oracle skills revision this repo was verified against |

**Each skill still stands alone.** Installing one skill must keep working without the
others or this directory: the framework is the contract *between* them, never a runtime
dependency of any of them. (apex-sentinel reads `apex-sync.json` on its own for that
reason; `tests/integration/config-parity.sh` keeps its reading equal to the guard's.)
