import { signal } from '@angular/core';
import { ComponentFixture, TestBed } from '@angular/core/testing';
import { provideRouter, Router } from '@angular/router';
import { ConfirmationService, MessageService } from 'primeng/api';
import { of } from 'rxjs';
import { AuthService } from '../core/auth/auth.service';
import { allows, Permission, Role } from '../core/auth/permissions';
import { VersionApi } from '../shared/api/api-services';
import { Shell } from './shell';

async function render(roles: Role[]): Promise<ComponentFixture<Shell>> {
  TestBed.configureTestingModule({
    providers: [
      provideRouter([{ path: '**', children: [] }]),
      MessageService,
      ConfirmationService,
      {
        provide: AuthService,
        useValue: {
          can: (p: Permission) => allows(roles, p),
          roles: signal(roles),
          user: signal({ username: 'planner', displayName: 'Demo Planner', roles }),
          logout: () => Promise.resolve(),
        },
      },
      { provide: VersionApi, useValue: { get: () => of({ revision: 'unknown' }) } },
    ],
  });
  const fixture = TestBed.createComponent(Shell);
  await fixture.whenStable();
  return fixture;
}

const element = (fixture: ComponentFixture<Shell>) => fixture.nativeElement as HTMLElement;
const sidebar = (fixture: ComponentFixture<Shell>) => element(fixture).querySelector('aside')!;
const page = (fixture: ComponentFixture<Shell>) =>
  element(fixture).querySelector('div.min-h-screen')!;
const menuButton = (fixture: ComponentFixture<Shell>) =>
  element(fixture).querySelector<HTMLButtonElement>('button[aria-controls="sidebar"]')!;

describe('Shell navigation drawer (accessibility below the desktop breakpoint)', () => {
  it('closed: the drawer is invisible to keyboard and screen readers, the page is interactive', async () => {
    const fixture = await render(['PLANNER']);
    expect(sidebar(fixture).classList).toContain('max-lg:invisible');
    expect(sidebar(fixture).classList).toContain('max-lg:-translate-x-full');
    expect(page(fixture).hasAttribute('inert')).toBe(false);
    expect(menuButton(fixture).getAttribute('aria-expanded')).toBe('false');
    expect(menuButton(fixture).getAttribute('aria-controls')).toBe(sidebar(fixture).id);
  });

  it('open: the drawer is reachable, the page behind it is inert and the focus moves to the first link', async () => {
    const fixture = await render(['PLANNER']);
    menuButton(fixture).click();
    await fixture.whenStable();
    fixture.detectChanges();
    expect(sidebar(fixture).classList).not.toContain('max-lg:invisible');
    expect(page(fixture).hasAttribute('inert')).toBe(true);
    expect(menuButton(fixture).getAttribute('aria-expanded')).toBe('true');
    expect(document.activeElement).toBe(sidebar(fixture).querySelector('nav a'));
  });

  it('Escape closes the drawer and gives the focus back to the menu button', async () => {
    const fixture = await render(['PLANNER']);
    document.body.appendChild(element(fixture)); // focus needs the element to be in the document
    menuButton(fixture).click();
    await fixture.whenStable();
    fixture.detectChanges();
    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }));
    await fixture.whenStable();
    fixture.detectChanges();
    expect(sidebar(fixture).classList).toContain('max-lg:invisible');
    expect(page(fixture).hasAttribute('inert')).toBe(false);
    expect(document.activeElement).toBe(menuButton(fixture));
    element(fixture).remove();
  });

  it('Tab on the last link wraps to the first and Shift+Tab on the first wraps to the last (focus stays in the open drawer)', async () => {
    const fixture = await render(['PLANNER']);
    document.body.appendChild(element(fixture));
    menuButton(fixture).click();
    await fixture.whenStable();
    fixture.detectChanges();
    const links = Array.from(sidebar(fixture).querySelectorAll<HTMLElement>('nav a'));
    const last = links[links.length - 1];
    last.focus();
    const forward = new KeyboardEvent('keydown', { key: 'Tab', bubbles: true, cancelable: true });
    last.dispatchEvent(forward);
    expect(forward.defaultPrevented).toBe(true);
    expect(document.activeElement).toBe(links[0]);
    const backward = new KeyboardEvent('keydown', {
      key: 'Tab',
      shiftKey: true,
      bubbles: true,
      cancelable: true,
    });
    links[0].dispatchEvent(backward);
    expect(backward.defaultPrevented).toBe(true);
    expect(document.activeElement).toBe(last);
    // a Tab in the middle of the list is left alone (the browser moves the focus)
    links[1].focus();
    const middle = new KeyboardEvent('keydown', { key: 'Tab', bubbles: true, cancelable: true });
    links[1].dispatchEvent(middle);
    expect(middle.defaultPrevented).toBe(false);
    element(fixture).remove();
  });

  it('Escape does nothing while the drawer is closed (no focus is stolen)', async () => {
    const fixture = await render(['PLANNER']);
    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }));
    await fixture.whenStable();
    expect(document.activeElement).not.toBe(menuButton(fixture));
  });

  it('the navigation marks the current page for assistive technology (aria-current) and hides decorative icons', async () => {
    const fixture = await render(['PLANNER']);
    await TestBed.inject(Router).navigateByUrl('/auftraege');
    fixture.detectChanges();
    const links = Array.from(sidebar(fixture).querySelectorAll('nav a'));
    const current = links.filter((link) => link.getAttribute('aria-current') === 'page');
    expect(current.map((link) => link.textContent?.trim())).toEqual(['Fertigungsaufträge']);
    expect(links[0].querySelector('i')!.getAttribute('aria-hidden')).toBe('true');
  });

  it('shows only the areas the role may read', async () => {
    const fixture = await render(['PURCHASER']);
    const labels = Array.from(sidebar(fixture).querySelectorAll('nav a')).map((a) =>
      a.textContent?.trim(),
    );
    expect(labels).toEqual([
      'Übersicht',
      'Fertigungsaufträge',
      'Bestellanforderungen',
      'Bestand & Artikel',
    ]);
  });
});
