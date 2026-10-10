# Where this skill stands against Oracle's standard

Oracle's 26.1 policies (`apexlang-generation/references/policies/`) are the standard for
grammar and components; this skill follows them there (`framework/PRINCIPLES.md` P6). It
departs from them in one place, on purpose, and says so.

## Automatic Row Processing: the deviation

**This is a deliberate deviation from Oracle's default, resting on an exception Oracle's standard itself names.** Oracle's 26.1 policies say *"Prefer ARP for simple CRUD"* (`apex.global.md`) — this skill does not. `apex.interactive-grid-page.md` lists Automatic Row Processing as non-negotiable rule 6 (§*Rules (Non-Negotiable)*: *"Enable automatic row processing"*), then carves it out under §*Process Guidance*: *"do not substitute custom PL/SQL **unless invoking a dedicated API**."* The package the `.apx` calls — entity or flow — **is** that dedicated API. The per-row process is equally official: `executeCondition: forEachRow`, a property of the process's `serverSideCondition` group (paired with `executionScope`) in the APEXlang grammar — not a workaround.

And everywhere else the standard talks about server-side code, it already leans this way: "page
processes default to `invokeApi`" (`apex.logic.md` §*2. Universal Guardrails*), "server-side work
should be packaged and referenced via `invokeApi` by default" (§*5. Dynamic Actions*), and inline
PL/SQL over 4000 characters is a hard failure whose fix is to "extract it into a package API"
(`PLSQL_INLINE_BLOCK_001`, §*2. Universal Guardrails* — it *blocks final output*). Form pages are told
to "offload logic to views or packages when possible" (`apex.form.md` §*Notes*). Automatic Row
Processing — preferred for simple CRUD, required by the IG page rule — is where the standard points the
other way. This skill takes the direction the rest of it already sets, and removes that exception. (The
policies also say pages call packages through `invokeApi`; the recipes use a thin `executeCode` wrapper
— both satisfy the single write path. Oracle's own policies disagree on this one: `framework/CAPABILITIES.md`
KC-4.)

## Three sources, three jobs

| Question | Authority |
|---|---|
| Is this valid `.apx`? Which properties, templates, slots exist? | Oracle — the SQLcl compiler (`apexlang-compile`) > the 26.1 lint > `apexlang-inventory`, the 26.1 policies and templates (`framework/PRINCIPLES.md` P6) |
| What should this pattern look like, and when is it the right pattern? | Oracle's UX Pattern Catalog app (26.1.4) |
| Where does the logic live, what must the data layer project, and when may we deviate? | **this skill** |

## The UX Pattern Catalog

The read-side recipes were built against that catalog. It is an Oracle sample app, not part of this skill, so recipes name its **patterns** (*Item Detail – Full*, *Faceted Search – Cards*) and never its page numbers, which are version-specific; a recipe cites it only where the citation carries an argument — usually a place where this skill deliberately does something else. Where the catalog and the official page standards disagree — and they do, on the faceted-search results region, on hidden region headers, on projecting theme classes from SQL — the disagreement is resolved in `ui-contracts.md`, and any deviation must carry its reason in the region's `comments` block.
