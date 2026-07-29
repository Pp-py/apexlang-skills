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

Known trade-off: the hook matches the command **text**, so a command that merely *mentions* `apex import`/`apex export` (an `echo`, a `git commit -m` message) is also gated. Rephrase or run the corresponding check; erring on the blocking side is the point — a false positive costs one rephrase, a false negative overwrites a replica. Expect an agent meeting this for the first time to report it as a bug; it is not. (It also makes the hook cheap to test — see §4.)

Other agents (Codex, opencode, …) don't get the hook — for them the wrapper script IS the protocol; `AGENTS.md` in this repo instructs loading the skill before any import/export.

## 4. Smoke test the wiring

```bash
<skill-dir>/scripts/apex-sync-check.sh status
```

Expected: config found, connection OK, syncpoint present (or "no syncpoint yet — bootstrap needed").

Then prove the hook actually fires. **Do not use a real `apex export` for this** — if the hook is broken, the test overwrites a replica, which is the very thing being guarded. Because the matcher is text-based (§3), `echo "apex export"` trips it identically and does nothing if it gets through.

Isolate the run so a smoke test cannot disturb your own setup — `--plugin-dir` loads the plugin for one run, so nothing is installed and no marketplace is added:

```bash
SB=$(mktemp -d); mkdir -p "$SB/repo" "$SB/cfg"
git -C "$SB/repo" init -q
printf '{ "appId": 1, "appAlias": "hook-test" }\n' > "$SB/repo/apex-sync.json"
ln -s ~/.claude/.credentials.json "$SB/cfg/.credentials.json"   # else: "Not logged in"

cd "$SB/repo" && CLAUDE_CONFIG_DIR="$SB/cfg" claude -p \
  'Run exactly this bash command and report whether it was blocked: echo "apex export"' \
  --plugin-dir <path-to-this-repo> --allowedTools Bash
```

Expected: **blocked**, exit 2, with the guard's reason on stderr. Four cases worth covering, all by touching `"$SB/repo"/.git/apex-sync/hook-test/check-ok.<direction>` between runs:

| Marker state | `apex export` | Proves |
|---|---|---|
| absent | blocked | the hook is registered and fires |
| fresh | allowed | a PASSing check really unblocks |
| `touch -d '11 minutes ago'` | blocked | the 10-min TTL is enforced, not just presence |
| fresh `check-ok.export`, then run `apex import` | blocked | direction-awareness — one check does not authorize the other |

`rm -rf "$SB"` when done. Note the hook resolves the repo from the **session's** cwd, not from any `cd` inside the command — so the run must start inside the onboarded repo.
