# Autonomous execution log (ProdFlow)

Working log of the autonomous phase that started on 2026-10-16. Facts only: what was done, why, how it was verified, what is open.
Secrets are never recorded here. Limits: no push/merge/GitHub writes/AWS resources/restart of the running dev stack without asking.

## Milestone 1 – Issue #8 closed out locally
- **Done:** Swagger PKCE login (`prodflow-swagger`), demo users, fail-fast `keycloak-import-guard` (Option A), compose wiring, tests and docs.
- **Commit:** `79e8514` on `feature/8-swagger-pkce-login`. Issue #7 (`ubuntu-24.04`) is a separate commit `e199b5e` on `feature/7-pin-ci-runner` (from `main`).
- **Verified:** `mvn -q verify` 97/97; `test-realm-import.ps1 -Scope All` 23/23; `test-realm-catchup.ps1` 43/43; `test-import-guard.ps1` 72/72;
  `test-compose-guard.ps1` 24/24 against the real `docker-compose.yml`; manual Swagger login and role checks by the project owner.
- **Review:** Opus security review of the guard (no blocker; fixes applied: connection retry, control-character check, case-insensitive username check).
- **Not done / risks:** the running dev stack uses the guard only after its next `docker compose up -d` (not executed: needs permission to recreate `keycloak`).
  `provision-demo-realm.ps1` still reports a corrupt credential as "present".

## Milestone 2 – production stack, #14 + #16 (branch `feature/14-production-stack`, commit `fc8450e`)
- **Done:** `deploy/docker-compose.prod.yml` (Caddy, backend, Keycloak `start`, two PostgreSQL, import guard; `${VAR:?}` everywhere; memory limits),
  `deploy/Caddyfile` (two hostnames, Keycloak path allowlist), `deploy/.env.example`, `deploy/deploy.sh`, `deploy/bootstrap-server.sh`,
  `scripts/duckdns-update.sh`, `scripts/smoke-auth.sh` (Linux login check), `scripts/test-prod-stack.sh`, `docs/aws-deployment.md` (runbook, not executed).
- **Verified (run 8):** `test-prod-stack.sh` 48 PASS / 0 FAIL: missing variables stop Compose, a weak demo password blocks Keycloak, HTTPS via Caddy internal CA,
  smoke-auth.sh 38/38 (PKCE login, refresh, API 401/200/403/404 for planner/purchaser/admin, placeholder password rejected), path allowlist incl. `..`, `%2e%2e`, `..%2f`
  tricks, only Caddy and the loopback admin port published, restart keeps realm and passwords, no secret in logs, cleanup, dev stack untouched.
- **Memory (informational):** Keycloak about 490 MB, backend about 285-305 MB, databases about 85 MB, Caddy about 16 MB (about 0.9 GB after the full test) -> `t3.small` plausible; decide on the instance.
- **Decisions:** two hostnames + full URLs from `.env`; admin console only via SSH tunnel (`127.0.0.1:8180`, `KC_HOSTNAME_ADMIN`); Swagger public as documented demo exception (D-8);
  Linux/CI client in bash (D-2); verification inside the Docker network because the Windows host cannot resolve `*.test`.
- **Debugging notes (presentation candidates):** (1) Windows `openssl` ends lines with CRLF -> generated passwords carried a trailing CR that containers silently dropped, database logins failed;
  (2) two test runs overlapped on the same project name/volumes; (3) scripted edits that silently did not apply (always grep after an edit).

## Milestone 3 – #10 version endpoint (branch `feature/10-version-endpoint`, commit `cd8b2ed`)
- `GET /version` (public, only `{"revision": "<commit>"}`), Dockerfile `ARG GIT_SHA` -> `APP_REVISION` + OCI label. Decision D-7: separate endpoint, `/actuator/info` stays ADMIN-only.
- `mvn -q verify`: 100 tests, 0 failures (3 new). Bug found and fixed: a second top-level `prodflow:` key in `application.yml` broke 72 context tests (DuplicateKeyException).

## Milestone 4 – #18 pull-based pipeline (branch `feature/18-pull-based-cicd`)
- `deploy/agent.sh` + systemd timer (every minute, no inbound SSH): pulls GHCR tag `prod`, reads the commit label, calls `deploy.sh sha-<commit>`; health gate + automatic rollback;
  failed tags are remembered; a `hold` file pauses the agent; both scripts run entirely inside `main()` because the checkout replaces them while they run.
- CI: `GIT_SHA` build arg, `prod` pointer, `concurrency`, new `verify` job (public `/version` must equal the commit and `/actuator/health` UP within 15 min; warning "not executed" if
  repository variable `PROD_APP_URL` is unset), SSH deploy job removed (history keeps it), least privilege (`packages: write` only on build, `persist-credentials: false`).
- `scripts/test-deploy-agent.sh`: 23 PASS (no-op, deploy, rollback, failed-tag memory, hold, registry/input errors, scripts replaced mid-run, failing `compose up`/`pull` -> rollback;
  the last tests fail against the previous `deploy.sh`: mutation-checked).
- **Opus security review (read-only):** one blocker found and fixed (with `set -e` a failing `compose up` skipped the rollback and left the bad release configured);
  also fixed: CI token scope, `/bin/bash` in the unit and executable bits in Git, Caddy strips `Forwarded`/`X-Forwarded-Prefix|Port`, log rotation, `no-new-privileges`, Let's Encrypt staging note.
- **Known residual risks:** the agent runs as root and trusts `main` (branch protection not yet enabled, Issue #15); `sha-` tags are mutable/short (digest pinning optional);
  realm brute-force lock (5 failures) could lock a demo account during the presentation (admin can unlock via tunnel; consider raising `failureFactor`);
  bootstrap admin variables stay visible in `docker inspect`; the `..;` path variant is untested against Keycloak (check with `curl --path-as-is` after go-live);
  `mem_limit` values sum to about 2 GB (swap is added by the bootstrap).

## Current blockers (permission boundaries)
1. **Push/PR/merge** of the local branches (#7, #8, #14, #10, #18) and the repository variable `PROD_APP_URL`: GitHub writes need approval.
2. **AWS** (#17): EC2, security group, Elastic IP, DuckDNS account/token and the Syntax sandbox rules (D-6) need the project owner; runbook ready in `docs/aws-deployment.md`.
3. Recreating the dev `keycloak` container (guard activation) needs approval.

## Exact next step
Finish run 9 of `test-prod-stack.sh` after the review fixes and commit; then ask ONE approval question: push the branches and open PRs (order #7, #8, #14+#16, #10, #18) so that CI runs.
