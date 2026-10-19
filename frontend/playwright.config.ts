import { defineConfig, devices } from '@playwright/test';

/**
 * End-to-end tests against the DISPOSABLE stack (frontend/e2e/stack.sh up): real Keycloak sign-in, real Spring Boot API.
 * The Angular dev server is started by this config with its API proxy pointing at the disposable backend (18080),
 * and /config.json is redirected to the disposable Keycloak (18180) by the tests. Production is never contacted.
 * Specs run in file order on one worker because they share the demo data (01 read-only ... 03 workflow ... 04 screenshots).
 */
export default defineConfig({
  testDir: 'e2e/tests',
  testMatch: '**/*.e2e.ts',
  timeout: 90_000,
  expect: { timeout: 10_000 },
  fullyParallel: false,
  workers: 1,
  retries: 0,
  reporter: [['list'], ['html', { open: 'never' }]],
  use: {
    baseURL: 'http://localhost:4200',
    locale: 'de-DE',
    timezoneId: 'Europe/Berlin',
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
    viewport: { width: 1440, height: 900 },
  },
  projects: [
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'], viewport: { width: 1440, height: 900 } },
    },
  ],
  webServer: {
    command: 'npx ng serve --port 4200 --host localhost',
    url: 'http://localhost:4200',
    reuseExistingServer: false,
    timeout: 240_000,
    env: { API_TARGET: 'http://localhost:18080' },
  },
});
