import { Component, inject } from '@angular/core';
import { RouterOutlet } from '@angular/router';
import { StartupState } from './core/startup-state';
import { StartupError } from './features/system/system-pages';

@Component({
  selector: 'app-root',
  imports: [RouterOutlet, StartupError],
  template: `
    @if (startup.error(); as message) {
      <app-startup-error [message]="message" />
    } @else {
      <router-outlet />
    }
  `,
})
export class App {
  protected readonly startup = inject(StartupState);
}
