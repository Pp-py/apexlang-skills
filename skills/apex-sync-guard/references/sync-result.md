# Reading a sync-result

Every `check-import`, `check-export` and `record-sync` run writes its verdict as JSON — the
schema is `framework/schemas/sync-result.schema.json` (stable, `schemaVersion: 1`):

- always `.git/apex-sync/<alias>/last-<operation>.json`;
- with `--task <id>`, also `<evidenceDir>/<id>/sync-<alias>-<operation>.json` — the copy an
  orchestrator reads. The evidence dir is created with a `.gitignore` of `*`.

A placeholder (`UNKNOWN`, `INTERRUPTED`) is written when the run starts, so a run killed
half-way never leaves the previous verdict behind. **The JSON is the verdict; the exit code
mirrors it.** A run stopped before it knew its app (no repo, no SQLcl, an invalid config,
`--app` missing with several apps) writes no file: exit 2 is BLOCKED.

| Field | Says |
|---|---|
| `status`, `reasons[0].code` | the verdict and why — catalog below |
| `marker` | checks only: `written` is true exactly when the check PASSed; `expiresAt` = 5 minutes later; the marker itself also records the source dir and its tree, which the hook checks |
| `changes[]` | check-import: Builder-side differences (`A` only in the Builder, `D` only in the reference, `M` differs, `E` line endings only — never gating); check-export: what is dirty |
| `payload` | check-import with a syncpoint: what the import **deploys** (LOCAL vs BASE) and how many commits since the syncpoint |
| `basis` | record-sync: `fresh-check`, `builder-unchanged`, `local-equals-builder` or `forced` |
| `syncpoint` | the ref, its commit after the run, and whether this run recorded it |
| `context` | task, repo commit and dirtiness, framework version, timestamp, connection, SQLcl and APEX versions when the run reached the Builder |
| `evidence[]` | what the verdict rests on: the Builder export, the existence query, the snapshot |

| Status | Reason codes |
|---|---|
| PASS | `FIRST_PUBLICATION` · `BOOTSTRAP_IN_SYNC` · `BUILDER_UNCHANGED` · `BUILDER_CHANGES_CAPTURED` · `LOCAL_CLEAN` · `SYNCPOINT_RECORDED` |
| CONFLICT | `BOOTSTRAP_DIVERGED` · `BUILDER_DIVERGED` — see `resolution.md` |
| FAIL | `LOCAL_DIRTY` |
| BLOCKED | `STATE_UNWRITABLE` · `SOURCE_DIR_MISSING` · `APP_ID_MISMATCH` · `SYNCPOINT_WITHOUT_APP` · `NO_FRESH_CHECK` (and, with no file: `USAGE` · `UNSUPPORTED_SHELL` · `NO_GIT` · `NO_SQLCL` · `NO_JSON_PARSER` · `NO_CONFIG` · `CONFIG_INVALID` · `APP_REQUIRED` · `APP_UNKNOWN`) |
| UNKNOWN | `EXPORT_FAILED` · `SNAPSHOT_FAILED` · `INTERRUPTED` · `UNEXPECTED_ERROR` — nothing is authorized; re-run |

Paths in a result are repo-relative; the repo root and `$HOME` are redacted from messages
(`framework/EVIDENCE.md`).
