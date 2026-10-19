import { expect, test } from '@playwright/test';
import { openNav, signIn } from '../support';

/** Screens that only read, against the fresh demo baseline (MR-200 0, SC-M8 25, PL-ST3 30, PR-40 50, BR-L60 100; no orders). */
test.describe('Lesende Ansichten mit echten Daten', () => {
  test('Übersicht: echte Zahlen des Ausgangszustands, keine erfundenen Kennzahlen', async ({
    page,
  }) => {
    await signIn(page, 'planner');
    await expect(page.getByRole('link', { name: 'Aufträge gesamt: 0' })).toBeVisible();
    await expect(page.getByRole('link', { name: 'Wartet auf Material: 0' })).toBeVisible();
    await expect(page.getByRole('link', { name: 'Offene Bestellanforderungen: 0' })).toBeVisible();
    await expect(page.getByRole('link', { name: 'Artikel: 5' })).toBeVisible();
    // MR-200 is a PRODUCT; the four materials all have stock, so no material is out of stock
    await expect(page.getByRole('link', { name: 'Material ohne Bestand: 0' })).toBeVisible();
    await expect(page.getByText('Nichts offen').first()).toBeVisible();
  });

  test('Bestand: alle fünf Artikel, Suche und Filter', async ({ page }) => {
    await signIn(page, 'planner');
    await openNav(page, 'Bestand & Artikel');
    for (const code of ['MR-200', 'SC-M8', 'PL-ST3', 'PR-40', 'BR-L60']) {
      await expect(page.getByRole('link', { name: code, exact: true }).first()).toBeVisible();
    }
    await expect(page.getByText('5 von 5 Artikeln')).toBeVisible();
    await page.getByRole('searchbox', { name: 'Artikel suchen' }).fill('sc-m');
    await expect(page.getByText('1 von 5 Artikeln')).toBeVisible();
    await page.getByRole('searchbox', { name: 'Artikel suchen' }).fill('');
    await page.getByRole('button', { name: 'Nur ohne Bestand' }).click();
    await expect(page.getByText('1 von 5 Artikeln')).toBeVisible(); // only MR-200 (no finished goods yet)
    await expect(page.getByRole('link', { name: 'MR-200', exact: true }).first()).toBeVisible();
  });

  test('Artikeldetail eines Produkts: einstufige Stückliste, ehrlicher Hinweis, Produzierbarkeit aus dem Bestand', async ({
    page,
  }) => {
    await signIn(page, 'planner');
    await openNav(page, 'Bestand & Artikel');
    await page.getByRole('link', { name: 'MR-200', exact: true }).first().click();
    await expect(page.getByRole('heading', { name: 'MR-200', level: 1 })).toBeVisible();
    await expect(page.getByText('Einstufige Stückliste')).toBeVisible();
    await expect(page.getByText('noch nicht umgesetzt')).toBeVisible();
    for (const code of ['SC-M8', 'PL-ST3', 'PR-40', 'BR-L60']) {
      await expect(page.getByRole('link', { name: code, exact: true })).toBeVisible();
    }
    // floor(25/4)=6 is the smallest of 6, 15, 14, 12
    await expect(page.getByText('6 Stück').first()).toBeVisible();
    await expect(page.getByText('begrenzt durch SC-M8')).toBeVisible();
  });

  test('Artikeldetail eines Materials: keine Stückliste', async ({ page }) => {
    await signIn(page, 'planner');
    await openNav(page, 'Bestand & Artikel');
    await page.getByRole('link', { name: 'SC-M8', exact: true }).first().click();
    await expect(page.getByText('keine Stückliste')).toBeVisible();
  });

  test('Einkäufer: Aufträge sind lesbar, aber Anlegen ist der Planung vorbehalten (rollenabhängige Aktionen)', async ({
    page,
  }) => {
    await signIn(page, 'purchaser');
    await openNav(page, 'Fertigungsaufträge');
    await expect(page.getByRole('heading', { name: 'Fertigungsaufträge', level: 1 })).toBeVisible();
    await expect(page.getByRole('button', { name: 'Neuer Auftrag' })).toHaveCount(0);
    await expect(page.getByText('der Planung vorbehalten').first()).toBeVisible();
    await expect(page.getByText('Einkäufer', { exact: true }).first()).toBeVisible();
  });

  test('Planer: Bestellanforderungen nur lesbar (Funktionstrennung erklärt)', async ({ page }) => {
    await signIn(page, 'planner');
    await openNav(page, 'Bestellanforderungen');
    await expect(page.getByText('Funktionstrennung')).toBeVisible();
    await expect(page.getByText('Keine Bestellanforderungen')).toBeVisible();
  });
});
