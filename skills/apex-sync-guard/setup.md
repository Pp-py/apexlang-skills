# apex-sync-guard — setup

One-time wiring per project repo. Three pieces: config file, first syncpoint, enforcement hook.

## 1. Per-project config: `apex-sync.json`

Committed at the **project repo root**. Everything the guard needs to know about the app:

```json
{
  "appId": 100,
  "appAlias": "demo-app",
  "apexlangDir": "apex/apexlang",
  "sqlclConnection": "dev_demo",
  "ignorePaths": ["apex-exports/"]
}
```

- `apexlangDir` — the directory passed to `apex export -dir` (its child `<appAlias>/` holds the `.apx` tree).
- `sqlclConnection` — SQLcl saved connection name (`sql -name <conn>`); the schema must be able to read `APEX_APPLICATION_PAGES` for the app.
- `ignorePaths` (optional) — paths relative to the app dir that exist only on one side by design (repo-only artifacts living inside the app dir, e.g. an `apex-exports/` folder with legacy SQL exports). Excluded from all comparisons.
- `testUser` / `runtimeUrl` (optional) — read by **apex-sentinel**, not by the guard: the runtime app's test user and its URL, so a verification run doesn't rediscover them. Both are ordinary config; the password is **not** and never belongs in this file, which is committed (see `skills/apex-sentinel/setup.md` §2).
- `uiGate`, `securityGate` (optional, `true`/`false`, default `false`) — read by the orchestrator, not by the guard: make **apex-ux**'s UI gate and **apex-security**'s Security gate required for the app (`framework/GATES.md`). Opt-in until 1.0.0. The guard checks only that they are booleans.
- `publicPages` (optional, an array of page numbers) and `lowPrivUser` (optional, a user name) — read by **apex-security**, not by the guard: the app's public pages besides the login page, each also carrying a `public page review: <reason>` comment in its `.apx`; and a test user without the app's roles, its password in `$APEX_TEST_PASSWORD_LOW[_<ALIAS>[_<ENV>]]` or the gitignored `.env`, never here. The guard checks only their types.
- `evidenceDir` (optional, default `.apex-evidence`) — where a gate run given `--task <id>` also writes its JSON result (`<evidenceDir>/<id>/sync-<appAlias>-<operation>.json`). Created with a `.gitignore` of `*`, so evidence is never committed by accident; every run also leaves `.git/apex-sync/<appAlias>/last-<operation>.json`.

**Several apps in one repo.** A workspace often holds more than one live app, and one repo can carry all of them. List them in `apps[]`; the top-level `apexlangDir`, `sqlclConnection`, `ignorePaths`, `testUser`, `runtimeUrl`, `uiGate`, `securityGate`, `publicPages` and `lowPrivUser` are then defaults that each app may override (`ignorePaths` is replaced, never merged), and `evidenceDir` stays repo-wide:

```json
{
  "apexlangDir": "apex/apexlang",
  "sqlclConnection": "dev_ws",
  "apps": [
    { "appId": 100, "appAlias": "rrhh", "testUser": "QA_RRHH", "runtimeUrl": "https://<host>/ords/r/<workspace>/rrhh/" },
    { "appId": 101, "appAlias": "ventas", "sqlclConnection": "dev_ventas" }
  ]
}
```

- Every gate command then names its app — `check-import --app rrhh`, `record-sync --app rrhh` — and is BLOCKED without one: the guard does not guess. `status`, `doctor` and `apps` (the resolved list) cover every app unless given `--app`.
- Each app keeps its own syncpoint, markers and results, all keyed by alias. Aliases must differ ignoring case (they name refs and directories), two entries cannot be the same Builder app (same `appId` through the same connection), and source dirs (`<apexlangDir>/<appAlias>`) must not overlap. An unknown key inside an app is an error, not a note: a typo there would silently fall back to the default — the right app checked through the wrong connection.
- `check-export` of one app ignores dirty files in the other apps' dirs: exporting that app does not write there.
- The hook requires the check of the app a command acts on, read from the command: `-input`/`-i`, `--app-path` or the deploy script's argument (a source dir, or a file in one), `-id`/`-applicationid` (an app id). What it cannot trace to one app — a bare `apex import` (the current directory), the shared parent dir, a `.zip`, a path computed at run time — is blocked, with the dirs and ids that would make it traceable. An export with no app id (`export-all-applications`, a `-workspaceid` export) needs every app's check.

