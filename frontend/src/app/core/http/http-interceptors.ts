import { HttpInterceptorFn } from '@angular/common/http';
import { inject } from '@angular/core';
import { catchError, from, switchMap, throwError } from 'rxjs';
import { AuthService } from '../auth/auth.service';
import { toApiError } from './api-error';

/** The bearer token is attached to calls of OUR API only (relative /api/...). It never goes to another origin. */
export function isApiUrl(url: string): boolean {
  return url === '/api' || url.startsWith('/api/');
}

export const authInterceptor: HttpInterceptorFn = (request, next) => {
  if (!isApiUrl(request.url)) {
    return next(request);
  }
  const auth = inject(AuthService);
  return from(auth.getToken()).pipe(
    switchMap((token) =>
      next(token ? request.clone({ setHeaders: { Authorization: `Bearer ${token}` } }) : request),
    ),
  );
};

let reLoginStarted = false;

/** Maps failures to ApiError; an authenticated user whose token is rejected (401) is sent through the login once. */
export const errorInterceptor: HttpInterceptorFn = (request, next) => {
  const auth = inject(AuthService);
  return next(request).pipe(
    catchError((error) => {
      const apiError = toApiError(error);
      if (isApiUrl(request.url) && apiError.kind === 'unauthenticated' && !reLoginStarted) {
        reLoginStarted = true;
        void auth.login();
      }
      return throwError(() => apiError);
    }),
  );
};

/** For tests: the one-shot guard is module state. */
export function resetReLoginGuard(): void {
  reLoginStarted = false;
}
