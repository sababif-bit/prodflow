/**
 * Role model of the UI. It MIRRORS the authorization matrix of the backend
 * (backend/src/main/java/de/prodflow/security/SecurityConfig.java, tested there by AuthorizationMatrixTest).
 *
 * The UI uses it only to show or hide actions. It is NOT a security boundary: the backend decides, and a forbidden call
 * still ends in 403, which the UI handles (see core/http/api-error.ts).
 */
export type Role = 'ADMIN' | 'PLANNER' | 'PURCHASER';

export const ROLES: readonly Role[] = ['ADMIN', 'PLANNER', 'PURCHASER'];

export type Permission =
  | 'item.read'
  | 'item.adjustStock'
  | 'order.read'
  | 'order.create'
  | 'order.checkMaterial'
  | 'order.complete'
  | 'purchase.read'
  | 'purchase.approve'
  | 'purchase.receive';

const EVERYONE: readonly Role[] = ['ADMIN', 'PLANNER', 'PURCHASER'];
const PLANNING: readonly Role[] = ['ADMIN', 'PLANNER'];
const PURCHASING: readonly Role[] = ['ADMIN', 'PURCHASER'];

export const PERMISSION_ROLES: Readonly<Record<Permission, readonly Role[]>> = {
  'item.read': EVERYONE,
  'item.adjustStock': ['ADMIN'],
  'order.read': EVERYONE,
  'order.create': PLANNING,
  'order.checkMaterial': PLANNING,
  'order.complete': PLANNING,
  'purchase.read': EVERYONE,
  'purchase.approve': PURCHASING,
  'purchase.receive': PURCHASING,
};

export function isRole(value: string): value is Role {
  return (ROLES as readonly string[]).includes(value);
}

/** Only the known application roles are kept (exact, case-sensitive), like KeycloakRoleConverter in the backend. */
export function knownRoles(claimRoles: readonly string[] | undefined): Role[] {
  return (claimRoles ?? []).filter(isRole);
}

export function allows(roles: readonly Role[], permission: Permission): boolean {
  const granted = PERMISSION_ROLES[permission];
  return roles.some((role) => granted.includes(role));
}

export const ROLE_LABELS: Readonly<Record<Role, string>> = {
  ADMIN: 'Administrator',
  PLANNER: 'Planer',
  PURCHASER: 'Einkäufer',
};
