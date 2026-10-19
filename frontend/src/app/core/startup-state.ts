import { Injectable, signal } from '@angular/core';

/** Set when the application cannot start (configuration or identity provider unavailable); the root component then shows a clear message. */
@Injectable({ providedIn: 'root' })
export class StartupState {
  private readonly errorSignal = signal<string | null>(null);
  readonly error = this.errorSignal.asReadonly();

  fail(message: string): void {
    this.errorSignal.set(message);
  }
}
