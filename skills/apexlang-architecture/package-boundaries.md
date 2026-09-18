# Package boundaries — which package, and when none

`back-end-conventions.md` says **how** a write-path package is built. This file says **which** package
a piece of logic belongs to, and when the answer is *no package at all*.

**One package per table is the default, not the obligation.** Read as a CRUD mapping — *1 table =
1 package* — it produces this skill's own failure mode one layer up: a package that starts as an
entity's API and ends as the centre of the business.

```text
pkg_orders                      -- started here: an entity's API
├── create_order
├── update_order
├── delete_order
├── calculate_total
├── confirm_order
├── cancel_order
├── reserve_inventory           -- another entity's write
├── process_payment             -- another entity's write
├── send_confirmation           -- an external system
├── generate_invoice            -- another entity's write
└── notify_customer             -- an external system
```

Nothing in *1 table = 1 package* forbids that package. The question it never asks is the one that
does: **who is responsible for this rule?**

## Why a package at all

Without one, the business logic **is** the page:

```text
APEX page process
    UPDATE orders    SET status = 'CONFIRMED' ...
    UPDATE inventory SET qty_on_hand = qty_on_hand - :QTY ...
    INSERT INTO payments ...
    UPDATE customers SET last_order_at = SYSDATE ...
```

That sequence *is* the rule "what it means to confirm an order" — living in one page, invisible to
every other caller, and retyped (differently) the next time someone confirms an order from a job.
With a package, the page states an intent and nothing else:

```text
APEX page process
    pkg_sales_flow.confirm_order(p_order_id => :P10_ORDER_ID);
```

| Reason | What it buys |
|---|---|
| **It is a contract with APEX** | The `.apx` names an operation instead of describing a mutation. The declarative front stays declarative, and a page diff stops being a business-logic diff. |
| **Invariants get one testable home** | "Cannot confirm without stock" is asserted in one place and callable from SQLcl with no browser. A rule spread across page processes cannot be tested at all. |
| **The UI cannot bypass it** | A job, an ORDS handler, SQLcl and next quarter's second page all hit the same guard. A validation in a grid column fires only in that grid. |
| **The second consumer is free** | Mobile, REST, a batch import — they call the operation instead of re-implementing it. |

The cost is ~30 lines. The three standard rationalizations for skipping it are answered in
`SKILL.md` §Common mistakes; none of them is an exception (see *Not exceptions* below).

## The three layers

```text
.apx  — states intents; calls named operations, never raw DML
  │
  ├──────────────► pkg_<flow>_flow      coordinates several entities, writes nothing
  │                        │
  └──────────────► pkg_<entity>         its table + its satellites
                           │
                           ▼
                    Database
                      ├── constraints   invariants of the data's shape
                      ├── tables
                      └── v_* / SQL     every read

pkg_<system>_api    one external system's protocol
pkg_errors          the -20xxx catalog (owns no table — `examples/00-pkg_errors.sql`)
f_*                 lookup/LOV function, on the entity package
```

The flow package sits **between** the `.apx` and the entity packages — never underneath them.

| Layer | Named | Owns | Must never |
|---|---|---|---|
| **Entity** | `pkg_<entity>` | one entity's table, its **satellite** tables, and that entity's rules | write another entity's table |
| **Domain** | `pkg_<flow>_flow` | the order of a multi-entity operation and the invariant that spans it | issue `INSERT`/`UPDATE`/`DELETE` of its own; wrap a single entity |
| **Integration** | `pkg_<system>_api` | one external system's protocol: payload, auth, endpoint, parsing, timeout | hold a business rule; write an entity table; decide the business transaction |

Entity packages keep their existing names — nothing is renamed. The suffix marks what is *not* an
entity, which is what has to be recognizable at a glance.

**Integration, minimally:** it returns a result; the flow (or entity) decides what to persist. An
external failure `RAISE`s and lets the caller's transaction unwind — it never commits, never
half-applies, and never decides on its own that the business operation succeeded. Retry policy,
idempotency keys and queue-and-forward are **out of scope for this file** and belong in a per-system
document.

## Test 1 — is this table a satellite?

A table is a **satellite** of an entity when **all four** hold:

1. It has a `NOT NULL` FK to that entity.
2. No other entity writes it.
3. It is meaningless without that entity.
4. It has no rules of its own — nothing constrains who may write it, or when, beyond the parent's
   own rules.

The entity package owns its satellites. Fail any one of the four and it is an entity in its own
right, with its own package.

Clause 4 decides the borderline cases, and it asks about **responsibility**, not about shape:

