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

Dependencies: `git`, SQLcl on PATH, and `jq` *or* `python3` (JSON parsing falls back automatically).

Sync **state** is machine-local and never committed: git ref `refs/apex-sync/<appAlias>` (the BASE tree) plus `.git/apex-sync/<appAlias>/state.json` (timestamps, last `LAST_UPDATED_ON` seen) and the freshness marker used by the hook. The Builder is per-environment — your DEV syncpoint means nothing on another machine.

## 2. First syncpoint (bootstrap)

With no BASE yet, `check-import` cannot 3-way compare; it degrades to REMOTE-vs-LOCAL:

```bash
<skill-dir>/scripts/apex-sync-check.sh check-import
```

- Zero diff → the replicas already agree; the script records the first syncpoint automatically.
- Diff → reconcile manually once (decide side by side which replica wins per file), commit, import or export accordingly, then `record-sync`.

## 3. Enforcement hook (Claude Code)

Layer 2 on top of process discipline: a `PreToolUse` hook that blocks any Bash command containing `apex import` / `apex export` unless a fresh sync-check marker exists (TTL 10 min).

**Installed as a plugin?** Nothing to do — the plugin registers the hook itself (repo-root `hooks/hooks.json`, resolved via `${CLAUDE_PLUGIN_ROOT}`). It is safe globally: in a repo without `apex-sync.json` (or outside a git repo) the hook exits 0 and polices nothing.

**Running from a local clone / symlinks?** Register it in the **project's** `.claude/settings.json`, with the absolute path to *your* clone:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "<path-to-your-clone>/apexlang-skills/skills/apex-sync-guard/scripts/apex-sync-hook.sh"
          }
        ]
      }
    ]
  }
}
```

The hook reads the tool call JSON on stdin; commands not matching `apex\s+(import|export)` pass through untouched. On a match without a fresh marker it exits 2 with the reason on stderr, which blocks the call and tells the agent to run `check-import` / `check-export` first. The marker is written by a PASSing check and keyed to the app alias.

Known trade-off: the hook matches the command **text**, so a command that merely *mentions* `apex import`/`apex export` (an `echo`, a `git commit -m` message) is also gated. Rephrase or run the corresponding check; erring on the blocking side is the point.

Other agents (Codex, opencode, …) don't get the hook — for them the wrapper script IS the protocol; `AGENTS.md` in this repo instructs loading the skill before any import/export.

## 4. Smoke test the wiring

```bash
<skill-dir>/scripts/apex-sync-check.sh status
```

Expected: config found, connection OK, syncpoint present (or "no syncpoint yet — bootstrap needed"). Then try `sql -name <conn>` + `apex export` through your agent WITHOUT running a check first: the hook must block it.
