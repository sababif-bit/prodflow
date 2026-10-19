# Issue draft (NOT created; creating it is a GitHub write and needs approval — see CLAUDE.md)

Title: `[Backlog #7–#10] Angular frontend served by the Spring Boot image (SPA integration, CSP, deployment verification)`
Labels: none (no `ready-for-agent` without approval). Branch after creation: `feature/<issue-number>-frontend-spa`
(local branch today: `feature/frontend-foundation`).

## What to build
A German Angular + PrimeNG frontend (dashboard, inventory with single-level BOM view, production orders, purchase requests; Keycloak PKCE login) that
is compiled into the existing Spring Boot Docker image, so that UI and API are deployed and rolled back atomically, with runtime configuration from the
backend, CSP/cache headers in Caddy, and a deployment gate that proves the UI, the configuration and the API authorization.

## Acceptance criteria
- [ ] `backend/Dockerfile` builds Angular and the backend into one image; build context is the repository root; the root `.env` is never part of the context
- [ ] SPA routes fall back to `index.html`; every other unlisted path keeps the existing 401/403/404 (deny by default); API RBAC tests unchanged and green
- [ ] `GET /config.json` is derived from the OIDC issuer and never cached; no localhost value ships in the production assets
- [ ] Caddy sends a CSP (scripts `'self'`, connect-src only self + sign-in server, frame-ancestors none) and immutable caching for hashed bundles; tested with a real browser through Caddy
- [ ] `prodflow-web` has the production redirect/web-origin/logout URIs (new realms via the import file, existing realm via `scripts/provision-web-client.ps1`)
- [ ] `deploy.sh` rolls back a release that is healthy but does not serve the SPA/config/401; CI `verify` runs `scripts/verify-deployment.sh`
- [ ] CI runs lint, unit tests and the production build of the frontend
- [ ] The single-level BOM is presented as single-level; multi-level BOM is NOT part of this issue (roadmap)

## Blocked by
None. Live Keycloak change (`docs/frontend-rollout.md`, section 3) and the merge/deploy need explicit approval.
