# Issue draft (published as a GitHub issue on 2026-10-20 after approval; see CLAUDE.md for the approval rules)

Title: `[Backlog #7] Angular frontend served by the Spring Boot image (SPA integration, CSP, deployment gate)`
Labels: none (no `ready-for-agent` without approval). Branch: `feature/<issue-number>-frontend-spa`.

## What to build
A German Angular + PrimeNG frontend that fulfils Backlog #7 to #10 (dashboard, inventory with a single-level BOM view, production orders with the material check, purchase requests; Keycloak PKCE login).
It is compiled into the existing Spring Boot Docker image instead of a separate Nginx container (supersedes the historical Nginx assumption of Backlog #7, see ADR #16-#19 in `docs/architecture.md`),
so UI and API are deployed and rolled back atomically. Runtime configuration comes from the backend, Caddy sets CSP/cache headers, and the deployment gate proves the UI, the configuration and the API authorization.

## Acceptance criteria
- [ ] `backend/Dockerfile` builds Angular and the backend into one image; the build context is the repository root; the root `.env` is never part of the context
- [ ] SPA routes fall back to `index.html`; every other unlisted path keeps the existing 401/403/404 (deny by default); the API RBAC tests are unchanged and green
- [ ] `GET /config.json` is derived from the OIDC issuer and never cached; no localhost value ships in the production assets
- [ ] Caddy sends a CSP (scripts `'self'`, connect-src only self + sign-in server, frame-ancestors none) and immutable caching for hashed bundles; tested with a real browser through Caddy
- [ ] `prodflow-web` has the production redirect/web-origin/logout URIs (new realms via the import file, the existing realm via `scripts/provision-web-client.ps1`, additive and idempotent)
- [ ] `deploy.sh` rolls back a release that is healthy but does not serve the SPA, `/config.json` or an API 401; a deliberate rollback to a release without the SPA needs the explicit `DEPLOY_ROLLBACK_TO_BACKEND_ONLY=1`, which skips only the SPA checks
- [ ] CI runs lint, unit tests and the production build of the frontend, plus the deployment-script and Caddyfile tests; the `verify` job runs `scripts/verify-deployment.sh`
- [ ] The single-level BOM is presented as single-level; multi-level BOM is not part of this issue (roadmap)
- [ ] Rollout and rollback are documented (`docs/frontend-rollout.md`, `docs/agents/PLAN_B_ROLLOUT_RUNBOOK.md`)

## Blocked by
None. The live Keycloak change, the merge and the production deployment each need separate explicit approval.
