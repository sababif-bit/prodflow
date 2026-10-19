import { expect, Page } from '@playwright/test';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

export type TestRole = 'planner' | 'purchaser' | 'admin';

/** Passwords of the disposable stack (random, in the git-ignored e2e/.stack.env). Never printed. */
function stackEnv(): Record<string, string> {
  const file = join(__dirname, '.stack.env');
  const env: Record<string, string> = {};
  for (const line of readFileSync(file, 'utf8').split(/\r?\n/)) {
    const m = /^([A-Z0-9_]+)=(.*)$/.exec(line.trim());
    if (m) env[m[1]] = m[2];
  }
  return env;
}

const PASSWORD_VARIABLE: Record<TestRole, string> = {
  planner: 'E2E_PLANNER_PASSWORD',
  purchaser: 'E2E_PURCHASER_PASSWORD',
  admin: 'E2E_ADMIN_PASSWORD',
};

export const DISPOSABLE_KEYCLOAK = 'http://localhost:18180';

/** Real sign-in through the Keycloak login form (Authorization Code + PKCE), then waits for the application shell. */
export async function signIn(page: Page, role: TestRole): Promise<void> {
  await page.goto('/');
  await page.locator('#username').fill(role);
  await page.locator('#password').fill(stackEnv()[PASSWORD_VARIABLE[role]]);
  await page.locator('#kc-login').click();
  // the application shell is up (the navigation itself is a closed drawer, invisible, on a phone)
  await expect(page.getByRole('main')).toBeVisible({ timeout: 30_000 });
}

export async function openNav(page: Page, label: string): Promise<void> {
  await page
    .getByRole('navigation', { name: 'Hauptnavigation' })
    .getByRole('link', { name: label })
    .click();
}
