# Recipe: calendar (bookings, shifts, schedules)

**Use for:** rows whose meaning is *when* — room bookings, appointments, shifts, deliveries, due
dates. If the request says "a list of bookings" and the table has a start and an end, this is the page.

**REQUIRED BACKGROUND:** `back-end-conventions.md` (the write path); `ui-contracts.md` §2 (the closed
set), §3 (links). Grammar: Oracle's `region-components/calendar/` family (26.1) — fifteen scenarios,
from a monthly view to a schedule builder. This recipe covers what that family leaves open: who
writes when an event is dragged, where "no overlap" lives, and what the SQL may project.

**Measured** on APEX 26.2.0 (2026-11-16, a 26.1 source compiled and imported with SQLcl 26.2.0, driven
in a browser, each write confirmed in the table): the SQL and class mapping, the three writes below,
the refusal message, the create link, facets over the calendar, a drag and a resize in the week
view, opening an event from the keyboard, and `ux-check.py` on all four views. **Not measured:** a
refused move in the week view (the month view's was), touch. The inventory lists no calendar-specific property and Oracle's
26.1 template is incomplete on three points this recipe names — where they disagree, the compiler
decided.

**Contents:** the three writes · the SQL · show the time · drag and drop goes through the package ·
a refused move says so · overlap is the package's rule · create and edit · filters · conventions ·
common mistakes.

## A calendar writes in three places

| Gesture | What it is | Goes to |
|---|---|---|
| Drag or resize an event | an UPDATE of the start (and end) | `dragAndDropPlsqlCode` → `pkg_bookings.reschedule` |
| Select an empty slot | the start of an INSERT | `createLink` → a form in a dialog (`modal-crud-to-package.md`) |
| Click an event | read or edit one row | `viewEditLink` → the same form, or a detail drawer |

The first is the one that gets missed: it has no page process, no button and no submit, so it looks
like configuration. It is a write.

## The SQL projects data and one class

```sql
select b.booking_id, b.title, b.starts_at, b.ends_at,
       case b.status when 'CONFIRMED' then 'apex-cal-black'
                     when 'PENDING'   then 'apex-cal-yellow'
                     else 'apex-cal-silver' end as css_class
  from v_bookings b
 where b.room_id = :P20_ROOM_ID
```

```
settings {
    displayColumn: TITLE  startDateColumn: STARTS_AT  endDateColumn: ENDS_AT
    pkColumn: BOOKING_ID  cssClass: CSS_CLASS
    showTime: true  timeFormat: 24Hour
    calendarViewsAndNavigation: [ month week day list navigation ]
}
```

- `pkColumn` is required on every calendar and is the table's primary key (Oracle: *"Every calendar
  region must emit `settings.pkColumn`"*).
- `cssClass` follows `ui-contracts.md` §2: whole literals, a `CASE` with an `ELSE`. Never a
  concatenation, never a class column a user can type into.
- **Four of the calendar's nine classes are usable.** Measured text contrast on APEX 26.2.0 (list view):
  `apex-cal-black` 13.2, `-yellow` 6.2, `-silver` 5.8, `-red` 5.1 meet 4.5:1; `-gray` 4.0,
  `-blue` 3.9, `-lime` 3.3, `-orange` 2.2 and `-green` 2.1 do not, and each event wearing one is a
  `color-contrast` finding (`UX-AXE-SERIOUS`). The closed set is those four. Oracle's templates and
  Sample Calendar use the other five.
- Colour is not the only signal: put the state in the title or in `supplementalInfo` as well
  (`apex-ux` `UX-NO-COLOR-ONLY`).
- **No markup in the query.** Oracle's calendar contract lets `escapeSpecialChars: false` through
  when the SQL returns sanitised HTML (*"disable escaping (`escapeSpecialChars: false`) only"* when
  intentional); this repo does not. The title is text, an icon is a class.
- `list` gives the calendar a list view, which is what a phone and a screen reader can use
  (`apex-ux` `UXCAL-LIST-VIEW`).

## Show the time, or a drag destroys it

The views come from one of two properties, and which one is legal depends on `showTime`:

| `showTime` | Views property | Views offered |
|---|---|---|
| absent (false) | `additionalCalendarViews: [ list navigation ]` | month, list |
| `true` | `calendarViewsAndNavigation: [ month week day list navigation ]` | those listed; `timeFormat` becomes legal |

Oracle's 26.1 contract says not to emit `showTime`. The compiler accepts it, and with it rejects
`additionalCalendarViews` (*Invalid property*) — and it is not optional for a timed entity: without
it the calendar treats every event as a whole day, so a drag sends midnight to midnight. Measured: a
booking of 11:00–12:00 dragged to the next day was stored as 00:00 to 00:00 of the day after. With
`showTime: true` the same drag kept 11:00–12:00.

A calendar of whole days (holidays, due dates) leaves `showTime` off and its package ignores the
time part.

## Drag and drop goes through the package

Oracle's template writes the table from the region:

```
❌ dragAndDropPlsqlCode: update bookings set starts_at = to_date(:APEX$NEW_START_DATE, …) where id = :APEX$PK_VALUE;
```

and its contract says to *"Use `invokeApi` unless a packaged API is unavailable."* Here the packaged
API is never unavailable — that is the single write path:

```
settings {
    dragAndDrop: true
    dragAndDropPlsqlCode: ```plsql
        -- thin wrapper: the calendar passes its binds as strings; the package validates and writes
        pkg_bookings.reschedule(
            p_booking_id => :APEX$PK_VALUE,
            p_starts_at  => to_date(:APEX$NEW_START_DATE, 'YYYYMMDDHH24MISS'),
            p_ends_at    => to_date(:APEX$NEW_END_DATE,   'YYYYMMDDHH24MISS'));``` }
```

`reschedule` is its own operation, not `update_row`: a drag carries no version token and changes
two columns, and the rules it must pass (below) are the same ones a form edit passes. It raises the
package's `-20xxx` when it refuses.

## A refused move says so — APEX does not

When the PL/SQL raises, the calendar puts the event back and shows **nothing**: no notification, no
console error. Measured: the response carried the package's message and the page stayed silent, so
the user sees the booking jump back with no reason. The calendar fires a custom event instead, and
the page must turn it into a message:

```
dynamicAction show-move-refusal (
    when { event: custom  customEvent: apexcalendardragdroperror  selectionType: region  region: @bookings }
    action show-refusal (
        action: executeJsCode
        settings { jsCode: ```javascript-browser
            var d = this.data,
                m = (d && (d.errorMessage || d.error || d.message)) || (typeof d === "string" ? d : "The booking could not be moved.");
            apex.message.clearErrors();
            apex.message.showErrors([{ type: "error", location: "page", message: m, unsafe: false }]);``` }
    )
)
```

With it, the two refusals measured (an overlap, a cancelled booking) showed the package's sentence,
the event returned, and the table was unchanged. The text is the package's, made presentable by the
application's error-handling function (`back-end-conventions.md` §3); `unsafe: false` escapes it.
Oracle's template lists this handler as optional. It is not: `apex-ux` `UXCAL-REFUSAL-MESSAGE`.

**Unit of work.** One drag is one request and one transaction: `reschedule` either moves the booking
or raises, and nothing else is written (`back-end-conventions.md` §4). A drag has no lost-update
guard — the row may have changed since the calendar loaded — so `reschedule` re-reads the row,
checks the state still allows a move, and locks it before writing (§7).

Resizing an event runs the same code with a new end (measured: 15:00–16:00 became 15:00–17:00
through `reschedule`), and a drag in the week view changes the hour and keeps the duration — so
`reschedule` is the one place both arrive.

Dragging is never the only way: an event is a keyboard stop and Enter opens its form (measured), where
the dates are fields (`apex-ux` `UXCAL-DRAG-ALTERNATIVE`).

Leave `dragAndDrop` off when moving an event has consequences a drag cannot ask about (a confirmed
booking that notifies people, a shift with a swap rule). An edit form can ask; a drag cannot.

## "No overlap" is the package's rule

Two bookings of one room cannot intersect. That rule lives in `pkg_bookings`, once, called by
`create_row`, `update_row` and `reschedule`:

- the intervals are half-open — `new.starts_at < old.ends_at and new.ends_at > old.starts_at` — so
  10:00–11:00 and 11:00–12:00 do not collide;
- cancelled rows are out of the check;
- the check and the write are serialised per resource (lock the room's row first), or two sessions
  both pass the check and both insert. A calendar invites exactly that race: two people looking at
  the same free slot.

It is not a page validation: a validation runs on submit, and a drag never submits.

## Create and edit

`createLink` opens the form with the slot the user picked — `items: { P21_NEW_START:
&APEX$NEW_START_DATE.  P21_NEW_END: &APEX$NEW_END_DATE. }` (substitutions, not the
`:APEX$NEW_START_DATE` bind of the drag). The form is an ordinary dialog on the same table, wired as
`modal-crud-to-package.md`; on close, a dynamic action (`apexafterclosedialog` on the calendar)
refreshes it. `viewEditLink` passes the key the same way. Both are declarative targets
(`ui-contracts.md` §3), never an `f?p=` string.

**The two date formats differ.** The drag's binds arrive as `YYYYMMDDHH24MISS`. The create link's
substitutions arrive in the **application's Date Time format** — measured: `11/21/2026 12.00.00 AM`
with none set, `21/11/2026 00:00` with `appFormatMasks { dateTime: DD/MM/YYYY HH24:MI }`. Parsing
them with the drag's mask raises `ORA-01858` when the dialog opens. So set the application's
`dateTime` mask explicitly and read the slot with that same mask. A click on a day in the month view
passes the whole day (00:00 to 23:59); the form asks for the hours.

The link the calendar builds carries a checksum, so the receiving items keep
`sessionStateProtection: checksumRequiredSessionLevel` and the page keeps
`argumentsMustHaveChecksum` (measured: the dialog opens with both in place).

## Filters

A `facetedSearch` filters a calendar as it filters a report — `filteredRegion` names the calendar —
so "by room", "by status", "by owner" need no hand-written predicates (`master-faceted-search.md`).
Measured: a facet on the room took the month from nine events to two, and the list view followed.

## Conventions

- One calendar, one resource dimension. Several rooms at once is a filter or one calendar per room,
  not a colour per room with no legend.
- Dates travel as `DATE`/`TIMESTAMP` columns; the time zone is the session's. An application that
  spans zones stores `TIMESTAMP WITH LOCAL TIME ZONE` and says so on the page.
- `maxEventsDay` keeps a busy month legible; the overflow opens the day.
- The calendar reopens on the view the user last chose (measured: week, after a new sign-in). A test
  that assumes the month view selects it first.
- The week view opens on the first week of the month the user was looking at, not on today
  (measured): a test presses **today** before it looks for an event.
- **Three axe findings, two of them the page's to fix.** On APEX 26.2.0 a calendar as generated
  gives `role-img-alt` (the previous/next icons), `scrollable-region-focusable` (the time grid's
  scroller) and `aria-required-parent` (the grid's own table). The first two go away with two
  options, measured on all four views:

  ```
  componentAdvanced { initJavaScriptFunction: ```javascript-browser
      function (pOptions) {
          pOptions.contentHeight = "auto";      // no inner scroller
          pOptions.buttonIcons = false;         // text buttons instead of unnamed icons
          pOptions.buttonText = Object.assign({}, pOptions.buttonText, { prev: "Previous", next: "Next" });
          return pOptions;
      }``` }
  ```

  The third is APEX's markup and no `.apx` changes it: `apex-ux` lists it as `OO-3` for APEX 26.2,
  an advisory. With the four classes above and these options the page passes `ux-check.py`; the
  list view passes with no exception at all.
- A read-only calendar sets no `dragAndDrop`, no `createLink`, and `readOnly`.

## Common mistakes

| Tempting | Why wrong |
|---|---|
| `update … where id = :APEX$PK_VALUE` in `dragAndDropPlsqlCode` | A write outside the package: the overlap rule, the state guard and the audit are skipped on the gesture users will use most. |
| The overlap check as a page validation on the form | A drag never runs it. A job and a REST call never run it. |
| `apex-cal-green` for "confirmed" | White on that green is 2.1:1. The state is in the text; the class comes from the four that pass. |
| `'apex-cal-' \|\| lower(colour)` | A composed class (`UX-NO-COMPOSED-CLASS`): no literal in the source says which classes can reach the page. |
| An icon or a link built as HTML in the title | The query projects data; and it turns `escapeSpecialChars` off for the whole region. |
| Timed events with no `showTime` | A drag stores midnight to midnight: the hours are gone, silently. |
| No handler for `apexcalendardragdroperror` | The package refuses, the event jumps back, the user is told nothing. |
| Parsing `&APEX$NEW_START_DATE.` as `YYYYMMDDHH24MISS` | That is the drag's format. The link's is the application's Date Time format. |
| A report page with a date column, because "calendars are hard to test" | The user scans thirty rows to find a free Tuesday. The component exists for this. |

## Verify

`apex-sentinel`: create from a slot, drag an event onto a free slot and onto a taken one (the row
moves and keeps its hours, or the package's message shows and the event returns), and confirm each
in the table: `apex-sentinel` `checks/calendar.md`. `apex-ux`: `criteria/calendar.md`.
