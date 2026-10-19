import { expect, test } from '@playwright/test';
import { DISPOSABLE_KEYCLOAK, signIn, useDisposableConfig } from '../support';

test.describe('Anmeldung (Authorization Code + PKCE gegen echtes Keycloak)', () => {
  test('ohne Anmeldung wird zum Keycloak-Login weitergeleitet (PKCE S256, Code-Flow)', async ({
    page,
  }) => {
    await useDisposableConfig(page);
    await page.goto('/');
    await expect(page.locator('#username')).toBeVisible({ timeout: 30_000 });
    const url = new URL(page.url());
    expect(url.origin).toBe(DISPOSABLE_KEYCLOAK);
    expect(url.searchParams.get('client_id')).toBe('prodflow-web');
    expect(url.searchParams.get('response_type')).toBe('code');
    expect(url.searchParams.get('code_challenge_method')).toBe('S256');
    expect(url.searchParams.get('code_challenge')).toBeTruthy();
  });

  test('Planer meldet sich an: Name, Rolle und Navigation sind sichtbar', async ({ page }) => {
    await signIn(page, 'planner');
    await expect(page).toHaveURL(/\/uebersicht$/);
    await expect(page.getByText('Planer', { exact: true }).first()).toBeVisible();
    const nav = page.getByRole('navigation', { name: 'Hauptnavigation' });
    for (const label of [
      'Übersicht',
      'Fertigungsaufträge',
      'Bestellanforderungen',
      'Bestand & Artikel',
    ]) {
      await expect(nav.getByRole('link', { name: label })).toBeVisible();
    }
    await expect(page).toHaveTitle(/Übersicht – ProdFlow/);
  });

  test('Token liegt nur im Speicher: kein Token in localStorage, sessionStorage oder Cookies der Anwendung', async ({
    page,
  }) => {
    await signIn(page, 'planner');
    const storage = await page.evaluate(() =>
      JSON.stringify({ local: { ...localStorage }, session: { ...sessionStorage } }),
    );
    expect(storage).not.toMatch(/eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/); // no JWT anywhere
    const cookies = await page.context().cookies('http://localhost:4200');
    expect(cookies).toHaveLength(0);
  });

  test('Der Bearer-Token geht nur an die eigene API, nie an eine andere Herkunft', async ({
    page,
  }) => {
    const seen: { url: string; hasAuth: boolean }[] = [];
    page.on('request', (request) =>
      seen.push({ url: request.url(), hasAuth: !!request.headers()['authorization'] }),
    );
    await signIn(page, 'planner');
    await page
      .getByRole('navigation', { name: 'Hauptnavigation' })
      .getByRole('link', { name: 'Bestand & Artikel' })
      .click();
    await expect(page.getByRole('link', { name: 'MR-200' }).first()).toBeVisible();
    const withAuth = seen.filter((r) => r.hasAuth);
    expect(withAuth.length).toBeGreaterThan(0);
    for (const request of withAuth) {
      expect(new URL(request.url).origin).toBe('http://localhost:4200');
      expect(new URL(request.url).pathname).toMatch(/^\/api\//);
    }
    const versionCall = seen.find((r) => r.url.endsWith('/version'));
    expect(versionCall?.hasAuth).toBe(false);
  });

  test('Abmelden beendet die Sitzung: danach verlangt die Anwendung wieder eine Anmeldung', async ({
    page,
  }) => {
    await signIn(page, 'planner');
    await page.getByRole('button', { name: 'Abmelden' }).click();
    // Keycloak ends the session; whichever page it shows, a new visit must ask for credentials again
    await page.waitForLoadState('networkidle');
    await useDisposableConfig(page);
    await page.goto('/');
    await expect(page.locator('#username')).toBeVisible({ timeout: 30_000 });
  });
});
