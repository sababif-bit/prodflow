import { defineConfig, devices } from '@playwright/test';

/**
 * READ-ONLY smoke test of a DEPLOYED ProdFlow (Plan B, stage S7). Run it by hand after a release, never in CI (it needs demo-account passwords).
 *
 *   PROD_APP_URL            required, e.g. https://prodflow-farhad.duckdns.org (https only; http only for localhost)
 *   PROD_AUTH_URL           optional, asserted to equal the sign-in server that the application announces in /config.json
 *   PRODSMOKE_PLANNER_PASSWORD, PRODSMOKE_PURCHASER_PASSWORD   passwords of the EXISTING demo users planner and purchaser (environment only)
 *
 * There is deliberately no default URL: a run against production must be a conscious choice.
 * No tracing, video or screenshots: a trace would record typed values. The spec performs navigation only and blocks any non-GET request to /api.
 */
function appUrl(): string {
  const raw = process.env['PROD_APP_URL'];
  if (!raw) {
    throw new Error(
      'PROD_APP_URL is not set (see frontend/e2e-production/README.md). There is no default on purpose.',
    );
  }
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    throw new Error('PROD_APP_URL is not a valid URL');
  }
  const local = url.hostname === 'localhost' || url.hostname === '127.0.0.1';
  if (url.protocol !== 'https:' && !(url.protocol === 'http:' && local)) {
    throw new Error('PROD_APP_URL must use https (http is accepted for localhost only)');
  }
  return url.origin;
}

export default defineConfig({
  testDir: 'e2e-production',
  testMatch: '**/*.prod.ts',
  timeout: 120_000,
  expect: { timeout: 20_000 },
  workers: 1,
  retries: 0,
  reporter: [['list']],
  use: {
    baseURL: appUrl(),
    locale: 'de-DE',
    viewport: { width: 1440, height: 900 },
    trace: 'off',
    video: 'off',
    screenshot: 'off',
  },
  projects: [
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'], viewport: { width: 1440, height: 900 } },
    },
  ],
});
