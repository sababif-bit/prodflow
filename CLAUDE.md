# CLAUDE.md – ProdFlow

## Safety rules (mandatory)
- Default to read-only. Without my explicit approval for the specific action, do NOT:
  modify/create/delete files, commit, push, merge, open/close PRs, switch branches,
  run builds or tests, start/stop/restart containers or Compose services, trigger
  deployments, or create/change AWS or other cloud resources.
  Approval for one action does not carry over to the next.
- Never display, copy, log, or commit secrets. Do not read or output `.env`, server
  `.env` files, `*.pem`, keys, tokens, or credential values; redact values when showing
  config. Tracked files get placeholders only (`.env.example`).
- A push to `main` triggers the CI/CD pipeline (incl. the deploy job) — treat it as a
  production action.

## Purpose
ProdFlow answers: "Can we produce this order — and if not, what must we buy?"
A production order is checked against the BOM × quantity vs. stock; shortages become
purchase requests; goods receipt automatically releases waiting orders.
Final project, Syntax Institut module "Fullstack, Backend & DevOps". Docs are in German.

## Current implemented architecture (local)
- Monolith Spring Boot backend in `backend/`, packages under `de.prodflow`:
  `item`, `bom`, `order`, `purchase`, `common` (RFC 7807 `ProblemDetail`), `security`.
- PostgreSQL 16, schema owned by Flyway (`db/migration`); Hibernate `ddl-auto: validate`.
  Schema changes only via a new migration; never edit an applied one.
- Model: `item` (MATERIAL|PRODUCT, `@Version`), self-referencing `bom_line` (single level
  used), `production_order` (CREATED→WAITING_MATERIAL→RELEASED→DONE),
  `purchase_request` (OPEN→APPROVED→RECEIVED). Material check is idempotent.
- Security: OAuth2 resource server validating Keycloak JWTs (JWK signature, issuer,
  audience `prodflow-api`). Realm roles ADMIN, PLANNER, PURCHASER; deny-by-default matrix
  in `security/SecurityConfig.java`; planners cannot approve/receive purchase requests.
  Public: `/actuator/health`, Swagger UI, `/v3/api-docs`.
- Keycloak realm `prodflow` imported from `keycloak/prodflow-realm.json`; public client
  `prodflow-web` (PKCE S256) prepared for a future frontend.
- `docker-compose.yml` (local): `db`, `keycloak-db`, `keycloak`, `backend`.
- No frontend yet.

## Proposed AWS deployment architecture (NOT implemented, not final)
- Single EC2 instance running Docker Compose: PostgreSQL, Keycloak, backend, and
  Caddy as reverse proxy with automatic HTTPS.
- RDS and Nginx are mentioned in older docs but are NOT final decisions.
- Existing `deploy/docker-compose.prod.yml` contains only the backend (port 80) and
  predates this proposal.

## Tech stack
Java 21, Spring Boot 3.4, Spring Security OAuth2 Resource Server, PostgreSQL 16, Flyway,
JUnit 5 + Testcontainers, springdoc, Docker (multi-stage) + Compose, Keycloak,
GitHub Actions, GHCR. Planned: Angular + PrimeNG frontend, AWS EC2, Caddy.

## Local development (run only with approval)
- Prereq: Docker Desktop; `.env` created from `.env.example`.
- `docker compose up --build` → backend http://localhost:8080 (`/swagger-ui.html`,
  `/actuator/health`), Keycloak http://localhost:8180. Profile `demo` loads sample data.
- Protected API calls need a Bearer token from Keycloak (README curl demo lacks auth).
- Tests: `cd backend && mvn verify` (Docker needed for Testcontainers). Key tests:
  `ProductionWorkflowTest`, `ApiSmokeTest`, `security/AuthorizationMatrixTest`,
  `JwtValidationTest`, `KeycloakRoleConverterTest`.
- OIDC env vars: `OIDC_ISSUER_URI`, `OIDC_JWK_SET_URI`, `OIDC_AUDIENCE` (fail closed → 401).

## Status
Implemented:
- Backlog #1–#4: skeleton, data model + demo data, material check/purchase requests,
  goods receipt/order completion — with tests.
- OAuth2 resource server + role-based access (PR #2); local Keycloak setup (PR #4).
- API: items (GET/POST/PUT, POST `/{id}/stock`), BOM (GET/POST/DELETE),
  production orders (GET/POST, check-material, complete), purchase requests
  (GET, approve, receive).
- CI/CD workflow: test on push/PR; on `main` build + push to GHCR (`sha-<commit>`, `latest`).
  Verified 2026-10-15: latest runs green; image `sha-c1eca31` present in GHCR (public).
  Re-verify before relying on this.

Not done / planned:
- AWS EC2 deployment: NOT completed (deploy job skips its steps without `EC2_HOST`).
- Branch protection on `main`: unverified.
- Production Keycloak/OIDC config, HTTPS (Caddy), Swagger off in production.
- Frontend (#7–#10), docs/diagram and demo prep (#12–#13).
- Stretch: multi-level BOM, make-or-buy, reservations, Excel import.

## Known limitations
- No material reservation (completion re-checks stock, so it never goes negative).
- Single-level BOM; `open-in-view: true` is accepted tech debt.
- Docs drift: README still lacks auth (curl demo without token), `PUT /api/items/{id}`,
  and mentions RDS/Nginx; backlog #12 diagram still assumes Nginx → RDS.

## Documentation
- `README.md` — overview, workflow, API, local start, pipeline, rollback
- `docs/architecture.md` — ADRs (#1–#15), MVP limits, data model, authorization matrix,
  local vs. proposed AWS runtime, original EC2 setup (partly superseded by ADR #15)
- `docs/backlog.md` — issues by sprint with acceptance criteria
- `docs/devlog.md` — daily dev log

## Git & GitHub workflow
- Repo: github.com/sababif-bit/prodflow; `main` is default and pipeline branch.
- One issue → branch `feature/<nr>-<name>` → PR into `main`; CI runs on PRs.
- Commit style: Conventional Commits (e.g. `feat(security): …`).
