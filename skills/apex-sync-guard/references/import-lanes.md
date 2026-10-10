# What counts as an import

Not just `apex import`. Every lane below is the same total overwrite of the Builder with a
different command text; `check-import` gates them all, and the hook recognizes them:

| Lane | Command | Oracle version |
|---|---|---|
| SQLcl directly | `apex import` / `apex imp`, with an option (`-input`/`-i`, `-id`, …) or a SQLcl launcher in the command — a bare `apex import` imports the **current directory** | any |
| Oracle's deploy script | `apexlang-deploy/scripts/deploy-apex-app.sh <app-directory>` — it issues `apex import -input "$app_directory"` inside its own heredoc, so the phrase never reaches the command line | 26.1 and 26.2 (the only import lane on 26.2) |
| the generation package's roundtrip | `apexctl … runtime roundtrip --import-intent validate-and-import` — it builds a SQLcl script holding `apex import -input …` and runs it in a subprocess (`apexlang-generation/references/ops/runtime-gates.md` §Canonical Validation 9) | 26.1 |

The hook gates `runtime roundtrip` whatever its intent says: the default intent is
`validate-only`, so a bare roundtrip is over-blocked on purpose — one 20-second check is
cheaper than trusting a reading of an upstream default.

Exports likewise: `apex export`, its `export-*` subcommands and their short forms (`ex`,
`exap`, `exaa`, `exco`, `exin`, `exsf`, `exwo`, …). An export with no app id
(`export-all-applications`, a `-workspaceid` export) writes every app's tree.

With several apps in `apex-sync.json`, the hook requires the check of **the app each
invocation acts on**, read from `-input`/`-i`, `--app-path`, the deploy script's argument, or
`-id`/`-applicationid`; an invocation it cannot trace to one app is blocked — one that names its
app does not vouch for another in the same command (`setup.md` §1).

Whatever the number of apps, a command is blocked when it reaches another onboarded repo than
the session's (a `cd` into it, a path pointing into it), and when its SQLcl launcher connects
through another saved connection than the app was checked through (`sql -name prod …`).

What the hook cannot see — an import inside `sql @script.sql`, a wrapper under another name,
an MCP tool — is a declared gap (`framework/CAPABILITIES.md` GAP-1): there, the check script
is the whole protocol.
