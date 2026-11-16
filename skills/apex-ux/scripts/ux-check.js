// ux-check — the browser half of apex-ux's runtime criteria. Not run directly: ux-check.py
// wraps it as `async (page) => (<this>)(page, AXE, OPTS)` and hands it to
// `pw.sh run-code --raw --filename`, so it runs inside the session the agent already logged in.
//   AXE   the vendored axe-core source, verified against its sha256 lock by the caller
//   OPTS  { tags: [...], dialogs: [selector, ...], reflow: [width, ...] }
// Returns one JSON string: { verdict: 'OK' | 'NOT-LOGGED-IN', url, runs: [...], dialogs: [...],
//   names: [...], reflow: [...], errors: [...] }.
// Every run keeps axe's raw result; the caller strips node HTML before printing anything.
async (page, AXE, OPTS) => {
  const errors = [];

  // A login page is not the page under test: never report its accessibility as the app's.
  const onLogin = /\/login(\?|#|$)/i.test(page.url()) ||
    (await page.locator('input[type="password"]:visible').count()) > 0;
  if (onLogin) return JSON.stringify({ verdict: 'NOT-LOGGED-IN', url: page.url() });

  // axe in every frame: APEX modal pages and drawers render inside an iframe.
  const runAxe = async (where) => {
    const out = [];
    for (const frame of page.frames()) {
      if (frame.url() === 'about:blank') continue;
      try {
        if (!(await frame.evaluate(() => !!window.axe))) await frame.addScriptTag({ content: AXE });
        const r = await frame.evaluate((tags) => window.axe.run(document, {
          runOnly: { type: 'tag', values: tags },
          resultTypes: ['violations', 'incomplete'],
        }), OPTS.tags);
        out.push({ where, frame: frame.url(), violations: r.violations, incomplete: r.incomplete });
      } catch (e) {
        errors.push({ where, frame: frame.url(), error: String(e && e.message || e).slice(0, 300) });
      }
    }
    return out;
  };

  // The dialog under test is the one the opener made visible, marked when it appears:
  // APEX adds other role=dialog nodes while the user tabs (popups, help), and "the last
  // visible dialog" would then be the wrong one. An iframe inside it counts as inside:
  // the top document reports the iframe as active while focus is in its page.
  const MARK = 'data-ux-check-dialog';
  const visibleDialogs = () => page.evaluate(() => [...document.querySelectorAll('[role="dialog"], .ui-dialog')]
    .filter((d) => d.getClientRects().length > 0).length);
  const markPresent = () => page.evaluate((m) => document.querySelectorAll('[role="dialog"], .ui-dialog')
    .forEach((d) => { if (d.getClientRects().length > 0) d.setAttribute(m, 'pre'); }), MARK);
  const markOpened = () => page.evaluate((m) => {
    const d = [...document.querySelectorAll('[role="dialog"], .ui-dialog')]
      .filter((x) => x.getClientRects().length > 0 && !x.hasAttribute(m)).shift();
    if (d) d.setAttribute(m, 'open');
    return !!d;
  }, MARK);
  const focusInDialog = () => page.evaluate((m) => {
    const d = document.querySelector('[' + m + '="open"]'), a = document.activeElement;
    return !!(d && a && a !== document.body && d.contains(a));
  }, MARK);
  const unmark = () => page.evaluate((m) => document.querySelectorAll('[' + m + ']')
    .forEach((d) => d.removeAttribute(m)), MARK);

  // UX-NAME-LANGUAGE: what assistive technology reads, per frame — names and live text, with the
  // page's lang. The caller reports only the ones on its list of APEX's untranslated defaults.
  const names = [];
  const readNames = async (where) => {
    for (const frame of page.frames()) {
      if (frame.url() === 'about:blank') continue;
      try {
        names.push({ where, frame: frame.url(), ...(await frame.evaluate(() => {
          const out = [], seen = new Set();
          const css = (e) => e.tagName.toLowerCase() + (e.id ? '#' + e.id : '') +
            (typeof e.className === 'string' && e.className.trim() ? '.' + e.className.trim().split(/\s+/)[0] : '');
          const push = (kind, text, el) => {
            text = (text || '').replace(/\s+/g, ' ').trim();
            if (!text || text.length > 120 || seen.has(kind + '|' + text)) return;
            seen.add(kind + '|' + text);
            out.push({ kind, text, target: css(el) });
          };
          for (const el of document.querySelectorAll('[aria-label],[title],[alt]'))
            for (const a of ['aria-label', 'title', 'alt']) if (el.hasAttribute(a)) push(a, el.getAttribute(a), el);
          for (const el of document.querySelectorAll('[role="alert"],[role="status"],[aria-live]:not([aria-live="off"]),.u-VisuallyHidden,.u-vh'))
            push('text', el.textContent, el);
          return { lang: document.documentElement.lang || '', names: out.slice(0, 400) };
        })) });
      } catch (e) { /* a frame that navigated away: axe reports it in errors */ }
    }
  };

  const runs = await runAxe('page');
  await readNames('page');
  const dialogs = [];

  for (const sel of OPTS.dialogs) {
    const res = { selector: sel, found: false, opened: false, focusIn: false,
                  tabStays: false, shiftTabStays: false, escCloses: false, focusReturns: false };
    dialogs.push(res);
    const opener = page.locator(sel).first();
    if (!(await opener.count())) continue;
    res.found = true;
    await markPresent();
    const before = await visibleDialogs();
    await opener.focus().catch(() => {});
    await opener.click();
    try {
      await page.waitForFunction((n) => [...document.querySelectorAll('[role="dialog"], .ui-dialog')]
        .filter((d) => d.getClientRects().length > 0).length > n, before, { timeout: 10000 });
    } catch (e) { await unmark(); continue; }
    res.opened = await markOpened();
    await page.waitForTimeout(1000);              // the dialog's page loads and places focus

    runs.push(...await runAxe('dialog ' + sel));  // as opened, before the keyboard moves anything
    await readNames('dialog ' + sel);
    res.focusIn = await focusInDialog();
    const walk = async (key) => {
      for (let i = 0; i < 30; i++) {
        await page.keyboard.press(key);
        if (!(await focusInDialog())) return false;
      }
      return true;
    };
    res.tabStays = res.focusIn && await walk('Tab');
    res.shiftTabStays = res.focusIn && await walk('Shift+Tab');

    await page.keyboard.press('Escape');
    try {
      await page.waitForFunction((m) => {
        const d = document.querySelector('[' + m + '="open"]');
        return !d || d.getClientRects().length === 0;
      }, MARK, { timeout: 5000 });
      res.escCloses = true;
    } catch (e) { /* still open: escCloses stays false */ }
    await page.waitForTimeout(300);
    // the opener, or the control wrapping it (a text= selector matches the label inside a link)
    res.focusReturns = res.escCloses && await opener.evaluate((el) => {
      const a = document.activeElement;
      return !!a && a !== document.body && (a === el || el.contains(a) || a.contains(el));
    }).catch(() => false);
    await unmark();
  }

  // UX-REFLOW: the page at each narrow width — horizontal page scroll, content cut off by a
  // container that cannot scroll, scroll regions the keyboard cannot reach, controls under 24 px
  // (axe target-size at that width). The viewport is put back. Candidates, read by a person:
  // a wide table that scrolls inside its own focusable container is not one.
  const reflow = [];
  if ((OPTS.reflow || []).length) {
    const size = page.viewportSize() || await page.evaluate(() => ({ width: innerWidth, height: innerHeight }));
    try {
      for (const width of OPTS.reflow) {
        await page.setViewportSize({ width, height: Math.max(size.height, 640) });
        await page.waitForTimeout(700);
        const r = await page.evaluate(() => {
          const de = document.documentElement, vw = de.clientWidth;
          const css = (e) => e.tagName.toLowerCase() + (e.id ? '#' + e.id : '') +
            (typeof e.className === 'string' && e.className.trim() ? '.' + e.className.trim().split(/\s+/)[0] : '');
          const shown = (e) => { const c = getComputedStyle(e), b = e.getBoundingClientRect();
            return c.display !== 'none' && c.visibility !== 'hidden' && b.width > 1 && b.height > 1; };
          const clipped = [], unreachable = [];
          for (const el of document.body.querySelectorAll('*')) {
            if (!shown(el)) continue;
            const cs = getComputedStyle(el), r = el.getBoundingClientRect();
            if (el.scrollWidth <= el.clientWidth + 1 || cs.textOverflow === 'ellipsis') continue;
            if (r.right <= 0 || r.left >= vw) continue;                    // an off-canvas part
            if (cs.overflowX === 'hidden' || cs.overflowX === 'clip') {
              // cut off for real: a visible cell, control or text block ends beyond the container
              const cut = [...el.querySelectorAll('td,th,a[href],button,input,select,textarea,p,li,h1,h2,h3,label')]
                .some((d) => shown(d) && d.getBoundingClientRect().right > r.right + 1 && d.getBoundingClientRect().left < r.right + 2000);
              if (cut) clipped.push(el);
            } else if ((cs.overflowX === 'auto' || cs.overflowX === 'scroll') &&
                       !(el.tabIndex >= 0 || el.querySelector('a[href],button,input,select,textarea,[tabindex]'))) {
              unreachable.push(el);
            }
          }
          const inner = (list) => list.filter((e) => !list.some((o) => o !== e && e.contains(o))).slice(0, 10).map(css);
          return { pageOverflowsX: de.scrollWidth > de.clientWidth + 1, clipped: inner(clipped), unreachable: inner(unreachable) };
        });
        try {
          if (!(await page.evaluate(() => !!window.axe))) await page.addScriptTag({ content: AXE });
          const t = await page.evaluate(() => window.axe.run(document, { runOnly: { type: 'rule', values: ['target-size'] }, resultTypes: ['violations'] }));
          r.smallTargets = t.violations.reduce((n, v) => n + v.nodes.length, 0);
          r.smallTargetList = t.violations.flatMap((v) => v.nodes.map((n) => n.target.join(' '))).slice(0, 10);
        } catch (e) { r.smallTargets = null; }
        reflow.push({ width, ...r });
      }
    } catch (e) {
      errors.push({ where: 'reflow', frame: page.url(), error: String(e && e.message || e).slice(0, 300) });
    } finally {
      await page.setViewportSize(size).catch(() => {});
    }
  }

  // the APEX version that rendered the page: oracle-owned.json entries are per version
  const apexVersion = await page.evaluate(() => (window.apex && apex.env && apex.env.APEX_BASE_VERSION) || null).catch(() => null);
  return JSON.stringify({ verdict: 'OK', url: page.url(), apex: apexVersion, runs, dialogs, names, reflow, errors });
}
