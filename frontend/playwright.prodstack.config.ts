import { defineConfig, devices } from '@playwright/test';

/**
 * Browser test of the PRODUCTION-LIKE stack (scripts/test-prod-stack.sh starts it and runs this config): Caddy with HTTPS (internal CA),
 * the single image with the SPA, real Keycloak with the production realm file. The hostnames are mapped to the published loopback port
 * inside the browser only (no hosts file, no DNS). It never runs against a real server.
 */
export default defineConfig({
  testDir: 'e2e-prodstack',
  testMatch: '**/*.prodstack.ts',
  timeout: 120_000,
  expect: { timeout: 15_000 },
  workers: 1,
  retries: 0,
  reporter: [['list']],
  use: {
    baseURL: 'https://app.prodflow.test',
    ignoreHTTPSErrors: true, // Caddy's internal CA
    locale: 'de-DE',
    viewport: { width: 1440, height: 900 },
    trace: 'retain-on-failure',
    launchOptions: {
      args: [
        `--host-resolver-rules=MAP app.prodflow.test 127.0.0.1:${process.env['PRODSTACK_HTTPS_PORT'] ?? '18443'}, MAP auth.prodflow.test 127.0.0.1:${process.env['PRODSTACK_HTTPS_PORT'] ?? '18443'}`,
      ],
    },
  },
  projects: [
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'], viewport: { width: 1440, height: 900 } },
    },
  ],
});
