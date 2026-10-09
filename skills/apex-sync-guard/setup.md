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

Dependencies: `git`, SQLcl on PATH, and `jq` *or* `python3` (JSON parsing falls back automatically). The scripts probe the parser by **running** it, so a `python3` that exists without executing — the Microsoft Store stub — is rejected with that named as the likely cause instead of failing mid-run.

**Platform.** These are bash scripts: Linux and macOS natively; on **Windows they need Git Bash (Git for Windows) or WSL** — PowerShell and cmd cannot execute them, and Claude Code's Bash tool on Windows already uses Git Bash, so agent-driven use works out of the box. Paths handed to SQLcl (a Java program) are converted with `cygpath` automatically, and quoted when they hold spaces. If an export still fails with a path containing spaces, point `TMPDIR` at one that has none — how SQLcl tokenizes `-dir` there has not been confirmed. `apex-sync-check.sh doctor` validates all of this on a new machine in one command.

Sync **state** is machine-local and never committed: git ref `refs/apex-sync/<appAlias>` (the BASE tree) plus `.git/apex-sync/<appAlias>/state.json` (timestamps, last `LAST_UPDATED_ON` seen) and the freshness marker used by the hook. The Builder is per-environment — your DEV syncpoint means nothing on another machine.

## 2. First syncpoint (bootstrap)

With no BASE yet, `check-import` cannot 3-way compare; it degrades to REMOTE-vs-LOCAL:

```bash
<skill-dir>/scripts/apex-sync-check.sh check-import
```

- Zero diff → the replicas already agree; the script records the first syncpoint automatically.
- Diff → reconcile manually once (decide side by side which replica wins per file), commit, import or export accordingly, then `record-sync`.

## 3. Enforcement hook (Claude Code)

Layer 2 on top of process discipline: a `PreToolUse` hook that blocks an import or an export — in any of the lanes listed below — unless a fresh sync-check marker for that direction exists (TTL 10 min).

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

On a match without a fresh marker it exits 2 with the reason on stderr, which blocks the call and tells the agent to run `check-import` / `check-export` first. The marker is written only by a PASSing check, withdrawn as soon as the next check of that direction starts, and keyed to the app alias. Two refusals hold even with a fresh marker, because they are the user's call: `record-sync --force`, and any write to the guard's own markers, `refs/apex-sync/*` or `.git/apex-sync/` state. Once a command looks relevant, a failure of the hook itself (an unreadable config, git refusing the repo, a marker age it cannot compute) blocks rather than allows.

Known trade-off: the hook matches the command **text**. A command that only *mentions* an import or export together with one of its flags — `echo "apex export -applicationid 1"`, a commit message quoting `apex import -input …` — is gated like a real one; the bare phrase without a flag or launcher is not, so grepping for it or reading the guard's own source stays possible. Rephrase or run the corresponding check; erring on the blocking side is the point — a false positive costs one rephrase, a false negative overwrites a replica. Expect an agent meeting this for the first time to report it as a bug; it is not. (It also makes the hook cheap to test — see §4.)

The opposite limit is a declared gap: an import the command text does not show — `sql @script.sql` whose script imports, a wrapper script under another name, an MCP tool — never reaches the pattern match. There the check script is the whole protocol.

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

Expected: **blocked**, exit 2, with the guard's reason on stderr. Four cases worth covering, all by touching `"$SB/repo"/.git/apex-sync/hook-test/check-ok.<direction>` between runs — from your own terminal: the hook refuses an agent that writes markers:

| Marker state | Command | Expected | Proves |
|---|---|---|---|
| absent | `echo "apex export -applicationid 1"` | blocked | the hook is registered and fires |
| fresh `check-ok.export` | the same | allowed | a PASSing check really unblocks |
| `check-ok.export` aged with `touch -d '11 minutes ago'` | the same | blocked | the 10-min TTL is enforced, not just presence |
| fresh `check-ok.export` only | `echo "apex import -input x"` | blocked | direction-awareness — one check does not authorize the other |

`tests/integration/sync-guard-e2e.sh` runs these four commands through the hook, so this table cannot drift from what the hook does.

`rm -rf "$SB"` when done. Note the hook resolves the repo from the **session's** cwd, not from any `cd` inside the command — so the run must start inside the onboarded repo.