**Environments of one app.** When one app's source deploys to more than one Builder — DEV and PROD, or QA, UAT and PROD, as many as your way of working has — declare them in the app's `environments` (inside each app of `apps[]`, or at the top level in the one-app shape). Each takes `sqlclConnection` (required: its own Builder), and optionally `appId` (when the id differs there), `runtimeUrl`, `testUser` and `protected`; what it does not set comes from the app:

```json
{ "appId": 100, "appAlias": "rrhh", "apexlangDir": "apex/apexlang",
  "environments": {
    "dev":  { "sqlclConnection": "dev_rrhh",  "runtimeUrl": "https://<host-dev>/ords/r/<workspace>/rrhh/" },
    "prod": { "sqlclConnection": "prod_rrhh", "protected": true } } }
```

- Every gate command names the environment — `check-import --env dev` (with `--app` when there are several apps) — and is BLOCKED without it: nothing is checked against, or deploys to, an environment nobody named. `pw.sh` and `evidence.py` take `--env` the same way.
- Each environment keeps its own syncpoint, markers and results, keyed `<alias>.<env>`: ref `refs/apex-sync/rrhh.dev`, results `sync-rrhh.dev-check-import.json`, `"environment": "dev"` in each result. The source dir is the app's, shared by all its environments.
- The hook reads the environment from the saved connection the command names (`sql -name dev_rrhh …`) and requires that environment's marker. A command that names none of them — a bare `apex import`, or a connect string such as Oracle's deploy script takes — is blocked: the guard cannot tell which Builder it reaches.
- `"protected": true` — the hook blocks every import or export an agent runs into that environment, whatever the checks say; the user runs it, outside the agent. Checks and `record-sync` still work there (they only read the Builder). **Risk** without it: an agent holding a fresh check could import to production. **Rollback**: remove the key.
- Moving an existing app to environments starts each environment from its first `check-import` (bootstrap). To keep today's syncpoint for one of them, copy the ref yourself — a write the guard never makes for you: `git update-ref refs/apex-sync/rrhh.dev refs/apex-sync/rrhh`.

Dependencies: `git`, SQLcl on PATH, and `jq` *or* `python3` (JSON parsing falls back automatically). The scripts probe the parser by **running** it, so a `python3` that exists without executing — the Microsoft Store stub — is rejected with that named as the likely cause instead of failing mid-run.

**Platform.** These are bash scripts: Linux and macOS natively; on **Windows they need Git Bash (Git for Windows) or WSL** — PowerShell and cmd cannot execute them, and Claude Code's Bash tool on Windows already uses Git Bash, so agent-driven use works out of the box. Paths handed to SQLcl (a Java program) are converted with `cygpath` automatically, and quoted when they hold spaces. If an export still fails with a path containing spaces, point `TMPDIR` at one that has none — how SQLcl tokenizes `-dir` there has not been confirmed. `apex-sync-check.sh doctor` validates all of this on a new machine in one command.

Sync **state** is machine-local and never committed: git ref `refs/apex-sync/<appAlias>` (the BASE tree) plus `.git/apex-sync/<appAlias>/state.json` (timestamps, last `LAST_UPDATED_ON` seen) and the freshness marker used by the hook. The Builder is per-environment — your DEV syncpoint means nothing on another machine. In a linked worktree (`git worktree add`) the ref and `state.json` stay shared with the main checkout, while the markers and last results are the worktree's own, under `.git/worktrees/<name>/apex-sync/`: a check authorizes an import only from the worktree whose LOCAL it compared.

## 2. First syncpoint (bootstrap)

With no BASE yet, `check-import` cannot 3-way compare; it degrades to REMOTE-vs-LOCAL:

```bash
<skill-dir>/scripts/apex-sync-check.sh check-import
```

