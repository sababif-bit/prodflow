import { inject } from '@angular/core';
import { CanActivateFn, Router } from '@angular/router';
import { AuthService } from './auth.service';
import { Permission } from './permissions';

/**
 * Route guard: the user must be signed in AND the role must allow the area.
 * Convenience only; the backend enforces the same rules and answers 403 for anything forbidden.
 */
export function requirePermission(permission: Permission): CanActivateFn {
  return () => {
    const auth = inject(AuthService);
    const router = inject(Router);
    if (!auth.isAuthenticated()) {
      return false; // the sign-in redirect is already in progress (login-required)
    }
    return auth.can(permission) ? true : router.createUrlTree(['/keine-berechtigung']);
  };
}
