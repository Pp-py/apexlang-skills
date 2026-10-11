// ux-check — the browser half of apex-ux's runtime criteria. Not run directly: ux-check.py
// wraps it as `async (page) => (<this>)(page, AXE, OPTS)` and hands it to
// `pw.sh run-code --raw --filename`, so it runs inside the session the agent already logged in.
//   AXE   the vendored axe-core source, verified against its sha256 lock by the caller
//   OPTS  { tags: [...], dialogs: [selector, ...] }
// Returns one JSON string: { verdict: 'OK' | 'NOT-LOGGED-IN', url, runs: [...], dialogs: [...], errors: [...] }.
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

  const runs = await runAxe('page');
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

  return JSON.stringify({ verdict: 'OK', url: page.url(), runs, dialogs, errors });
}
