import { DestroyRef, effect, inject, signal, untracked } from '@angular/core';
import { Observable, Subscription } from 'rxjs';
import { ApiError, toApiError } from '../../core/http/api-error';

/**
 * A tiny, explicit loading state for one backend call: loading -> value | error, with reload().
 * Create it in a field initializer (needs an injection context); the subscription ends with the component.
 *
 * Pass `watch` (a signal read, e.g. () => this.id()) to load again whenever that value changes; the first load then
 * happens as soon as the value is available (route inputs are set after construction).
 */
export interface Loadable<T> {
  readonly value: () => T | undefined;
  readonly loading: () => boolean;
  readonly error: () => ApiError | undefined;
  reload(): void;
}

export function createLoadable<T>(source: () => Observable<T>, watch?: () => unknown): Loadable<T> {
  const value = signal<T | undefined>(undefined);
  const loading = signal(true);
  const error = signal<ApiError | undefined>(undefined);
  let subscription: Subscription | undefined;

  const load = (): void => {
    subscription?.unsubscribe();
    loading.set(true);
    error.set(undefined);
    subscription = source().subscribe({
      next: (result) => {
        value.set(result);
        loading.set(false);
      },
      error: (e: unknown) => {
        error.set(toApiError(e));
        loading.set(false);
      },
    });
  };

  inject(DestroyRef).onDestroy(() => subscription?.unsubscribe());
  if (watch) {
    effect(() => {
      watch();
      untracked(load);
    });
  } else {
    load();
  }
  return { value, loading, error, reload: load };
}
