import { Component, input } from '@angular/core';
import { RouterLink } from '@angular/router';
import { Button } from 'primeng/button';

@Component({
  selector: 'app-not-found-page',
  imports: [RouterLink],
  template: `
    <main
      class="mx-auto flex min-h-screen max-w-lg flex-col items-center justify-center gap-3 p-6 text-center"
    >
      <i class="pi pi-compass text-4xl text-surface-400"></i>
      <h1 class="m-0 text-2xl">Seite nicht gefunden</h1>
      <p class="m-0 text-surface-500">Diese Adresse gibt es in ProdFlow nicht.</p>
      <a routerLink="/uebersicht">Zur Übersicht</a>
    </main>
  `,
})
export class NotFoundPage {}

@Component({
  selector: 'app-forbidden-page',
  imports: [RouterLink],
  template: `
    <div class="mx-auto flex max-w-lg flex-col items-center gap-3 py-16 text-center" role="alert">
      <i class="pi pi-lock text-4xl text-surface-400"></i>
      <h1 class="m-0 text-2xl">Keine Berechtigung</h1>
      <p class="m-0 text-surface-500">Ihre Rolle darf diesen Bereich nicht öffnen.</p>
      <a routerLink="/uebersicht">Zur Übersicht</a>
    </div>
  `,
})
export class ForbiddenPage {}

/** Shown instead of the application when the configuration or the sign-in service is unavailable. */
@Component({
  selector: 'app-startup-error',
  imports: [Button],
  template: `
    <main
      class="mx-auto flex min-h-screen max-w-lg flex-col items-center justify-center gap-3 p-6 text-center"
      role="alert"
    >
      <i class="pi pi-exclamation-circle text-4xl" style="color: var(--pf-danger)"></i>
      <h1 class="m-0 text-2xl">ProdFlow kann nicht starten</h1>
      <p class="m-0 text-surface-500">
        Die Anmeldung oder die Konfiguration ist nicht erreichbar. Bitte später erneut versuchen.
      </p>
      <p class="m-0 text-sm text-surface-400">Technische Meldung: {{ message() }}</p>
      <p-button label="Neu laden" icon="pi pi-refresh" (onClick)="reload()" />
    </main>
  `,
})
export class StartupError {
  readonly message = input.required<string>();

  protected reload(): void {
    window.location.reload();
  }
}