| Child table | Verdict |
|---|---|
| `order_lines` | **satellite** — the order's rules govern them; a line has none of its own |
| `order_events` | **satellite** — written only by the parent's own operations |
| `item_comments` | **entity** — *"only the author may edit it, and only within N minutes"* is a rule about the comment, not about the item. It earns `pkg_item_comments` (`item-detail-page.md`) |

```text
orders + order_lines + order_events   → satellites   → pkg_orders writes all three
absences + employee_quota             → NOT satellite → the quota's FK points at the employee,
                                                        and payroll writes it too
```

That last line is why `approve` on an absence is a **domain** operation and not an entity one.

## Test 2 — does this need a flow package?

Only when the operation writes **more than one non-satellite entity**, *and* at least one holds:

- **(a)** there is an observable intermediate state that is invalid if the sequence stops halfway;
- **(b)** the coordinated operation must be callable from outside the page — a job, REST, another page.

Neither (a) nor (b)? Then the `.apx` calls the entity packages in sequence, and that is correct — see
`master-detail-edit.md` §Conventions. Two tables is not, by itself, a reason for a third package.

**Reading another entity to decide is always allowed**, in any layer. `examples/employees-form/02-pkg_employees.sql`
already queries `hr_sectors` to enforce "the sector must be active", and that is right. What a
package must not do is *write* an entity it does not own; what `back-end-conventions.md` §5 forbids
is routing **reporting**
through a package.

## The decision procedure

**First, decide which question you are asking.** A *rule* and an *operation* are different subjects,
and running the wrong procedure is how logic ends up in the wrong place:

| You are asking | Run |
|---|---|
| "Where does this **rule** live?" — a uniqueness check, a guard, a required field | **A** |
| "Which package owns this **operation**?" — a save, a transition, a wizard's final step | **B** |

Both are ordered, and within each one you **stop at the first branch that matches**.

### A — where a rule lives

**A1 — Is it an invariant of the data's shape?**
`NOT NULL`, `CHECK`, `UNIQUE`, `FK` → a **database constraint**, always. And *also* a check inside
the owning package when the user needs a sentence instead of `ORA-00001`: the constraint is where the
invariant lives, the package check is where the friendly `-20xxx` message is born
(`back-end-conventions.md` §2, §3). Never one
without the other.

**A2 — Is it purely UX?**
Field shape, a required marker, a format hint → the **`.apx`**, and it stays there **only if no other
path can perform the operation**. If a job, an ORDS handler or SQLcl can reach the same table, the
rule is not UX — go to A3. That guard is the whole of A2.

**A3 — Otherwise it lives in PL/SQL**, inside the package that owns the operation the rule
constrains — run **B** to find out which. A rule that spans entities ("no approval without balance")
lives in the flow package, because that is the only layer where both entities are visible.

### B — which package owns an operation

**B0 — Does it write?**
No → inline SQL for a page-local query, a `v_*` view when the read is complex or reused. **No
package** (`back-end-conventions.md` §5). Do not wrap a `SELECT` in a package to satisfy a rule. The
single exception is an `f_*` **function** resolving an LOV or lookup value, which lives on the entity
package that owns that value — never as a report's data source.

**B1 — Does it write exactly one entity, plus that entity's satellites?**
→ **entity package** (`pkg_<entity>`). This is most operations: CRUD, an entity's own rules, a
transition that touches only that entity and its event rows.

**B2 — Does it write more than one entity?**
Apply Test 2.
- Test 2 does not fire → the **`.apx` calls the entity packages in sequence**. No new package.
- Test 2 fires → **flow package** (`pkg_<flow>_flow`): it coordinates, guards the spanning
  invariant, and issues no DML of its own.

**B3 — Does it also talk to an external system?**
This one is **not** an alternative to B1/B2 — an operation can write entities *and* call outward. The
protocol half goes in an **integration package** (`pkg_<system>_api`), called by whichever layer B1 or
B2 assigned the operation to.

### Worked: the same feature through both procedures

*"Approving an absence must deduct the employee's quota, and cannot exceed the balance."*

- **Operation** (`approve`): B0 writes → B1? it writes `hr_absences` **and** the quota, and the quota
  fails Test 1 → B2 → Test 2 fires (an approved absence with no quota deducted is an invalid
  intermediate state) → **`pkg_absence_flow.approve`**.
- **Rule** ("cannot exceed the balance"): A1? not a shape invariant — it compares rows across two
  entities, no constraint can express it → A2? not UX, a job could approve → A3 → PL/SQL, in the
  package that owns the operation → **the flow**.

Both procedures land on the flow, from different directions. That agreement is the check that the
boundary is right; when they disagree, the operation is split wrong.

