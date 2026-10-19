import { Component, computed, inject, signal } from '@angular/core';
import { toSignal } from '@angular/core/rxjs-interop';
import { RouterLink, RouterLinkActive, RouterOutlet } from '@angular/router';
import { catchError, of } from 'rxjs';
import { ConfirmDialog } from 'primeng/confirmdialog';
import { Button } from 'primeng/button';
import { Tag } from 'primeng/tag';
import { Toast } from 'primeng/toast';
import { AuthService } from '../core/auth/auth.service';
import { Permission, ROLE_LABELS } from '../core/auth/permissions';
import { VersionApi } from '../shared/api/api-services';

interface NavItem {
  label: string;
  path: string;
  icon: string;
  permission: Permission;
}

/** Navigation is role-aware: an entry is shown only when the role may read that area (the backend still enforces it). */
const NAVIGATION: readonly NavItem[] = [
  { label: 'Übersicht', path: '/uebersicht', icon: 'pi pi-th-large', permission: 'order.read' },
  { label: 'Fertigungsaufträge', path: '/auftraege', icon: 'pi pi-cog', permission: 'order.read' },
  {
    label: 'Bestellanforderungen',
    path: '/bestellanforderungen',
    icon: 'pi pi-shopping-cart',
    permission: 'purchase.read',
  },
  { label: 'Bestand & Artikel', path: '/bestand', icon: 'pi pi-box', permission: 'item.read' },
];

@Component({
  selector: 'app-shell',
  imports: [RouterOutlet, RouterLink, RouterLinkActive, Toast, ConfirmDialog, Button, Tag],
  template: `
    <a class="pf-skip" href="#main">Zum Inhalt springen</a>

    <aside
      class="fixed inset-y-0 left-0 z-40 flex w-[var(--pf-sidebar-w)] flex-col text-white transition-transform duration-200 lg:translate-x-0"
      style="background: var(--p-primary-900)"
      [class.-translate-x-full]="!menuOpen()"
      aria-label="Seitenleiste"
    >
      <a
        routerLink="/"
        class="flex h-[var(--pf-topbar-h)] items-center gap-3 px-5 text-white no-underline"
      >
        <img src="favicon.svg" width="30" height="30" alt="" />
        <span class="text-lg font-semibold tracking-tight">ProdFlow</span>
      </a>
      <nav class="mt-2 flex flex-1 flex-col gap-1 px-3" aria-label="Hauptnavigation">
        @for (item of navigation(); track item.path) {
          <a
            [routerLink]="item.path"
            routerLinkActive="nav-active"
            class="nav-link flex items-center gap-3 rounded-lg px-3 py-2.5 text-sm font-medium no-underline"
            (click)="menuOpen.set(false)"
          >
            <i [class]="item.icon"></i>
            <span>{{ item.label }}</span>
          </a>
        }
      </nav>
      <div class="px-5 py-4 text-xs" style="color: var(--p-primary-200)">
        <div>Fertigungsplanung & Einkauf</div>
        @if (backendRevision(); as rev) {
          <div class="tabular mt-1" title="Commit des laufenden Backends">Backend {{ rev }}</div>
        }
      </div>
    </aside>

    @if (menuOpen()) {
      <div
        class="fixed inset-0 z-30 bg-black/40 lg:hidden"
        (click)="menuOpen.set(false)"
        aria-hidden="true"
      ></div>
    }

    <div class="min-h-screen lg:pl-[var(--pf-sidebar-w)]">
      <header
        class="sticky top-0 z-20 flex h-[var(--pf-topbar-h)] items-center justify-between gap-3 border-b bg-white px-4 lg:px-8"
        style="border-color: var(--pf-border)"
      >
        <button
          type="button"
          class="rounded-md border-0 bg-transparent p-2 text-surface-700 lg:hidden"
          aria-label="Menü öffnen"
          [attr.aria-expanded]="menuOpen()"
          (click)="menuOpen.set(!menuOpen())"
        >
          <i class="pi pi-bars text-xl"></i>
        </button>
        <div class="hidden text-sm text-surface-500 lg:block">
          Kann ich diesen Auftrag produzieren – und was muss ich einkaufen?
        </div>
        <div class="flex items-center gap-3">
          @if (user(); as u) {
            <div class="hidden text-right sm:block">
              <div class="text-sm font-medium leading-tight text-surface-900">
                {{ u.displayName }}
              </div>
              <div class="mt-0.5 flex justify-end gap-1">
                @for (role of roleLabels(); track role) {
                  <p-tag [value]="role" severity="secondary" />
                }
              </div>
            </div>
            <span
              class="inline-flex h-9 w-9 items-center justify-center rounded-full text-sm font-semibold text-white"
              style="background: var(--p-primary-color)"
              aria-hidden="true"
              >{{ initials() }}</span
            >
          }
          <p-button
            label="Abmelden"
            icon="pi pi-sign-out"
            severity="secondary"
            [text]="true"
            (onClick)="logout()"
          />
        </div>
      </header>

      <main id="main" class="mx-auto max-w-[1400px] p-4 lg:p-8" tabindex="-1">
        <router-outlet />
      </main>
    </div>

    <p-toast position="bottom-right" />
    <p-confirmdialog />
  `,
  styles: [
    `
      .nav-link {
        color: var(--p-primary-100);
      }
      .nav-link:hover {
        background: rgb(255 255 255 / 0.08);
        color: #fff;
      }
      .nav-active {
        background: rgb(255 255 255 / 0.14);
        color: #fff;
      }
    `,
  ],
})
export class Shell {
  private readonly auth = inject(AuthService);
  private readonly version = toSignal(
    inject(VersionApi)
      .get()
      .pipe(catchError(() => of(null))),
    { initialValue: null },
  );

  protected readonly menuOpen = signal(false);
  protected readonly user = this.auth.user;
  protected readonly navigation = computed(() =>
    NAVIGATION.filter((item) => this.auth.can(item.permission)),
  );
  protected readonly roleLabels = computed(() =>
    this.auth.roles().map((role) => ROLE_LABELS[role]),
  );
  protected readonly backendRevision = computed(() => {
    const revision = this.version()?.revision ?? '';
    return /^[0-9a-f]{7,40}$/.test(revision) ? revision.slice(0, 7) : null; // local builds report "unknown"
  });
  protected readonly initials = computed(() =>
    (this.user()?.displayName ?? '?')
      .split(/\s+/)
      .map((part) => part[0])
      .slice(0, 2)
      .join('')
      .toUpperCase(),
  );

  protected logout(): void {
    void this.auth.logout();
  }
}
