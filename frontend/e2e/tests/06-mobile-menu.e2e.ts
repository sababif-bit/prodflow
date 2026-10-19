import { expect, test } from '@playwright/test';
import { signIn } from '../support';

/** The navigation drawer below the desktop breakpoint, used with the keyboard only (WCAG: focus order, no hidden focusable content). */
test.describe('Mobiles Menü: Tastaturbedienung', () => {
  test.use({ viewport: { width: 390, height: 844 } });

  test('geschlossen unsichtbar, geöffnet mit Fokus im Menü, Escape schließt und gibt den Fokus zurück', async ({
    page,
  }) => {
    await signIn(page, 'planner');
    const link = page
      .getByRole('navigation', { name: 'Hauptnavigation' })
      .getByRole('link', { name: 'Fertigungsaufträge' });
    const button = page.getByRole('button', { name: 'Menü öffnen' });

    // closed: the links are neither visible nor reachable with Tab
    await expect(link).toBeHidden();
    for (let i = 0; i < 12; i++) {
      await page.keyboard.press('Tab');
      expect(await page.evaluate(() => !!document.activeElement?.closest('aside'))).toBe(false);
    }

    await button.focus();
    await page.keyboard.press('Enter');
    await expect(link).toBeVisible();
    await expect(
      page.getByRole('navigation', { name: 'Hauptnavigation' }).getByRole('link').first(),
    ).toBeFocused();
    await expect(button).toHaveAttribute('aria-expanded', 'true');
    expect(
      await page.evaluate(() => (document.querySelector('div.min-h-screen') as HTMLElement).inert),
    ).toBe(true);

    // open: Tab stays inside the drawer (the page behind it is inert)
    for (let i = 0; i < 10; i++) {
      await page.keyboard.press('Tab');
      expect(await page.evaluate(() => !!document.activeElement?.closest('aside'))).toBe(true);
    }

    await page.keyboard.press('Escape');
    await expect(link).toBeHidden();
    await expect(button).toBeFocused();
    await expect(button).toHaveAttribute('aria-expanded', 'false');
    expect(
      await page.evaluate(() => (document.querySelector('div.min-h-screen') as HTMLElement).inert),
    ).toBe(false);
  });

  test('ein Link im Menü navigiert und schließt das Menü; die aktuelle Seite ist markiert', async ({
    page,
  }) => {
    await signIn(page, 'planner');
    await page.getByRole('button', { name: 'Menü öffnen' }).click();
    const nav = page.getByRole('navigation', { name: 'Hauptnavigation' });
    await nav.getByRole('link', { name: 'Bestand & Artikel' }).click();
    await expect(page.getByRole('heading', { name: 'Bestand & Artikel', level: 1 })).toBeVisible();
    await expect(nav.getByRole('link', { name: 'Bestand & Artikel' })).toBeHidden(); // drawer closed again
    await page.getByRole('button', { name: 'Menü öffnen' }).click();
    await expect(nav.getByRole('link', { name: 'Bestand & Artikel' })).toHaveAttribute(
      'aria-current',
      'page',
    );
    await expect(nav.getByRole('link', { name: 'Übersicht' })).not.toHaveAttribute(
      'aria-current',
      'page',
    );
  });
});
