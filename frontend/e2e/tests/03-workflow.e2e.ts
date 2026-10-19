import { expect, Page, test } from '@playwright/test';
import { openNav, signIn } from '../support';

/**
 * The demo workflow end to end through the UI, with two roles, against the disposable stack:
 * order MR-200 x 10 -> shortage 15 SC-M8 -> ONE purchase request -> planner cannot approve -> purchaser approves and receives
 * -> order released by the system -> planner completes -> final stock.
 * Order matters (serial): each step builds on the previous one.
 */
test.describe.configure({ mode: 'serial' });

const confirmIn = (page: Page, label: string) =>
  page.getByRole('alertdialog').getByRole('button', { name: label });

test.describe('Geschäftsablauf: Auftrag -> Fehlmenge -> Bestellung -> Freigabe -> Abschluss', () => {
  test('Planer legt den Auftrag MR-200 x 10 an und sieht die Fehlmenge von 15 SC-M8', async ({
    page,
  }) => {
    await signIn(page, 'planner');
    await openNav(page, 'Fertigungsaufträge');
    await page.getByRole('button', { name: 'Neuer Auftrag' }).click();
    const dialog = page.getByRole('dialog', { name: 'Neuen Fertigungsauftrag anlegen' });
    await dialog.locator('p-select').click();
    await page.getByRole('option', { name: /MR-200/ }).click();
    await dialog.locator('#order-qty').fill('10');
    await dialog.getByRole('button', { name: 'Anlegen und Material prüfen' }).click();

    const result = page.getByRole('dialog', { name: /Materialprüfung/ });
    await expect(result).toBeVisible();
    await expect(result.getByText('Wartet auf Material').first()).toBeVisible();
    await expect(result.getByText('Bei 1 Material fehlt Bestand')).toBeVisible();
    const row = result.getByRole('row', { name: /SC-M8/ });
    await expect(row).toContainText('40 pcs'); // required
    await expect(row).toContainText('25 pcs'); // available
    await expect(row).toContainText('15 pcs'); // shortage and newly requested
    await result.getByRole('button', { name: 'Schließen' }).click();

    const orderRow = page.getByRole('row', { name: /FA-00001/ });
    await expect(orderRow).toContainText('MR-200');
    await expect(orderRow).toContainText('Wartet auf Material');
  });

  test('Planer sieht die Bestellanforderung, darf sie aber nicht genehmigen', async ({ page }) => {
    await signIn(page, 'planner');
    await openNav(page, 'Bestellanforderungen');
    const row = page.getByRole('row', { name: /SC-M8/ });
    await expect(row).toContainText('15 pcs');
    await expect(row).toContainText('Offen');
    await expect(row).toContainText('FA-00001');
    await expect(page.getByRole('button', { name: 'Genehmigen' })).toHaveCount(0);
    await expect(page.getByRole('button', { name: 'Wareneingang buchen' })).toHaveCount(0);
  });

  test('Einkäufer genehmigt und bucht den Wareneingang', async ({ page }) => {
    await signIn(page, 'purchaser');
    await openNav(page, 'Bestellanforderungen');
    const row = page.getByRole('row', { name: /SC-M8/ });
    await row.getByRole('button', { name: 'Genehmigen' }).click();
    await confirmIn(page, 'Genehmigen').click();
    await expect(row).toContainText('Genehmigt');
    await expect(page.getByText('genehmigt', { exact: false }).first()).toBeVisible();

    await row.getByRole('button', { name: 'Wareneingang buchen' }).click();
    await confirmIn(page, 'Wareneingang buchen').click();
    await expect(row).toContainText('Wareneingang gebucht');
    await expect(page.getByText('wartende Aufträge wurden vom System neu geprüft')).toBeVisible();
  });

  test('Der Auftrag wurde vom System automatisch freigegeben; Planer schließt ihn ab', async ({
    page,
  }) => {
    await signIn(page, 'planner');
    await openNav(page, 'Fertigungsaufträge');
    const row = page.getByRole('row', { name: /FA-00001/ });
    await expect(row).toContainText('Freigegeben');
    await row.getByRole('button', { name: 'Abschließen' }).click();
    await confirmIn(page, 'Abschließen').click();
    await expect(row).toContainText('Abgeschlossen');
    await expect(row.getByRole('button', { name: 'Abschließen' })).toHaveCount(0);
  });

  test('Endbestand stimmt: MR-200 10, SC-M8 0, PL-ST3 10, PR-40 15, BR-L60 20', async ({
    page,
  }) => {
    await signIn(page, 'planner');
    await openNav(page, 'Bestand & Artikel');
    const expected: Record<string, string> = {
      'MR-200': '10 pcs',
      'SC-M8': '0 pcs',
      'PL-ST3': '10 pcs',
      'PR-40': '15 m',
      'BR-L60': '20 pcs',
    };
    for (const [code, qty] of Object.entries(expected)) {
      await expect(
        page.getByRole('row', { name: new RegExp(`^${code}\\b`) }).first(),
      ).toContainText(qty);
    }
  });

  test('Auftragsdetail und Übersicht spiegeln den Abschluss', async ({ page }) => {
    await signIn(page, 'planner');
    await expect(page.getByRole('link', { name: 'Abgeschlossen: 1' })).toBeVisible();
    await expect(page.getByRole('link', { name: 'Aufträge gesamt: 1' })).toBeVisible();
    await openNav(page, 'Fertigungsaufträge');
    await page.getByRole('link', { name: 'FA-00001' }).first().click();
    await expect(page.getByRole('heading', { name: 'FA-00001', level: 1 })).toBeVisible();
    await expect(page.getByText('Der Auftrag ist abgeschlossen')).toBeVisible();
    await expect(page.getByRole('row', { name: /SC-M8/ })).toContainText('Wareneingang gebucht');
  });
});
