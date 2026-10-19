import { expect, Page, test } from '@playwright/test';

/**
 * The deployed application as a browser sees it: HTTPS through Caddy, Content-Security-Policy in force, runtime configuration from the
 * backend, Keycloak sign-in and sign-out with the realm of the production import file. Passwords come from the environment of
 * scripts/test-prod-stack.sh (random, never printed).
 */
const PLANNER_PASSWORD = process.env['PRODSTACK_PLANNER_PASSWORD'];
test.skip(!PLANNER_PASSWORD, 'run through scripts/test-prod-stack.sh');

/** Everything the browser reports as a policy violation or error while the page runs. */
function watch(page: Page): string[] {
  const problems: string[] = [];
  page.on('console', (message) => {
    if (message.type() === 'error' || /content security policy/i.test(message.text())) {
      problems.push(`${message.type()}: ${message.text()}`);
    }
  });
  page.on('pageerror', (error) => problems.push(`pageerror: ${error.message}`));
  return problems;
}

async function signIn(page: Page): Promise<void> {
  await page.goto('/');
  await page.locator('#username').fill('planner');
  await page.locator('#password').fill(PLANNER_PASSWORD!);
  await page.locator('#kc-login').click();
  await expect(page.getByRole('navigation', { name: 'Hauptnavigation' })).toBeVisible({
    timeout: 45_000,
  });
}

test.describe('Produktionsnaher Stack (Caddy, HTTPS, CSP, Keycloak)', () => {
  test('Anmeldung, alle Seiten und Neuladen einer Unterseite laufen ohne CSP-Verstöße; Styles sind geladen', async ({
    page,
  }) => {
    const problems = watch(page);
    await signIn(page);
    expect(new URL(page.url()).origin).toBe('https://app.prodflow.test');

    // the stylesheet is a normal <link> (no inline handler) and was applied: the dark sidebar and the self-hosted font are in effect
    const styled = await page.evaluate(() => ({
      sidebar: getComputedStyle(document.querySelector('aside')!).backgroundColor,
      font: getComputedStyle(document.body).fontFamily,
    }));
    expect(styled.sidebar).not.toBe('rgba(0, 0, 0, 0)');
    expect(styled.font).toContain('IBM Plex Sans');

    const nav = page.getByRole('navigation', { name: 'Hauptnavigation' });
    for (const [label, heading] of [
      ['Fertigungsaufträge', 'Fertigungsaufträge'],
      ['Bestellanforderungen', 'Bestellanforderungen'],
      ['Bestand & Artikel', 'Bestand & Artikel'],
      ['Übersicht', 'Übersicht'],
    ]) {
      await nav.getByRole('link', { name: label }).click();
      await expect(page.getByRole('heading', { name: heading, level: 1 })).toBeVisible();
      await page.waitForLoadState('networkidle');
    }

    // a reload on a deep link is answered with the application (SPA fallback) and the session carries on
    await nav.getByRole('link', { name: 'Bestand & Artikel' }).click();
    await expect(page.getByRole('link', { name: 'MR-200', exact: true }).first()).toBeVisible();
    await page.getByRole('link', { name: 'MR-200', exact: true }).first().click();
    await expect(page.getByRole('heading', { name: 'MR-200', level: 1 })).toBeVisible();
    await page.reload();
    await expect(page.getByRole('heading', { name: 'MR-200', level: 1 })).toBeVisible({
      timeout: 45_000,
    });
    await page.waitForLoadState('networkidle');
    expect(problems).toEqual([]);
  });

  test('Abmelden führt über Keycloak zurück zur Anwendung (post-logout redirect auf HTTPS)', async ({
    page,
  }) => {
    await signIn(page);
    await page.getByRole('button', { name: 'Abmelden' }).click();
    await expect(page.locator('#username')).toBeVisible({ timeout: 30_000 });
    await expect(page.locator('body')).not.toContainText(/invalid|ungültig/i);
    expect(new URL(page.url()).searchParams.get('redirect_uri')).toBe('https://app.prodflow.test/');
  });

  test('Swagger UI (dokumentierte Demo-Ausnahme) lädt unter seiner eigenen CSP', async ({
    page,
  }) => {
    const problems = watch(page);
    await page.goto('/swagger-ui/index.html');
    await expect(page.locator('.swagger-ui .info .title')).toBeVisible({ timeout: 30_000 });
    expect(problems).toEqual([]);
  });

  test('Die Seite lässt sich nicht einbetten und lädt nichts von fremden Herkunftsorten', async ({
    page,
  }) => {
    const external: string[] = [];
    page.on('request', (r) => {
      const origin = new URL(r.url()).origin;
      if (
        !['https://app.prodflow.test', 'https://auth.prodflow.test'].includes(origin) &&
        !r.url().startsWith('data:')
      )
        external.push(r.url());
    });
    const response = await page.goto('/uebersicht'); // the application document itself, before the sign-in redirect
    expect(response?.headers()['content-security-policy']).toContain("frame-ancestors 'none'");
    await signIn(page);
    expect(external).toEqual([]);
  });
});
