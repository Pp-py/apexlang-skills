# The model: three replicas, one syncpoint

| Role | What | Materialized as |
|---|---|---|
| BASE | the last synchronized state | a git tree under the local ref `refs/apex-sync/<app-alias>` + `.git/apex-sync/<app-alias>/state.json` |
| LOCAL | your working tree | the app's APEXlang source dir in the repo (`<apexlangDir>/<appAlias>`) |
| REMOTE | the Builder | `apex export` to a scratch dir — the export is byte-stable: zero diff means genuinely untouched |

Same 3-way logic as `git pull` before `push`: if REMOTE moved since BASE, integrate before
overwriting.

**Canonical space.** BASE is always snapshotted from an `apex export`, never from the raw
working tree: hand-edited `.apx` differ *textually* from the exporter's canonical
serialization (whitespace, fenced vs inline blocks, JSON spacing) without differing
semantically. BASE↔REMOTE comparisons are therefore noise-free; only the one-time bootstrap
(BUILDER vs LOCAL, no BASE yet) can surface formatting-only diffs, which reconcile by
adopting the canonical form.

**Comparison is byte-exact and independent of your git config.** Replicas are compared
byte for byte (`cmp`, or `git hash-object --no-filters` where `cmp` is unavailable), never
with `git diff --no-index`: git applies `.gitattributes` / `core.autocrlf` to whichever
side it resolves inside the repo and not to the scratch export, so its verdict tracked the
machine's git settings instead of the content (with `core.autocrlf=true` — the
Git-for-Windows default — a CRLF and an LF copy of the same file compare *equal*).

**Line endings never gate.** Files that differ **only** in line endings are reported as
`E` and do not block: that difference cannot carry a Builder-side change, and blocking on
it would deadlock, since every re-export reintroduces it. Oracle's own roundtrip contract
normalizes too — "Normalize every `.apx` source file from CRLF or CR to LF" before validate
and import (`apexlang-generation/references/ops/runtime-gates.md`). Silence them with
`*.apx text eol=lf` in the consuming repo's `.gitattributes`.

**Why always an export.** Dictionary timestamps cannot gate a check: an APEXlang import
recreates components with NULL audit columns, so `LAST_UPDATED_ON`/`LAST_UPDATED_BY` feed
only the best-effort who/when report. Every check exports (~20 s).
