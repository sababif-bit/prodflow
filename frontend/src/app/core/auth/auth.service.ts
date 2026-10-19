import { computed, inject, Injectable, InjectionToken, signal } from '@angular/core';
import Keycloak from 'keycloak-js';
import { KeycloakConfig } from '../config/app-config';
import { allows, knownRoles, Permission, Role } from './permissions';

/** The small part of keycloak-js this application uses (also what unit tests fake). */
export interface KeycloakLike {
  init(options: {
    onLoad: 'login-required' | 'check-sso';
    pkceMethod: 'S256';
    checkLoginIframe: boolean;
  }): Promise<boolean>;
  login(options?: { redirectUri?: string }): Promise<void>;
  logout(options?: { redirectUri?: string }): Promise<void>;
  updateToken(minValiditySeconds?: number): Promise<boolean>;
  token?: string;
  tokenParsed?: {
    preferred_username?: string;
    name?: string;
    email?: string;
    realm_access?: { roles?: string[] };
  };
}

export const KEYCLOAK_FACTORY = new InjectionToken<(config: KeycloakConfig) => KeycloakLike>(
  'KEYCLOAK_FACTORY',
  {
    providedIn: 'root',
    factory: () => (config) =>
      new Keycloak({
        url: config.url,
        realm: config.realm,
        clientId: config.clientId,
      }) as unknown as KeycloakLike,
  },
);

export interface CurrentUser {
  username: string;
  displayName: string;
  email?: string;
  roles: Role[];
}

/**
 * Authorization Code flow with PKCE (S256) against the existing public client "prodflow-web".
 * Tokens live only inside keycloak-js (memory): nothing is written to localStorage/sessionStorage or cookies by this app.
 * The login iframe check is off on purpose: the identity provider is a different site, where third-party cookie rules
 * would silently break it; a full redirect login and refresh-token renewal need no iframe.
 */
@Injectable({ providedIn: 'root' })
export class AuthService {
  private readonly factory = inject(KEYCLOAK_FACTORY);
  private keycloak?: KeycloakLike;
  private readonly userSignal = signal<CurrentUser | null>(null);

  readonly user = this.userSignal.asReadonly();
  readonly roles = computed<Role[]>(() => this.userSignal()?.roles ?? []);
  readonly isAuthenticated = computed(() => this.userSignal() !== null);

  async init(config: KeycloakConfig): Promise<void> {
    const keycloak = this.factory(config);
    this.keycloak = keycloak;
    const authenticated = await keycloak.init({
      onLoad: 'login-required',
      pkceMethod: 'S256',
      checkLoginIframe: false,
    });
    if (!authenticated) {
      await keycloak.login();
      return;
    }
    this.userSignal.set(this.readUser(keycloak));
  }

  /** A valid access token (renewed with the refresh token when it expires within 30 s), or undefined after a redirect to the login. */
  async getToken(): Promise<string | undefined> {
    const keycloak = this.keycloak;
    if (!keycloak) {
      return undefined;
    }
    try {
      await keycloak.updateToken(30);
    } catch {
      await keycloak.login();
      return undefined;
    }
    return keycloak.token;
  }

  can(permission: Permission): boolean {
    return allows(this.roles(), permission);
  }

  async login(): Promise<void> {
    await this.keycloak?.login();
  }

  async logout(): Promise<void> {
    await this.keycloak?.logout({ redirectUri: `${window.location.origin}/` });
  }

  private readUser(keycloak: KeycloakLike): CurrentUser {
    const claims = keycloak.tokenParsed ?? {};
    const username = claims.preferred_username ?? 'unbekannt';
    return {
      username,
      displayName: claims.name?.trim() || username,
      email: claims.email,
      roles: knownRoles(claims.realm_access?.roles),
    };
  }
}
