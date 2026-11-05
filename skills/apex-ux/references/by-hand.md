# Runtime ADVISE checks, by hand

`ux-check.py` does not measure `UX-REFLOW`, `UX-FOCUS-VISIBLE` (the 3:1 contrast), `UX-NAME-LANGUAGE`
or `UXDASH-CHART-SERIES`. Apply them on the page the session holds, after `pw.sh login` and
`pw.sh goto <page>`. A finding is an advisory under the criterion's ID, never a verdict; a check
you did not run is `NOT_RUN`. Whether a message appears or an action works is `apex-sentinel`'s
verdict: use its flow to cause the state (a request, a validation error), and report only how it is
presented, here. `UX-TARGET-SIZE` needs no snippet: axe's `target-size` already runs in `ux-check.py`
(and FAILs `UX-AXE-SERIOUS`); read its findings at each width below.

**Transport.** The snippets are DOM functions for `pw.sh [--app X] eval '<function>'` — one quoted
argument, read-only: they never focus, click or change a value, because the session is shared with
`apex-sentinel`. The viewport is `pw.sh resize <w> <h>`. An APEX modal page or drawer is an iframe,
and `eval` sees only the top document: run the same function in that frame with `run-code`, which
takes Playwright code (`async (page) => ...`), never a bare DOM function:

```js
async (page) => page.frames().filter((f) => f !== page.mainFrame())[0].evaluate(/* the function, pasted here */)
```

## UX-REFLOW (320 and 375 px)

Note the size (`pw.sh eval '() => [innerWidth, innerHeight]'`), then `pw.sh resize 320 640`, run the
snippet, repeat at 375, and resize back. 320 is WCAG's number; 375 is the usual phone, a practical
check only. `clipped` lists containers whose content is cut off with no way to scroll; `scrollers`
lists the ones that scroll, and `keyboard: false` is a scroll region a keyboard cannot reach. Then
operate each action of the page's main flow at that width and say which you could not reach or
operate. The lists are candidates: a Universal Theme off-canvas part can show up and be fine.

```js
() => {
  const de = document.documentElement, out = { pageOverflowsX: de.scrollWidth > de.clientWidth + 1, clipped: [], scrollers: [] };
  const name = (e) => e.tagName.toLowerCase() + (e.id ? '#' + e.id : '') + (typeof e.className === 'string' && e.className.trim() ? '.' + e.className.trim().split(/\s+/)[0] : '');
  for (const el of document.body.querySelectorAll('*')) {
    const cs = getComputedStyle(el), r = el.getBoundingClientRect();
    if (cs.display === 'none' || cs.visibility === 'hidden' || r.width <= 1 || r.height <= 1) continue;   // hidden, sr-only
    if (el.scrollWidth <= el.clientWidth + 1 || cs.textOverflow === 'ellipsis') continue;
    if (cs.overflowX === 'hidden' || cs.overflowX === 'clip') out.clipped.push(name(el));
    else if (cs.overflowX === 'auto' || cs.overflowX === 'scroll')
      out.scrollers.push({ el: name(el), keyboard: el.tabIndex >= 0 || !!el.querySelector('a[href],button,input,select,textarea,[tabindex]') });
  }
  return out;
}
```

## UX-FOCUS-VISIBLE (3:1)

For each kind of stop (content controls, side menu and its tree, grid cells, dialog controls),
press Tab with `pw.sh press Tab` and read the focused element, without moving focus yourself:

```
pw.sh eval '() => { const e = document.activeElement, s = getComputedStyle(e); return [e.tagName, e.id, s.outlineStyle, s.outlineWidth, s.outlineColor, s.boxShadow, getComputedStyle(e.parentElement).backgroundColor]; }'
```

Compute the contrast of the outline colour against the background next to it with WCAG's
relative-luminance formula; below 3:1 is the finding (WCAG 1.4.11), and an outline over a
transparent parent needs the first opaque ancestor's background. A box-shadow or a background change is an
indicator this does not measure: take an element screenshot focused and unfocused, and compare the
changed pixels with their neighbours. Name the stop, the colours and how you measured. A
kind of stop you did not reach is `NOT_RUN`, not a pass.

## UX-NAME-LANGUAGE

Run the first snippet on the page as loaded and in each dialog. For the transient texts (a
request's "processing", a validation error, an empty result) install the second **before** the
action, then read `pw.sh eval '() => window.__live'` after it (a full page submit discards it; a
dynamic action or partial refresh keeps it). Read both against `lang`: an English word in a
Spanish page is the finding, and a word valid in both (`Bar`, `Total`) is judged by its sentence.
Say which component renders each string; whether it is Oracle's is decided by `oracle-owned.json`,
never by the string coming from a standard component.

```js
() => {                    // texts assistive technology reads, for a person to read against lang
  const out = [], add = (o, t) => { t = (t || '').replace(/\s+/g, ' ').trim(); if (t) out.push(o + ': ' + t); };
  const lab = (e) => e.getAttribute('aria-label') || (e.getAttribute('aria-labelledby') || '').split(/\s+/).map((id) => (document.getElementById(id) || {}).textContent || '').join(' ');
  document.querySelectorAll('[aria-label],[title],[alt],[aria-roledescription],[aria-valuetext]').forEach((e) =>
    ['aria-label', 'title', 'alt', 'aria-roledescription', 'aria-valuetext'].forEach((a) => e.hasAttribute(a) && add(e.tagName.toLowerCase() + '[' + a + ']', e.getAttribute(a))));
  document.querySelectorAll('svg title, [role=alert], [role=status], [aria-live]:not([aria-live=off])').forEach((e) => add('live/svg', e.textContent));
  document.querySelectorAll('nav, [role=navigation], [role=region], [role=dialog], main, header, footer, aside').forEach((e) => add('landmark', lab(e)));
  return { lang: document.documentElement.lang, texts: [...new Set(out)] };
}
```

```js
() => {                    // install BEFORE the action; afterwards read window.__live
  window.__live = [];
  const grab = () => document.querySelectorAll('[role=alert],[role=status],[aria-live]:not([aria-live=off])').forEach((e) => {
    const t = e.textContent.replace(/\s+/g, ' ').trim();
    if (t && !window.__live.includes(t)) window.__live.push(t);
  });
  new MutationObserver(grab).observe(document.body, { subtree: true, childList: true, characterData: true, attributes: true });
  return 'observing';
}
```

## UXDASH-CHART-SERIES

Open each chart with two or more series. Look for a pattern, a marker or line style, or a direct or
data label in the chart itself, and that a legend entry is more than a colour swatch. Report what
you saw, and the two series colours with their contrast ratio. A data table next to the chart answers
`UXDASH-CHART-TEXT`, not this.
