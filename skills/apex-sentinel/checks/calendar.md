# Check: calendar (bookings, schedules)

**Verifies** `apexlang-architecture/recipes/calendar-scheduling.md`: a moved or resized event is written by the package and keeps its hours, a refused move says why, a slot opens the form already filled, and none of it needs a mouse.

**REQUIRED BACKGROUND:** `setup.md` and `SKILL.md` §Snapshot diet. The calendar is FullCalendar inside `#<htmlDomId>`: events are `.fc-event` (week and day views: `.fc-timegrid-event`), days are `td[data-date="YYYY-MM-DD"]`, the view buttons are in `.fc-toolbar`.

## Before anything: put the calendar where the data is

The calendar reopens on the user's last view, and the week view opens on the first week of the month last shown. A script that looks for an event straight away finds none and reports a bug that is not there.

1. Press **today** if it is enabled, then the view you need — a view button is disabled while its view is the current one, so click it only when enabled.
2. Read the events with `eval`: `[...document.querySelectorAll('#bookings .fc-event')].map(e => e.innerText)`. Assert the count against the table through SQLcl, and that each event's text names its state (not the colour alone).

## Steps

1. **Drag onto a free slot.** In the month view, drag an event to another day (`run-code`: `mouse.down` on the event, a small first move, then steps to the target cell). Confirm in the table: the day changed, **the hours did not**, the version moved. An event stored as midnight to midnight means the calendar is not showing the time (`showTime`).
2. **Drag in the week view** by a whole number of slots (read the slot height from `.fc-timegrid-slot`). Confirm the new hour and the same duration.
3. **Resize** from the event's lower edge (`.fc-event-resizer-end`, visible on hover). Confirm the new end.
4. **Create from a slot.** Click an empty day. The form opens with the start and end already filled, in the application's date format. Save; the dialog closes, the event appears without a reload, the row exists.
5. **Open from the keyboard.** `focus()` an event, press Enter: the same form opens with that event's data. Esc closes it.
6. **Filter**, when the page has facets: choose one value; the event count matches the table for that value, in the grid and in the list view.

## Refusal path (non-mutating)

1. Drag an event onto a slot the package must refuse (a taken room, a closed state). Assert **all three**: the event is back where it was, the package's sentence is on the page (`#t_Alert_Notification`, no `ORA-` prefix), and the row is unchanged in the table. An event that jumps back in silence fails this check — the page is not handling `apexcalendardragdroperror`.
2. Create over a taken slot: the form stays open with the package's sentence, and no row is added.

## Pass criteria

Each criterion has an ID: a runtime-result (`framework/schemas/runtime-result.schema.json`) reports it by that ID, with what was observed and the evidence it rests on.

- `CAL-MOVE-PERSISTS` — A dragged event is stored on its new day or hour with its duration intact; the table agrees.
- `CAL-RESIZE-PERSISTS` — A resized event is stored with its new end.
- `CAL-REFUSAL-SHOWN` — A move the package refuses returns the event, shows the package's message and changes no row.
- `CAL-CREATE-FROM-SLOT` — A slot opens the form filled with that slot; saving adds the row and the event appears.
- `CAL-KEYBOARD-OPEN` — An event can be focused and opened without a mouse.
- `CAL-FILTER-AGREES` — With a facet applied, the events shown are the rows the table has for it. `NOT_RUN` on a page with no facets.
- (Not a runtime criterion: that the drag's PL/SQL calls the package and nothing else is the Architecture Gate's reading of the page source.)
