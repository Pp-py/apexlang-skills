// sec-probe — the browser half of apex-security's runtime probes. Not run directly: sec-probe.py
// wraps it as `async (page) => (<this>)(page, OPTS)` and hands it to `pw.sh run-code`, in the
// session the agent logged in (or, for the role probe, the low-privilege user's own session).
//   OPTS  { open: [url, ...], tamper: bool, xss: token | null }
// Returns one JSON string: { verdict: 'OK' | 'NOT-LOGGED-IN', url, open, tamper, xss }.
// What APEX rendered is judged by its page id (#pFlowStepId), never by what the page looks like.
async (page, OPTS) => {
  const onLogin = /\/login(\?|#|$)/i.test(page.url()) ||
    (await page.locator('input[type="password"]:visible').count()) > 0;
  if (onLogin) return JSON.stringify({ verdict: 'NOT-LOGGED-IN', url: page.url() });

  // Load a URL in a new tab of this session, read what APEX rendered, close the tab: the
  // agent's own page never moves.
  // A URL with no session= gets the held one: with session rejoin off (Oracle's baseline) APEX
  // answers a URL without it with a NEW session and the login page — every control would fail.
  const held = await page.evaluate(() => (window.apex && apex.env && apex.env.APP_SESSION) || '').catch(() => '');
  const withSession = (url) => page.evaluate(([u, s]) => {
    const x = new URL(u, location.href);
    if (s && !x.searchParams.has('session')) x.searchParams.set('session', s);
    return x.href;
  }, [url, held]);
  const load = async (url) => {
    const p = await page.context().newPage();
    try {
      const r = await p.goto(await withSession(url), { waitUntil: 'load', timeout: 30000 });
      const s = await p.evaluate(() => {
        const e = document.getElementById('pFlowStepId');
        // APEX renders its refusals (a checksum violation, an authorization failure, an ended
        // session) as an error page that still carries the requested page's id: the step alone
        // would read them as "rendered". The error page's own markup tells them apart.
        const error = !!document.querySelector('.t-Alert-errorTitle, .a-Error-back, #APEX_ERROR_MESSAGE:not(.u-hidden)');
        return { step: e ? e.value : null, login: !!document.querySelector('input[type="password"]'), error };
      });
      return { url, status: r ? r.status() : null, step: s.step, login: s.login, error: s.error };
    } catch (e) {
      return { url, step: null, login: false, error: String(e && e.message || e).slice(0, 200) };
    } finally {
      await p.close().catch(() => {});
    }
  };

  const out = { verdict: 'OK', url: page.url(), open: [] };
  for (const url of OPTS.open) out.open.push(await load(url));

  if (OPTS.tamper) {
    // The first same-origin link that carries a checksum, in any frame. URLs are built in
    // the page: run-code's sandbox has no global URL class.
    const origin = await page.evaluate(() => location.origin);
    let link = null;
    for (const f of page.frames()) {
      // a modal page's link is `#action$a-dialog-open?url=<the URL, encoded>`: decode it
      const hrefs = await f.$$eval('a[href*="cs="], a[href*="cs%3D"]', (as) => as.map((a) => {
        const m = (a.getAttribute('href') || '').match(/a-dialog-open\?url=([^&#]+)/);
        if (!m) return a.href;
        try { return new URL(decodeURIComponent(m[1]), location.href).href; } catch (e) { return ''; }
      })).catch(() => []);
      link = hrefs.find((h) => h.startsWith(origin + '/') && /[?&]cs=/.test(h));
      if (link) break;
    }
    if (link) {
      // without its checksum; and with the first item value (for f?p=, its last field) one
      // digit longer — same checksum, another value
      const v = await page.evaluate((l) => {
        const noCs = new URL(l); noCs.searchParams.delete('cs');
        const alt = new URL(l);
        const key = [...alt.searchParams.keys()].find((k) => !/^(cs|session|request|clear|debug|p_trace)$/i.test(k));
        if (key) alt.searchParams.set(key, alt.searchParams.get(key) + '9');
        return { noCs: noCs.href, altered: key ? alt.href : null };
      }, link);
      out.tamper = { link, control: await load(link), noChecksum: await load(v.noCs),
                     altered: v.altered ? await load(v.altered) : null };
    } else out.tamper = { link: null };
  }

  if (OPTS.xss) {
    const sel = '[data-xss-probe="' + OPTS.xss + '"]';
    let elements = 0, text = false;
    for (const f of page.frames()) {
      elements += await f.locator(sel).count().catch(() => 0);
      text = text || await f.evaluate((t) => !!document.body &&
        document.body.innerText.includes('data-xss-probe="' + t + '"'), OPTS.xss).catch(() => false);
    }
    out.xss = { elements, text };
  }
  return JSON.stringify(out);
}