- Zero diff → the replicas already agree; the script records the first syncpoint automatically.
- Diff (CONFLICT, `BOOTSTRAP_DIVERGED`) → reconcile once, file by file, deciding which replica wins — there is no BASE to tell which side moved:
  - **where the Builder wins**, copy its file from the kept export into LOCAL and commit. Once LOCAL matches the Builder everywhere, `check-import` PASSes and records the first syncpoint.
  - **where LOCAL must win**, the Builder holds nothing worth keeping — but only the user can declare that: they run `record-sync --force` in their own terminal, which records the current Builder as BASE. Then `check-import` PASSes, the import pushes LOCAL, and `record-sync` follows it.

  `record-sync` without `--force` refuses here (`NO_FRESH_CHECK`), by design: an agent clearing a CONFLICT that way would erase exactly the Builder work the check was about.

## 3. Enforcement hook (Claude Code)

Layer 2 on top of process discipline: a `PreToolUse` hook that blocks an import or an export — in any of the lanes listed below — unless a fresh sync-check marker for that direction exists (TTL 5 min) and the source dir still hashes to the tree it records.

The matcher names **both** shell tools — `Bash|PowerShell` — because Claude Code exposes them as two separate tools (`PowerShell` is not an alias of `Bash`, so a `Bash`-only matcher never fires on a Windows-native session). Widening it is safe precisely because the hook is **shell-agnostic**: both tools carry the same `tool_input.command` field, and the hook reads that text and pattern-matches it. It executes nothing from the caller's shell, so there is no shell syntax for it to get wrong. A matcher of that shape (letters and pipes only) is compared by **exact tool name**, not as a loose regex — it matches those two tools and nothing else.

**Installed as a plugin?** Nothing to do — the plugin registers the hook itself (repo-root `hooks/hooks.json`, resolved via `${CLAUDE_PLUGIN_ROOT}`). It is safe globally: in a repo without `apex-sync.json` (or outside a git repo) the hook exits 0 and polices nothing.

