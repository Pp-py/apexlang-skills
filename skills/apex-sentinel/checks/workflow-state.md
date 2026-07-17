# Check: workflow / state transition

**Verifies** `apexlang-architecture/recipes/workflow-state-transitions.md`: transitions are package operations with legal-state guards, surfaced as state changes.

**REQUIRED BACKGROUND:** `setup.md` and `SKILL.md` §Snapshot diet.

## Steps

1. Navigate to the master list of requests (`?session=<token>`). Assert rows render with **status badges** via `eval` — read the badge texts directly (e.g. `[...document.querySelectorAll('.t-Badge, [class*="badge"]')].map(b => b.innerText)`) instead of snapshotting. Take **one** snapshot only if you still need the action icon's ref.
2. Open the resolve modal for a row **in a transitionable state** (click its action icon — the real way, so APEX sets the PK item).
3. `click` a transition button (e.g. **Approve**). Each button submits its `buttonName` as `:REQUEST`, gating exactly one process.
4. Assert the **state changed** cheaply: dialog closed + the row's badge text is now the target state (`eval`, or `wait` for the new badge text — not a re-snapshot). Confirm with SQLcl that `status` and the audit stamp (`approved_by`/`approved_at`) changed — **and any side effect** (e.g. a quota deducted) applied.

## Illegal-transition path (non-mutating)

Try to transition a row **not** in the legal from-state (e.g. approve an already-approved one — or confirm those buttons are correctly hidden by `serverSideCondition`, via `eval` for the button's absence). Assert the package's guard error appears in the notification region (friendly, no `ORA-` prefix) and `status` is unchanged.

## Pass criteria

- Badges render; legal transition flips the badge + audit stamp + side effect.
- Illegal transition is blocked (button hidden or package guard error); state unchanged.
- No process wrote `status` directly (the guard/side-effect prove it routed through the package verb).
