import { expect, Page, Request, test } from '@playwright/test';

/**
 * Read-only browser smoke test of a deployed ProdFlow: real Keycloak sign-in (Authorization Code + PKCE) with the EXISTING demo accounts,
 * every page, role-dependent controls, deep-link reload, sign-out. Run by hand (frontend/e2e-production/README.md); not part of CI.
 *
 * Safety properties (each one is enforced in code, not only by convention):
 *  - GET navigation only; the spec never clicks an action button (no create, approve, receive, complete).
 *  - Defense in depth: every non-GET request to /api is aborted by a route handler and fails the test.
 *  - Passwords come from the environment, are never logged, and failures from the sign-in step are re-thrown WITHOUT Playwright's call log
 *    (which would contain the typed value). Tracing, video and screenshots are off (see the configuration).
 */
const APP = new URL(process.env['PROD_APP_URL'] ?? 'https://invalid.example').origin;
const PASSWORDS: Record<string, string | undefined> = {
  planner: process.env['PRODSMOKE_PLANNER_PASSWORD'],
  purchaser: process.env['PRODSMOKE_PURCHASER_PASSWORD'],
};
const EXPECTED_AUTH = process.env['PROD_AUTH_URL']
  ? new URL(process.env['PROD_AUTH_URL']).origin
  : undefined;

interface ApiCall {
  method: string;
  path: string;
  status: number;
}

interface Observed {
  console: string[];
  pageErrors: string[];
  /** Requests that really failed (network error, or aborted WITHOUT a successful response). */
  failedRequests: string[];
  /** GET requests Chromium reports as ERR_ABORTED although the response (status < 400) had already arrived: a client-side abort after completion. */
  abortedAfterResponse: string[];
  badResponses: string[];
  blockedWrites: string[];
  apiCalls: ApiCall[];
  pending: Promise<void>[];
}

const display = (url: string): string => {
  const u = new URL(url);
  return `${u.origin}${u.pathname}`; // never the query string (it may carry codes/state during sign-in)
};

/** Records what a user does not see but an operator must: console errors, CSP violations, failed/aborted/4xx/5xx requests; blocks writes. */
async function observe(page: Page): Promise<Observed> {
  const o: Observed = {
    console: [],
    pageErrors: [],
    failedRequests: [],
    abortedAfterResponse: [],
    badResponses: [],
    blockedWrites: [],
    apiCalls: [],
    pending: [],
  };
  await page.route(`${APP}/api/**`, async (route) => {
    const method = route.request().method();
    if (method === 'GET') {
      await route.continue();
    } else {
      o.blockedWrites.push(`${method} ${new URL(route.request().url()).pathname}`);
      await route.abort();
    }
  });
  page.on('console', (m) => {
    if (m.type() === 'error' || /content security policy/i.test(m.text()))
      o.console.push(`${m.type()}: ${m.text().slice(0, 200)}`);
  });
  page.on('pageerror', (e) => o.pageErrors.push(e.message.slice(0, 200)));
  page.on('response', (r) => {
    const u = new URL(r.url());
    if (u.origin === APP && u.pathname.startsWith('/api/'))
      o.apiCalls.push({ method: r.request().method(), path: u.pathname, status: r.status() });
    if (r.status() >= 400)
      o.badResponses.push(`${r.status()} ${r.request().method()} ${display(r.url())}`);
  });
  page.on('requestfailed', (r: Request) => {
    const description = `${r.method()} ${display(r.url())} ${r.failure()?.errorText ?? ''}`;
    o.pending.push(
      (async () => {
        const response = await r.response().catch(() => null);
        const aborted = /ERR_ABORTED/.test(r.failure()?.errorText ?? '');
        if (aborted && r.method() === 'GET' && response !== null && response.status() < 400)
          o.abortedAfterResponse.push(description);
        else o.failedRequests.push(description);
      })(),
    );
  });
  return o;
}

/** Runs a step that handles credentials; on failure only the step name is reported (Playwright's call log would contain the typed value). */
async function sensitive(step: string, action: () => Promise<void>): Promise<void> {
  try {
    await action();
  } catch {
    throw new Error(`step "${step}" failed (details withheld: the step handles credentials)`);
  }
}