**Running from a local clone / symlinks?** Register it in the **project's** `.claude/settings.json`, with the absolute path to *your* clone:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash|PowerShell",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"<path-to-your-clone>/apexlang-skills/skills/apex-sync-guard/scripts/apex-sync-hook.sh\""
          }
        ]
      }
    ]
  }
}
```

The explicit `bash` prefix is what makes it portable: on Windows a bare `.sh` path depends on which shell the hook runner happens to use, while `bash <path>` works either way (and is harmless on Linux/macOS).

The hook reads the tool call JSON on stdin and gates these lanes; every other command passes through untouched:

- **`apex import` / `apex export`** (and `apex export-*`) — when the command also carries a flag a real invocation runs with (`-input`, `-id`, `-applicationid`, `-dir`, `-split`, …) **or** a SQLcl launcher (`sql`, `sql.exe`, `sqlcl`, `$SQLCL_BIN`). A bare `apex import` imports the current directory, so `sql -name dev <<< "apex import"` is a real import with no flag in it.
- **Oracle's deploy script** `deploy-apex-app.sh` (26.1 and 26.2) — its `apex import` lives in a heredoc the hook never sees, so any command naming the script is an import unless every segment of it starts with a plain reader (`cat`, `grep`, `sed`, `less`, …).
- **The 26.1 generation package's own lane** — `apexctl … runtime roundtrip`, or `--runtime-action`/`--import-intent validate-and-import`: `roundtrip` runs `apex import` inside a SQLcl subprocess.

On a match without a fresh marker it exits 2 with the reason on stderr, which blocks the call and tells the agent to run `check-import` / `check-export` first. The marker is written only by a PASSing check, keyed to the app alias, and withdrawn whenever a check of that direction does not PASS — even one stopped before it began (a bad option, no SQLcl, an invalid config). Refused even with a fresh marker:

- `record-sync --force`, and any write to the guard's own markers, `refs/apex-sync/*` or `.git/apex-sync/` state — the user's call;
- a command that reaches **another** onboarded repo than the session's — a `cd`/`pushd` into it, or a path pointing into it — since the markers checked are the session repo's (from a session outside any onboarded repo, it would be checked against none); a `cd` to a directory computed at run time blocks for the same reason;
- a command whose SQLcl launcher connects through another saved connection than the one the app was checked through (`sql -name prod …` after a check through `dev`).

Once a command looks relevant, a failure of the hook itself (an unreadable config, git refusing the repo, a marker age it cannot compute, a parser that reads nothing) blocks rather than allows.

Known trade-off: the hook matches the command **text**. A command that only *mentions* an import or export together with one of its flags — `echo "apex export -applicationid 1"`, a commit message quoting `apex import -input …` — is gated like a real one; the bare phrase without a flag or launcher is not, so grepping for it or reading the guard's own source stays possible. Rephrase or run the corresponding check; erring on the blocking side is the point — a false positive costs one rephrase, a false negative overwrites a replica. Expect an agent meeting this for the first time to report it as a bug; it is not. (It also makes the hook cheap to test — see §4.)

The opposite limit is a declared gap: an import the command text does not show — `sql @script.sql` whose script imports, a wrapper script under another name, an MCP tool, a path held in a variable — never reaches the pattern match. There the check script is the whole protocol.

Other agents (Codex, opencode, …) don't get the hook — for them the wrapper script IS the protocol; `AGENTS.md` in this repo instructs loading the skill before any import/export.

## 4. Smoke test the wiring

```bash
<skill-dir>/scripts/apex-sync-check.sh doctor
```

Checks, by exercising each one rather than by looking for it on PATH: shell and platform (plus `cygpath` on Windows), `git`, SQLcl, the JSON parser, `apex-sync.json` and its fields, the state dir, that the connection answers **and that it can actually see this `appId`** (a wrong saved connection is otherwise only discovered mid-import), and the syncpoint. Non-zero exit if anything failed. `status` remains the quick look at syncpoint age and both replicas.

Then prove the hook actually fires. **Do not use a real `apex export` for this** — if the hook is broken, the test overwrites a replica, which is the very thing being guarded. Because the matcher is text-based (§3), `echo "apex export -applicationid 1"` trips it identically and does nothing if it gets through. Keep the flag: a bare `echo "apex export"` is a mention, not an export, and passes.

Isolate the run so a smoke test cannot disturb your own setup — `--plugin-dir` loads the plugin for one run, so nothing is installed and no marketplace is added:

```bash
SB=$(mktemp -d); mkdir -p "$SB/repo" "$SB/cfg"
git -C "$SB/repo" init -q && mkdir -p "$SB/repo/.git/apex-sync/hook-test"
printf '{ "appId": 1, "appAlias": "hook-test" }\n' > "$SB/repo/apex-sync.json"
ln -s ~/.claude/.credentials.json "$SB/cfg/.credentials.json"   # else: "Not logged in"

cd "$SB/repo" && CLAUDE_CONFIG_DIR="$SB/cfg" claude -p \
  'Run exactly this bash command and report whether it was blocked: echo "apex export -applicationid 1"' \
  --plugin-dir <path-to-this-repo> --allowedTools Bash
```

Expected: **blocked**, exit 2, with the guard's reason on stderr. Five cases worth covering, all by writing `"$SB/repo"/.git/apex-sync/hook-test/check-ok.<direction>` between runs — from your own terminal: the hook refuses an agent that writes markers. A marker is bound to the source it checked (GAP-9); the sandbox has no `hook-test/` dir, which git hashes as its empty tree, so a valid marker for it is:

```bash
M="$SB/repo/.git/apex-sync/hook-test"
printf '{"check":"export","src":"hook-test","tree":"4b825dc642cb6eb9a060e54bf8d69288fbee4904"}\n' > "$M/check-ok.export"
```

| Marker state | Command | Expected | Proves |
|---|---|---|---|
| absent | `echo "apex export -applicationid 1"` | blocked | the hook is registered and fires |
| fresh `check-ok.export`, written as above | the same | allowed | a PASSing check really unblocks |
| `check-ok.export` aged 6 minutes (`touch -d '6 minutes ago'`; on macOS `touch -t <CCYYMMDDhhmm>`) | the same | blocked | the 5-min TTL is enforced, not just presence |
| fresh, but `mkdir "$SB/repo/hook-test" && echo x > "$SB/repo/hook-test/p.apx"` after it | the same | blocked | the marker speaks only for the source it checked |
| fresh `check-ok.export` only (the dir removed again) | `echo "apex import -input x"` | blocked | direction-awareness — one check does not authorize the other |

`tests/integration/sync-guard-e2e.sh` runs these commands through the hook, so this table cannot drift from what the hook does.

`rm -rf "$SB"` when done. Note the hook resolves the repo from the **session's** cwd, not from any `cd` inside the command — so the run must start inside the onboarded repo.
