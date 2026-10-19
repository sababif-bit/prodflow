import { expect, test } from '@playwright/test';
import { openNav, signIn } from '../support';

/**
 * Error handling of mutations and loads. The real backend cannot be made to answer 403/409/5xx on demand through the UI,
 * so these tests intercept the single call and verify what the USER sees. (Real 401/403/2xx behavior of the backend is covered
 * by the backend's own tests and by scripts/smoke-auth.sh; the workflow spec proves the happy path against the real API.)
 */
const OPEN_REQUEST = [
  {
    id: 99,
    itemId: 2,
    itemCode: 'SC-M8',
    itemName: 'Hex screw M8x30',
    unit: 'pcs',
    quantity: 15,
    status: 'OPEN',
    orderNo: 'FA-00099',
    createdAt: '2026-10-19T10:00:00',
  },
];

test.describe('Fehlerbehandlung', () => {
  test.beforeEach(async ({ page }) => {
    await signIn(page, 'purchaser');
    await page.route('**/api/purchase-requests', (route) => route.fulfill({ json: OPEN_REQUEST }));
  });

  test('403 bei einer Aktion: verständliche Meldung, Liste bleibt bedienbar', async ({ page }) => {
    await page.route('**/api/purchase-requests/99/approve', (route) =>
      route.fulfill({
        status: 403,
        headers: { 'www-authenticate': 'Bearer error="insufficient_scope"' },
        body: '',
      }),
    );
    await openNav(page, 'Bestellanforderungen');
    await page.getByRole('button', { name: 'Genehmigen' }).click();
    await page.getByRole('alertdialog').getByRole('button', { name: 'Genehmigen' }).click();
    await expect(page.getByText('Genehmigung: Keine Berechtigung')).toBeVisible();
    await expect(page.getByText('Ihre Rolle darf diese Aktion nicht ausführen.')).toBeVisible();
    await expect(page.locator('div[role="alertdialog"]')).toBeHidden(); // the confirmation closed itself
    await expect(
      page.getByRole('row', { name: /SC-M8/ }).getByRole('button', { name: 'Genehmigen' }),
    ).toBeVisible(); // still usable, nothing half-done
  });

  test('409 (Geschäftsregel): die Begründung des Servers wird angezeigt', async ({ page }) => {
    await page.route('**/api/purchase-requests/99/approve', (route) =>
      route.fulfill({
        status: 409,
        contentType: 'application/problem+json',
        body: JSON.stringify({
          title: 'Conflict',
          status: 409,
          detail: 'Only OPEN requests can be approved (request is APPROVED)',
        }),
      }),
    );
    await openNav(page, 'Bestellanforderungen');
    await page.getByRole('button', { name: 'Genehmigen' }).click();
    await page.getByRole('alertdialog').getByRole('button', { name: 'Genehmigen' }).click();
    await expect(page.getByText('Genehmigung: Aktion nicht möglich')).toBeVisible();
    await expect(
      page.getByText('Only OPEN requests can be approved (request is APPROVED)'),
    ).toBeVisible();
  });

  test('Netzwerkfehler beim Laden: Fehlerzustand mit "Erneut versuchen"', async ({ page }) => {
    await page.unroute('**/api/purchase-requests');
    await page.route('**/api/purchase-requests', (route) => route.abort('connectionrefused'));
    await openNav(page, 'Bestellanforderungen');
    await expect(page.getByRole('alert').getByText('Keine Verbindung')).toBeVisible();
    // the connection comes back: retry loads the data
    await page.unroute('**/api/purchase-requests');
    await page.route('**/api/purchase-requests', (route) => route.fulfill({ json: OPEN_REQUEST }));
    await page.getByRole('button', { name: 'Erneut versuchen' }).click();
    await expect(page.getByRole('row', { name: /SC-M8/ })).toBeVisible();
  });

  test('Serverfehler 500 beim Laden: verständlicher Fehlerzustand', async ({ page }) => {
    await page.unroute('**/api/purchase-requests');
    await page.route('**/api/purchase-requests', (route) =>
      route.fulfill({ status: 500, body: '' }),
    );
    await openNav(page, 'Bestellanforderungen');
    await expect(page.getByRole('alert').getByText('Serverfehler')).toBeVisible();
  });

  test('401 der API (abgelaufene Sitzung): die Anwendung leitet zur Anmeldung um', async ({
    page,
  }) => {
    await page.route('**/api/items', (route) => route.fulfill({ status: 401, body: '' }));
    const loginRedirect = page.waitForRequest(
      (request) => request.url().includes('/protocol/openid-connect/auth'),
      { timeout: 15_000 },
    );
    await openNav(page, 'Bestand & Artikel');
    await loginRedirect;
  });
});

test.describe('Unbekannte Adressen und fehlende Rechte', () => {
  test('unbekannte Adresse zeigt eine klare Seite', async ({ page }) => {
    await signIn(page, 'planner');
    await page.goto('/gibt-es-nicht');
    await expect(page.getByRole('heading', { name: 'Seite nicht gefunden' })).toBeVisible();
  });
});
