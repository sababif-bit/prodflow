import { TestBed } from '@angular/core/testing';
import { vi } from 'vitest';
import { AuthService, KEYCLOAK_FACTORY, KeycloakLike } from './auth.service';

const CONFIG = { url: 'https://auth.example.org', realm: 'prodflow', clientId: 'prodflow-web' };

function fakeKeycloak(overrides: Partial<KeycloakLike> = {}): KeycloakLike {
  return {
    init: vi.fn().mockResolvedValue(true),
    login: vi.fn().mockResolvedValue(undefined),
    logout: vi.fn().mockResolvedValue(undefined),
    updateToken: vi.fn().mockResolvedValue(false),
    token: 'access-token',
    tokenParsed: {
      preferred_username: 'planner',
      name: 'Demo Planner',
      realm_access: { roles: ['PLANNER', 'offline_access'] },
    },
    ...overrides,
  };
}

function serviceWith(keycloak: KeycloakLike): AuthService {
  TestBed.configureTestingModule({
    providers: [{ provide: KEYCLOAK_FACTORY, useValue: () => keycloak }],
  });
  return TestBed.inject(AuthService);
}

describe('AuthService', () => {
  it('signs in with Authorization Code + PKCE S256, login-required and without the login iframe', async () => {
    const keycloak = fakeKeycloak();
    await serviceWith(keycloak).init(CONFIG);
    expect(keycloak.init).toHaveBeenCalledWith({
      onLoad: 'login-required',
      pkceMethod: 'S256',
      checkLoginIframe: false,
    });
  });

  it('exposes the user and only the known application roles', async () => {
    const auth = serviceWith(fakeKeycloak());
    await auth.init(CONFIG);
    expect(auth.isAuthenticated()).toBe(true);
    expect(auth.user()).toEqual({
      username: 'planner',
      displayName: 'Demo Planner',
      email: undefined,
      roles: ['PLANNER'],
    });
    expect(auth.can('order.create')).toBe(true);
    expect(auth.can('purchase.approve')).toBe(false);
  });

  it('falls back to the username when the token has no name', async () => {
    const auth = serviceWith(
      fakeKeycloak({
        tokenParsed: { preferred_username: 'purchaser', realm_access: { roles: ['PURCHASER'] } },
      }),
    );
    await auth.init(CONFIG);
    expect(auth.user()?.displayName).toBe('purchaser');
  });

  it('redirects to the login when Keycloak reports "not authenticated" and stays signed out', async () => {
    const keycloak = fakeKeycloak({ init: vi.fn().mockResolvedValue(false) });
    const auth = serviceWith(keycloak);
    await auth.init(CONFIG);
    expect(keycloak.login).toHaveBeenCalled();
    expect(auth.isAuthenticated()).toBe(false);
  });

  it('renews the token when it expires within 30 seconds and returns the current one', async () => {
    const keycloak = fakeKeycloak();
    const auth = serviceWith(keycloak);
    await auth.init(CONFIG);
    expect(await auth.getToken()).toBe('access-token');
    expect(keycloak.updateToken).toHaveBeenCalledWith(30);
  });

  it('sends the user through the login again when the token cannot be renewed', async () => {
    const keycloak = fakeKeycloak({
      updateToken: vi.fn().mockRejectedValue(new Error('refresh token expired')),
    });
    const auth = serviceWith(keycloak);
    await auth.init(CONFIG);
    expect(await auth.getToken()).toBeUndefined();
    expect(keycloak.login).toHaveBeenCalled();
  });

  it('gives no token before sign-in', async () => {
    expect(await serviceWith(fakeKeycloak()).getToken()).toBeUndefined();
  });

  it('logs out and returns to the application root', async () => {
    const keycloak = fakeKeycloak();
    const auth = serviceWith(keycloak);
    await auth.init(CONFIG);
    await auth.logout();
    expect(keycloak.logout).toHaveBeenCalledWith({ redirectUri: `${window.location.origin}/` });
  });
});