### When NOT a package

Collected, because it is the half that gets skipped:

- **A read** — inline SQL or a `v_*` view (B0).
- **A shape invariant** — a constraint; the package check exists for the message, not the truth (A1).
- **A UX-only hint** — the `.apx`, provided no other path can write (A2).
- **A multi-entity sequence with no spanning invariant** — the `.apx` calls each entity package (B2).
- **Any layer with nothing to abstract** — a flow package around a single entity, an integration
  package with no external system, a view over one table. A layer must earn its existence with a
  responsibility, not with a rule.

## God package — the threshold

"Too many responsibilities" is not checkable. These are:

1. **It writes more than one non-satellite entity.** It is already a flow package wearing an
   entity's name. This is the load-bearing test — the other three are corroboration.
2. **Its name does not predict its operations.** If you have to read the spec to know what the
   package does, the name stopped describing it.
3. **It carries verbs from more than one business domain** — `reserve_inventory` next to
   `process_payment` next to `notify_customer`.
4. **More than ~7 public operations.** Not a rule; a prompt to check the three above.

Splitting the `pkg_orders` at the top of this file:

```text
pkg_orders          create_row · update_row · delete_row · set_status · add_line
                    (orders + order_lines + order_events)
pkg_inventory       reserve · release
pkg_payments        create_row · void
pkg_sales_flow      confirm_order · cancel_order       (coordinates; writes nothing)
pkg_invoicing_flow  generate_invoice
pkg_mailer_api      send                               (protocol only)
```

`calculate_total` is a read — a `v_*` view or an `f_*` function, not a procedure (B0).

## Not exceptions

The escape hatches this file does **not** open. Each is answered in `SKILL.md` §Common mistakes:

- *"It's a prototype / I'll add the package later."* Retrofitting a write path after pages already
  issue direct DML means rewriting every page that touched the table. The seam is ~30 lines.
- *"Simple catalog, no business rules yet."* Catalogs get FK-referenced fast; "no rules yet" is the
  rationalization, not the condition.
- *"A package is ceremony."* The ceremony is the rule duplicated across four page processes.

If a table gets written, it has an owner. There is no size below which that stops being true.

## Atomicity and locking in a flow package

A flow package coordinates, so it is where partial application becomes visible. Two conventions:

**It still does not commit.** `back-end-conventions.md` §4 is unchanged: APEX commits on page submit,
jobs commit explicitly.
The flow package is a boundary of **atomicity**, not of transaction. It guarantees atomicity by not
committing between steps — so an exception from any step unwinds all of them:

```plsql
PROCEDURE confirm_order (p_order_id IN NUMBER) IS
BEGIN
    -- Locks are taken in the order declared in the header, below.
    pkg_orders.set_status(p_order_id, 'CONFIRMED');
    pkg_inventory.reserve(p_order_id);     -- raises e_no_stock when short
    pkg_payments.create_row(p_order_id);
    -- No COMMIT: the caller owns the transaction (back-end-conventions.md §4).
END confirm_order;
```

Note what is **not** there. No `SAVEPOINT`, and no handler that rolls back and re-raises: since
nothing committed in between, letting the exception propagate already undoes every step, and
`ROLLBACK TO` followed by `RAISE` would be a no-op. A `SAVEPOINT` earns its place only when the flow
must undo one step and **carry on** — skip an optional step, fall back to a second provider — and it
carries a cost worth knowing: `ROLLBACK TO SAVEPOINT` releases the row locks acquired after that
savepoint, so anything the flow still depends on has to be locked again.

**It declares its lock order.** Two flows that lock the same entities in opposite orders deadlock.
Every flow package states the order it acquires `FOR UPDATE` in its header, and every entity package
it calls respects it:

```plsql
CREATE OR REPLACE PACKAGE pkg_sales_flow AS
  /*
   * Coordinates orders + inventory + payments. Issues no DML of its own.
   * No internal COMMIT (back-end-conventions.md section 4).
   * Lock order: hr_orders -> hr_inventory -> hr_payments. Do not deviate.
   */
  PROCEDURE confirm_order (p_order_id IN NUMBER);
END pkg_sales_flow;
```

Alphabetical by table name is a fine default — what matters is that it is written down and identical
across flows.

## Pending

`examples/absences-workflow` does not yet ship the `pkg_quotas` + `pkg_absence_flow` pair. The slice
implements the from-state guard on `pkg_absences` and marks, in that package's body, where a quota
deduction does **not** belong. Read it for its `.apx` grammar and its transition guard; the flow half
arrives in a follow-up, and `recipes/workflow-state-transitions.md` already shows its shape.
