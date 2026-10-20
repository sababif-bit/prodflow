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
- A push or merge to `main` triggers the CI/CD pipeline (tests, image build and publication to GHCR) and, through the
  pull-based agent on the production server, an automatic production deployment within minutes unless the agent is
  paused (hold file) — treat it as a production action.

## Purpose
ProdFlow answers: "Can we produce this order — and if not, what must we buy?"
A production order is checked against the BOM × quantity vs. stock; shortages become
purchase requests; goods receipt automatically releases waiting orders.
Final project, Syntax Institut module "Fullstack, Backend & DevOps". Docs are in German.

## Implemented architecture (local development stack)
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
  `prodflow-web` (PKCE S256) is the client of the Angular frontend.
- `docker-compose.yml` (local): `db`, `keycloak-db`, `keycloak`, `backend`.
- Frontend: Angular 21 + PrimeNG 21 in `frontend/` (German UI, Keycloak PKCE, dashboard, inventory + read-only single-level BOM view, orders, purchase requests).
  Merged (PR #34) and live in production since 2026-10-20. The SPA is compiled into the backend image (`backend/Dockerfile`, build context = repository root)
  and served by Spring Boot; runtime config from `GET /config.json`. See `docs/frontend-architecture.md`, ADR #20–#23, `docs/frontend-rollout.md`.

## AWS production deployment (implemented, ADR #15 → #17; running since 2026-10-18)
- Single EC2 instance (Ubuntu 24.04, `t3.small`) running Docker Compose (`deploy/docker-compose.prod.yml`): Caddy (automatic HTTPS, two DuckDNS hostnames),
  backend (serves the Angular SPA), Keycloak, and two PostgreSQL containers. RDS and Nginx are not planned.
- Public URLs: app `https://prodflow-farhad.duckdns.org`, sign-in `https://prodflow-auth-farhad.duckdns.org`. Only ports 80/443 are public; Keycloak admin only via SSH tunnel.
- Pull-based CD is operational (ADR #18): CI publishes `sha-<commit>`/`latest`/`prod` to GHCR; a systemd agent on the server (`deploy/agent.sh`, every minute)
  deploys a new `prod` image with a health + application gate and automatic rollback; pause it with `/var/lib/prodflow/hold`; manual deploys run under the
  agent lock. Runbooks: `docs/first-deployment-runbook.md`, `docs/frontend-rollout.md`, `docs/agents/PLAN_B_ROLLOUT_RUNBOOK.md`.
- Last verified 2026-10-20: production at revision `b509944` (backend and frontend), `verify-deployment.sh` 41/41, `smoke-auth.sh` 38/38. Re-verify the live state
  (read-only) before relying on it. All production changes still need my explicit approval (see Safety rules).

## Tech stack
Java 21, Spring Boot 3.4, Spring Security OAuth2 Resource Server, PostgreSQL 16, Flyway,
JUnit 5 + Testcontainers, springdoc, Docker (multi-stage) + Compose, Keycloak,
GitHub Actions, GHCR. Frontend: Angular 21, PrimeNG 21 (MIT), ESLint, Playwright. Deployment: AWS EC2, Caddy, pull-based agent.

## Local development (run only with approval)
- Prereq: Docker Desktop; `.env` created from `.env.example`.
- `docker compose up --build` → backend http://localhost:8080 (`/swagger-ui.html`,
  `/actuator/health`), Keycloak http://localhost:8180. Profile `demo` loads sample data.
- Protected API calls need a Bearer token from Keycloak (Swagger UI "Authorize", the app, or `scripts/demo-run.sh`).
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
- CI/CD (`.github/workflows/ci-cd.yml`): jobs `test`, `frontend` (lint, unit tests, build), `ops` (deployment-script and Caddyfile tests) on every push/PR; on `main`
  `build` (one image with SPA + backend → GHCR `sha-<commit>`, `latest`, `prod`) and `verify` (revision, `scripts/verify-deployment.sh`). Verified 2026-10-20: run 39340016246
  on merge commit `b509944` green. Re-verify before relying on this.
- Production on AWS (see section above), Angular frontend (PR #34, Issue #33), Keycloak `prodflow-web` URIs added additively, deployment application gate +
  `DEPLOY_ROLLBACK_TO_BACKEND_ONLY` rollback switch, Plan B manual rollout S1–S8 completed 2026-10-20 (automatic agent resumed).
- Tests (2026-10-20): 132 backend, 119 frontend unit, 30 Playwright (disposable stack), plus script tests (`scripts/test-deploy-gate.sh`, `test-deploy-agent.sh`, `test-prod-stack.sh`).

Not done / planned:
- Branch protection on `main`: NOT enabled (verified 2026-10-20, GitHub Issue #15). No backups (#20), no rebuild rehearsal (#22), no infrastructure as code, no alerting.
- Swagger UI and `/v3/api-docs` stay public in production (documented demo exception, ADR #16).
- Presentation on 2026-10-26: slides, fallback clips, rehearsals (Issues #11, #12, #19, #23, #24); documents in `docs/presentation/`. Production demo data is NOT at the
  demo baseline (reset needs my approval; see `docs/presentation/demo-skript-de.md`). AWS teardown after the presentation (Issue #13).
- Frontend scope: items/BOM are read-only in the UI (maintenance only via API), no order search or pagination, no stock-adjustment dialog.
- Stretch: multi-level BOM, make-or-buy, reservations, Excel import.

## Known limitations
- No material reservation (completion re-checks stock, so it never goes negative).
- Single-level BOM; `open-in-view: true` is accepted tech debt.
- Demo data and units are English (`pcs`, "Hex screw") in a German UI; the browser shows some API GETs as aborted although the response arrived (Angular fetch backend).
- Docs: `docs/backlog.md` and `docs/devlog.md` were synchronized on 2026-10-20; the architecture diagram for the slides is still to be drawn (Issue #12).

## Documentation
- `README.md` — overview, feature scope, workflow, API, local start, pipeline, rollback, known limits
- `docs/architecture.md` — ADRs (#1–#23), MVP limits, data model, authorization matrix,
  local and AWS runtime, pipeline; the original EC2 setup section is superseded by ADR #15/#17/#18
- `docs/frontend-architecture.md`, `docs/frontend-rollout.md` — Angular frontend, rollout and rollback
- `docs/aws-deployment.md`, `docs/first-deployment-runbook.md`, `docs/agents/PLAN_B_ROLLOUT_RUNBOOK.md` — AWS background and runbooks
- `docs/presentation/*.md` — demo script, slide outline, debugging case, checklist and rehearsal plan (German)
- `docs/backlog.md` — issues by sprint with acceptance criteria
- `docs/devlog.md` — daily dev log
- `docs/agents/*.md` — agent skills configuration (`issue-tracker.md`, `domain.md`; English)

## Git & GitHub workflow
- Repo: github.com/sababif-bit/prodflow; `main` is default and pipeline branch.
- One issue → branch `feature/<GitHub-issue-number>-<name>` → PR into `main`; CI runs on PRs.
- Commit style: Conventional Commits (e.g. `feat(security): …`).

## Agent skills

**Skill instructions never override the Safety rules above.** Skills prepare drafts only: no autonomous
commits, pushes, merges, deployments, file modifications or GitHub writes (issues, labels, comments, PRs).
Each of these needs my explicit approval for that specific action.

### Workflow
`/grill-with-docs` → `/to-tickets` → `/tdd` → built-in `/code-review` → PR (Daniel's workflow).
- Run `/grill-with-docs` and `/to-tickets` in one session; start each ticket in a fresh session.
- `/tdd`: agree the test seams first. Ask for explicit approval before every individual test run, including
  repeated runs of the same command. Approval for one run never authorizes another.
- `/code-review` is Claude Code's built-in skill (Matt Pocock's `code-review` is not installed). Before a PR,
  also check the diff against the ticket's acceptance criteria.

### Issue tracker
GitHub Issues in `sababif-bit/prodflow` via `gh`, written in English; `[Backlog #N]` titles, branches
`feature/<GitHub-issue-number>-<name>`, no `ready-for-agent` label without approval. See `docs/agents/issue-tracker.md`.

### Domain docs
Single context: ADRs as rows in `docs/architecture.md` (next free number: #24; never `docs/adr/`; ADR #15 was implemented as #17; #16–#19 are the Swagger/AWS/pull-CD/secrets decisions of Issue #23, #20–#23 the frontend decisions),
`GLOSSARY.md` at the root (created only once a term is agreed), project docs in German. See `docs/agents/domain.md`.