async function login(page: Page, role: 'planner' | 'purchaser'): Promise<string> {
  const password = PASSWORDS[role];
  if (!password) throw new Error(`PRODSMOKE_${role.toUpperCase()}_PASSWORD is not set`);
  await page.goto('/');
  await expect(page.locator('#username')).toBeVisible({ timeout: 45_000 });
  const url = new URL(page.url());
  const authOrigin = url.origin;
  if (EXPECTED_AUTH) expect(authOrigin).toBe(EXPECTED_AUTH);
  expect(authOrigin).not.toBe(APP);
  expect(url.searchParams.get('client_id')).toBe('prodflow-web');
  expect(url.searchParams.get('response_type')).toBe('code');
  expect(url.searchParams.get('code_challenge_method')).toBe('S256');
  expect(url.searchParams.get('redirect_uri')?.startsWith(APP + '/')).toBe(true);
  await sensitive('enter user name', () => page.locator('#username').fill(role));
  await sensitive('enter password', () => page.locator('#password').fill(password));
  await sensitive('submit sign-in', () => page.locator('#kc-login').click());
  await expect(page.getByRole('main')).toBeVisible({ timeout: 45_000 });
  expect(new URL(page.url()).origin).toBe(APP);
  return authOrigin;
}

function report(label: string, o: Observed, facts: Record<string, unknown>): void {
  const writes = o.apiCalls.filter((c) => c.method !== 'GET');
  const summary = {
    apiGetCalls: o.apiCalls.length,
    apiStatuses: [
      ...new Set(o.apiCalls.map((c) => `${c.method} ${c.path.replace(/\d+/g, ':id')} ${c.status}`)),
    ],
    abortedAfterResponse: o.abortedAfterResponse.length,
    failedRequests: o.failedRequests,
    badResponses: o.badResponses,
    consoleErrors: o.console,
    pageErrors: o.pageErrors,
    blockedWrites: o.blockedWrites,
    ...facts,
  };
  process.stdout.write(`SUMMARY ${label} ${JSON.stringify(summary)}\n`);
  expect(o.blockedWrites, 'the smoke test must never send a write request').toEqual([]);
  expect(writes, 'the smoke test must never send a write request').toEqual([]);
  expect(o.console, 'console errors / CSP violations').toEqual([]);
  expect(o.pageErrors).toEqual([]);
  expect(
    o.failedRequests,
    'failed requests (aborted-after-response GETs are reported separately)',
  ).toEqual([]);
  expect(o.badResponses).toEqual([]);
}

test.skip(!process.env['PROD_APP_URL'], 'PROD_APP_URL is not set');
test.skip(!PASSWORDS['planner'] || !PASSWORDS['purchaser'], 'demo-account passwords not provided');
test.describe.configure({ mode: 'serial' });

test('Konfiguration: die Anwendung nennt einen https-Anmeldeserver (kein localhost)', async ({
  request,
}) => {
  const response = await request.get('/config.json');
  expect(response.ok()).toBe(true);
  const config = (await response.json()) as {
    keycloak: { url: string; realm: string; clientId: string };
  };
  expect(config.keycloak.clientId).toBe('prodflow-web');
  if (APP.startsWith('https://')) {
    expect(config.keycloak.url.startsWith('https://')).toBe(true);
    expect(config.keycloak.url).not.toMatch(/localhost|127\.0\.0\.1/);
  }
  if (EXPECTED_AUTH) expect(new URL(config.keycloak.url).origin).toBe(EXPECTED_AUTH);
});

