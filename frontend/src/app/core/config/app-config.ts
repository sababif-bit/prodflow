/** Where the identity provider lives. Loaded at start-up from /config.json so one build runs in every environment. */
export interface KeycloakConfig {
  url: string;
  realm: string;
  clientId: string;
}

export interface AppConfig {
  keycloak: KeycloakConfig;
}

const LOCAL_HOSTS = new Set(['localhost', '127.0.0.1']);

/**
 * Validates the runtime configuration. Credentials are only ever sent to an https identity provider
 * (plain http is accepted for localhost development only), and nothing secret may be part of this file.
 */
export function parseAppConfig(raw: unknown): AppConfig {
  const kc = (raw as { keycloak?: Record<string, unknown> } | null)?.keycloak;
  if (!kc || typeof kc !== 'object') {
    throw new Error('config.json: Abschnitt "keycloak" fehlt');
  }
  const { url, realm, clientId } = kc as Record<string, unknown>;
  if (
    typeof url !== 'string' ||
    typeof realm !== 'string' ||
    typeof clientId !== 'string' ||
    !url ||
    !realm ||
    !clientId
  ) {
    throw new Error('config.json: keycloak.url, keycloak.realm und keycloak.clientId sind Pflicht');
  }
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    throw new Error('config.json: keycloak.url ist keine gültige URL');
  }
  if (
    parsed.protocol !== 'https:' &&
    !(parsed.protocol === 'http:' && LOCAL_HOSTS.has(parsed.hostname))
  ) {
    throw new Error('config.json: keycloak.url muss https verwenden (http nur für localhost)');
  }
  return { keycloak: { url: url.replace(/\/+$/, ''), realm, clientId } };
}

export async function loadAppConfig(fetcher: typeof fetch = fetch): Promise<AppConfig> {
  const response = await fetcher('/config.json', { cache: 'no-store' });
  if (!response.ok) {
    throw new Error(`config.json konnte nicht geladen werden (HTTP ${response.status})`);
  }
  return parseAppConfig(await response.json());
}
