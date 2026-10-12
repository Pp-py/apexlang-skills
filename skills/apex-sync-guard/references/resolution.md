# Resolution when the Builder moved

`check-import` failed with **CONFLICT**: the Builder holds work an import would destroy.
Per differing file (the report and `changes[]` in the result list them; the Builder export
is kept in scratch):

- **Changed only in the Builder** (LOCAL == BASE for it): copy it from the scratch export
  over the source dir, and commit it as "capture Builder changes".
- **Changed on both sides**: an ordinary 3-way text merge, per file — materialize its BASE
  version from the syncpoint ref and let git merge it:

  ```bash
  git show refs/apex-sync/<alias>:<alias>/<file> > /tmp/base.apx
  git merge-file <source-dir>/<file> /tmp/base.apx <scratch>/<alias>/<file>
  ```

  Resolve any conflict markers, commit. Do NOT merge the syncpoint ref as a branch — it
  shares no history with yours; `merge-file` is the right tool.

Then re-run `check-import`: it PASSes once LOCAL contains every Builder-side change
(`BUILDER_CHANGES_CAPTURED` — importing rewrites those files identically, losing nothing).
Then validate, run `check-import` once more as the last step before the import (its PASS lapses
in 5 minutes and speaks only for the LOCAL it compared), import, `record-sync`.

**Never `record-sync` to clear a CONFLICT.** It would record the Builder as BASE, the next
check would PASS, and the import would destroy exactly the work the CONFLICT was about.
`record-sync` refuses without a basis (`NO_FRESH_CHECK`); only the user may decide the current
Builder *is* the new truth, with `record-sync --force` in their own terminal.

**First publication into a new workspace.** With no syncpoint, an app absent from the target
workspace PASSes (`FIRST_PUBLICATION`) — there is no second replica. With a syncpoint on
record, "not visible" means a wrong connection, workspace or app id, and it is BLOCKED
(`SYNCPOINT_WITHOUT_APP`); the message names the user's escape (setting the old syncpoint aside).