for (const role of ['planner', 'purchaser'] as const) {
  test(`${role}: Anmeldung (PKCE), alle Seiten lesend, Rollenrechte, Neuladen, Abmelden`, async ({
    page,
  }) => {
    const o = await observe(page);
    const authOrigin = await login(page, role);
    const nav = page.getByRole('navigation', { name: 'Hauptnavigation' });
    const facts: Record<string, unknown> = {};

    const roleLabel = role === 'planner' ? 'Planer' : 'Einkäufer';
    await expect(page.getByText(roleLabel, { exact: true }).first()).toBeVisible();

    await expect(page).toHaveURL(/\/uebersicht$/);
    await expect(page.getByRole('heading', { name: 'Übersicht', level: 1 })).toBeVisible();
    await page.waitForLoadState('networkidle');
    facts['dashboardTiles'] = await page
      .getByRole('link', { name: /: \d+$/ })
      .evaluateAll((els) => els.map((e) => e.getAttribute('aria-label')));

    await nav.getByRole('link', { name: 'Fertigungsaufträge' }).click();
    await expect(page.getByRole('heading', { name: 'Fertigungsaufträge', level: 1 })).toBeVisible();
    await page.waitForLoadState('networkidle');
    facts['orderRows'] = await page.locator('p-table tbody tr').count();
    const newOrder = page.getByRole('button', { name: 'Neuer Auftrag' });
    if (role === 'planner') await expect(newOrder).toBeVisible();
    else await expect(newOrder).toHaveCount(0);

    await nav.getByRole('link', { name: 'Bestellanforderungen' }).click();
    await expect(
      page.getByRole('heading', { name: 'Bestellanforderungen', level: 1 }),
    ).toBeVisible();
    await page.waitForLoadState('networkidle');
    facts['purchaseRows'] = await page.locator('p-table tbody tr').count();
    const approve = page.getByRole('button', { name: 'Genehmigen' });
    const receive = page.getByRole('button', { name: 'Wareneingang buchen' });
    if (role === 'planner') {
      await expect(approve).toHaveCount(0);
      await expect(receive).toHaveCount(0);
      await expect(page.getByText('Funktionstrennung')).toBeVisible();
    }
    // only counted, never clicked
    facts['approveButtonsVisible'] = await approve.count();
    facts['receiveButtonsVisible'] = await receive.count();

    await nav.getByRole('link', { name: 'Bestand & Artikel' }).click();
    await expect(page.getByRole('heading', { name: 'Bestand & Artikel', level: 1 })).toBeVisible();
    await page.waitForLoadState('networkidle');
    facts['inventoryCount'] = (
      await page
        .getByText(/\d+ von \d+ Artikeln/)
        .first()
        .textContent()
    )?.trim();
    const productLink = page.getByRole('link', { name: 'MR-200', exact: true }).first();
    if (await productLink.count()) {
      await productLink.click();
      await expect(page.getByRole('heading', { name: 'MR-200', level: 1 })).toBeVisible();
      await expect(page.getByText('Einstufige Stückliste')).toBeVisible();
      await page.waitForLoadState('networkidle');
      facts['bomRows'] = await page.locator('p-table tbody tr').count();
      await page.reload(); // deep link: SPA fallback and silent session renewal
      await expect(page.getByRole('heading', { name: 'MR-200', level: 1 })).toBeVisible({
        timeout: 45_000,
      });
      await page.waitForLoadState('networkidle');
    }

    // tokens live in memory only
    const storage = await page.evaluate(() =>
      JSON.stringify({ l: { ...localStorage }, s: { ...sessionStorage } }),
    );
    expect(storage).not.toMatch(/eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/);
    expect(await page.context().cookies(APP)).toHaveLength(0);

    await Promise.all(o.pending);
    report(role, o, facts);

    // sign-out returns through Keycloak to the application, which asks for a sign-in again
    await page.getByRole('button', { name: 'Abmelden' }).click();
    await expect(page.locator('#username')).toBeVisible({ timeout: 45_000 });
    await expect(page.locator('body')).not.toContainText(/invalid|ungültig/i);
    expect(new URL(page.url()).origin).toBe(authOrigin);
    expect(new URL(page.url()).searchParams.get('redirect_uri')).toBe(APP + '/');
  });
}

test('Dokument: CSP, HSTS und Deep-Link-Antwort der ausgelieferten Seite', async ({ page }) => {
  const response = await page.goto('/bestand');
  expect(response?.status()).toBe(200);
  const headers = response?.headers() ?? {};
  expect(headers['content-security-policy']).toContain("frame-ancestors 'none'");
  expect(headers['content-security-policy']).toMatch(/script-src 'self'(;|$)/);
  expect(headers['content-security-policy']).not.toMatch(/script-src[^;]*unsafe-inline/);
  expect(headers['x-content-type-options']).toBe('nosniff');
  if (APP.startsWith('https://'))
    expect(headers['strict-transport-security']).toMatch(/max-age=\d+/);
});
