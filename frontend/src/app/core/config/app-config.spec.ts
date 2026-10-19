import { vi } from 'vitest';
import { loadAppConfig, parseAppConfig } from './app-config';

const valid = (url: string) => ({ keycloak: { url, realm: 'prodflow', clientId: 'prodflow-web' } });

describe('parseAppConfig', () => {
  it('accepts an https identity provider and removes trailing slashes', () => {
    expect(parseAppConfig(valid('https://auth.example.org/'))).toEqual({
      keycloak: { url: 'https://auth.example.org', realm: 'prodflow', clientId: 'prodflow-web' },
    });
  });

  it('accepts plain http only for localhost development', () => {
    expect(parseAppConfig(valid('http://localhost:8180')).keycloak.url).toBe(
      'http://localhost:8180',
    );
    expect(parseAppConfig(valid('http://127.0.0.1:8180')).keycloak.url).toBe(
      'http://127.0.0.1:8180',
    );
  });

  it('refuses plain http to any other host (credentials would travel unencrypted)', () => {
    expect(() => parseAppConfig(valid('http://auth.example.org'))).toThrow(/https/);
    expect(() => parseAppConfig(valid('http://localhost.evil.example'))).toThrow(/https/);
  });

  it('refuses a missing or incomplete configuration', () => {
    expect(() => parseAppConfig(null)).toThrow(/keycloak/);
    expect(() => parseAppConfig({})).toThrow(/keycloak/);
    expect(() => parseAppConfig({ keycloak: { url: 'https://a.example', realm: 'r' } })).toThrow(
      /Pflicht/,
    );
    expect(() => parseAppConfig(valid('not a url'))).toThrow(/URL/);
  });
});

describe('loadAppConfig', () => {
  it('loads /config.json without using a cached copy', async () => {
    const fetcher = vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      json: async () => valid('https://auth.example.org'),
    });
    const config = await loadAppConfig(fetcher as unknown as typeof fetch);
    expect(fetcher).toHaveBeenCalledWith('/config.json', { cache: 'no-store' });
    expect(config.keycloak.realm).toBe('prodflow');
  });

  it('reports a failed download', async () => {
    const fetcher = vi.fn().mockResolvedValue({ ok: false, status: 404, json: async () => ({}) });
    await expect(loadAppConfig(fetcher as unknown as typeof fetch)).rejects.toThrow(/HTTP 404/);
  });
});
