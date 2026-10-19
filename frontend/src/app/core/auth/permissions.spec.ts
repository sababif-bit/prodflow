import { allows, knownRoles, Permission, Role } from './permissions';

/**
 * The expected table is written out literally from backend/src/main/java/de/prodflow/security/SecurityConfig.java
 * (and docs/architecture.md, "Berechtigungsmatrix"); it is NOT derived from PERMISSION_ROLES, so a drift on either side fails here.
 *
 *   GET items/orders/purchase-requests ........ ADMIN, PLANNER, PURCHASER
 *   POST /api/items/{id}/stock ................ ADMIN
 *   POST orders, check-material, complete ..... ADMIN, PLANNER
 *   POST purchase-requests approve, receive ... ADMIN, PURCHASER
 */
const EXPECTED: Record<Permission, Record<Role, boolean>> = {
  'item.read': { ADMIN: true, PLANNER: true, PURCHASER: true },
  'item.adjustStock': { ADMIN: true, PLANNER: false, PURCHASER: false },
  'order.read': { ADMIN: true, PLANNER: true, PURCHASER: true },
  'order.create': { ADMIN: true, PLANNER: true, PURCHASER: false },
  'order.checkMaterial': { ADMIN: true, PLANNER: true, PURCHASER: false },
  'order.complete': { ADMIN: true, PLANNER: true, PURCHASER: false },
  'purchase.read': { ADMIN: true, PLANNER: true, PURCHASER: true },
  'purchase.approve': { ADMIN: true, PLANNER: false, PURCHASER: true },
  'purchase.receive': { ADMIN: true, PLANNER: false, PURCHASER: true },
};

describe('permissions (mirror of the backend authorization matrix)', () => {
  for (const permission of Object.keys(EXPECTED) as Permission[]) {
    for (const role of ['ADMIN', 'PLANNER', 'PURCHASER'] as Role[]) {
      it(`${role} ${EXPECTED[permission][role] ? 'may' : 'may NOT'} ${permission}`, () => {
        expect(allows([role], permission)).toBe(EXPECTED[permission][role]);
      });
    }
  }

  it('the separation of duties holds: a planner can never approve or receive', () => {
    expect(allows(['PLANNER'], 'purchase.approve')).toBe(false);
    expect(allows(['PLANNER'], 'purchase.receive')).toBe(false);
  });

  it('a user without any application role may do nothing', () => {
    for (const permission of Object.keys(EXPECTED) as Permission[]) {
      expect(allows([], permission)).toBe(false);
    }
  });

  it('several roles add up', () => {
    expect(allows(['PLANNER', 'PURCHASER'], 'purchase.approve')).toBe(true);
    expect(allows(['PLANNER', 'PURCHASER'], 'order.create')).toBe(true);
  });
});

describe('knownRoles', () => {
  it('keeps only the exact application role names (like KeycloakRoleConverter in the backend)', () => {
    expect(
      knownRoles(['offline_access', 'PLANNER', 'uma_authorization', 'planner', 'Admin', 'ADMIN']),
    ).toEqual(['PLANNER', 'ADMIN']);
  });

  it('handles a missing claim', () => {
    expect(knownRoles(undefined)).toEqual([]);
  });
});
