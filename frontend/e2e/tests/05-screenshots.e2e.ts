import { expect, Page, test } from '@playwright/test';
import { join } from 'node:path';
import { openNav, signIn } from '../support';

/**
 * Seeds a few more real orders and captures the screens for the documentation (docs/frontend/screenshots).
 * Runs last: it needs the finished order of the workflow spec and adds a waiting order with two open purchase requests.
 * Data stays in the disposable stack; nothing here touches production.
 */
test.describe.configure({ mode: 'serial' });

const OUT = join(__dirname, '..', '..', '..', 'docs', 'frontend', 'screenshots');
const shot = (page: Page, name: string) =>
  page.screenshot({ path: join(OUT, `${name}.png`), animations: 'disabled' });

test.describe('Screenshots', () => {
  test('Daten: zweiter Auftrag mit Fehlmenge (SC-M8 und BR-L60)', async ({ page }) => {
    await signIn(page, 'planner');
    await openNav(page, 'Fertigungsaufträge');
    await page.getByRole('button', { name: 'Neuer Auftrag' }).click();
    const dialog = page.getByRole('dialog', { name: 'Neuen Fertigungsauftrag anlegen' });
    await dialog.locator('p-select').click();
    await page.getByRole('option', { name: /MR-200/ }).click();
    await dialog.locator('#order-qty').fill('4');
    await shot(page, '05-auftrag-anlegen');
    await dialog.getByRole('button', { name: 'Anlegen und Material prüfen' }).click();
    const result = page.getByRole('dialog', { name: /Materialprüfung/ });
    await expect(result.getByText('Bei 2 Materialien fehlt Bestand')).toBeVisible();
    await shot(page, '06-materialpruefung-fehlmenge');
    await result.getByRole('button', { name: 'Schließen' }).click();
  });

  test('Planer: Übersicht, Aufträge, Auftragsdetail, Bestand, Artikel', async ({ page }) => {
    await signIn(page, 'planner');
    await expect(page.getByRole('link', { name: 'Wartet auf Material: 1' })).toBeVisible();
    await page.waitForLoadState('networkidle');
    await shot(page, '01-uebersicht-planer');

    await openNav(page, 'Fertigungsaufträge');
    await expect(page.getByRole('row', { name: /FA-00002/ })).toBeVisible();
    await shot(page, '02-fertigungsauftraege');

    await page.getByRole('link', { name: 'FA-00002' }).first().click();
    await expect(page.getByRole('heading', { name: 'FA-00002', level: 1 })).toBeVisible();
    await page.waitForLoadState('networkidle');
    await shot(page, '03-auftragsdetail');

    await openNav(page, 'Bestand & Artikel');
    await expect(page.getByText('5 von 5 Artikeln')).toBeVisible();
    await shot(page, '04-bestand');

    await page.getByRole('link', { name: 'MR-200', exact: true }).first().click();
    await expect(page.getByText('Einstufige Stückliste')).toBeVisible();
    await shot(page, '07-artikel-stueckliste');

    await openNav(page, 'Bestellanforderungen');
    await expect(page.getByText('Funktionstrennung')).toBeVisible();
    await shot(page, '08-bestellanforderungen-planer-lesend');
  });

  test('Einkäufer: Bestellanforderungen mit Aktionen', async ({ page }) => {
    await signIn(page, 'purchaser');
    await openNav(page, 'Bestellanforderungen');
    await expect(page.getByRole('button', { name: 'Genehmigen' }).first()).toBeVisible();
    await page.waitForLoadState('networkidle');
    await shot(page, '09-bestellanforderungen-einkaeufer');
    await page.getByRole('button', { name: 'Genehmigen' }).first().click();
    await shot(page, '10-bestaetigung-genehmigen');
  });

  test('Mobile Ansicht (390 x 844): Übersicht und Aufträge', async ({ browser }) => {
    const context = await browser.newContext({
      viewport: { width: 390, height: 844 },
      locale: 'de-DE',
    });
    const page = await context.newPage();
    await signIn(page, 'planner');
    await expect(page.getByRole('link', { name: /Aufträge gesamt/ })).toBeVisible();
    await page.waitForLoadState('networkidle');
    await shot(page, '11-mobil-uebersicht');
    await page.getByRole('button', { name: 'Menü öffnen' }).click();
    await shot(page, '12-mobil-menue');
    await page
      .getByRole('navigation', { name: 'Hauptnavigation' })
      .getByRole('link', { name: 'Fertigungsaufträge' })
      .click();
    await expect(page.getByRole('heading', { name: 'Fertigungsaufträge', level: 1 })).toBeVisible();
    await shot(page, '13-mobil-auftraege');
    await context.close();
  });
});
