# Calendars — `UXCAL`

Recipe: `calendar-scheduling.md`. Runtime companion: `apex-sentinel/checks/calendar.md`. Drawn from WCAG 2.2 and Oracle's calendar contract; the example catalog has no calendar page, so no row cites it.

| ID | Criterion | Sev | By | Source |
|---|---|---|---|---|
| `UXCAL-LIST-VIEW` | the calendar offers its list view (`list` in `calendarViewsAndNavigation`, or in `additionalCalendarViews` when no time is shown): the events are reachable as a list by keyboard and at a phone width, not only as a grid of positioned blocks | ADVISE | static + runtime | WCAG 1.3.1, 1.4.10; Oracle calendar |
| `UXCAL-DRAG-ALTERNATIVE` | whatever dragging or resizing an event does can also be done without dragging — the event opens a form where the dates are edited | ADVISE | static + runtime | WCAG 2.5.7 |
| `UXCAL-EVENT-TEXT` | an event reads on its own: its title names what it is, and its state is in the title or the supplemental text, never in the colour alone (`UX-NO-COLOR-ONLY`) | ADVISE | static + manual | WCAG 1.4.1; repo `recipes/calendar-scheduling.md` |
| `UXCAL-CLASS-CONTRAST` | an event's class is one whose text meets 4.5:1 — of the calendar's nine, `apex-cal-black`, `-red`, `-silver` and `-yellow` (APEX 26.2.0); an event in another class is a `color-contrast` finding under `UX-AXE-SERIOUS` | ADVISE | static | WCAG 1.4.3; repo `recipes/calendar-scheduling.md` |
| `UXCAL-REFUSAL-MESSAGE` | a move the package refuses (an overlap, a closed state) says why in plain words, and the event returns to where it was — APEX shows nothing by itself: the page handles the calendar's `apexcalendardragdroperror` event | ADVISE | runtime | WCAG 3.3.1; repo `recipes/calendar-scheduling.md` |
| `UXCAL-TIME-KEPT` | a calendar of timed events shows the time (`showTime`), so moving an event keeps its hours instead of turning it into a whole day | ADVISE | static + runtime | repo `recipes/calendar-scheduling.md` |
| `UXCAL-TIME-CONTEXT` | the page says what the times mean when it is not obvious — the time zone, and whether an end is included — and uses the application's one time format | ADVISE | manual | WCAG 3.3.2 |
