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

## Milestone 5 – pull requests (2026-10-17)
- Pushed 5 branches, opened PRs: #25 (#7, base main), #26 (#8, base main), #27 (#14/#16, base feature/8), #28 (#10, base feature/14), #29 (#18, base feature/10). No merges, no settings changes.
- Ancestry fixes before pushing: `feature/10-version-endpoint` had accidentally carried the #18 agent commit (reset locally, unpushed); stack rebased so each PR shows one logical commit.
- The workflow triggered only for PRs with base `main`, so stacked PRs would have had no CI: one commit in #26 changes `pull_request` to every base.
- CI on all five: test job green (about 40-52 s); verified in the log of #28: 100 tests, 0 failures, on `ubuntu-24.04`. `build`/`deploy`/`verify` are skipped on PRs by design.
- Merge-readiness review: all MERGEABLE/CLEAN. Findings: (1) squash/rebase merges would break the stack -> "Create a merge commit"; (2) "delete branch on merge" is off -> delete each branch after merging
  so GitHub retargets the next PR; (3) `main` unprotected, no Actions variables, default Actions token read-only (the build job declares `packages: write` itself);
  (4) the `prod` tag and Verify job exist only after #29 merges, so the first AWS bootstrap must use an image built from `main` after that merge. Full list: `docs/agents/GATE_CHECKLIST.md`.

## Milestone 6 – #9 demo reset + #19 workflow check (branch `feature/9-demo-reset`, commit `ff98f88`, local only)
- `scripts/reset-demo-data.sh`: single transaction, V100 seed as single source of truth, baseline verified inside the transaction; guards: demo marker, service `db` only, database `prodflow` only,
  one container, schema fingerprint (no Keycloak tables, Flyway 1+100); `--dry-run`, `--yes`.
- `scripts/demo-run.sh` + `scripts/lib/oidc.sh`: the demo workflow with real PKCE tokens (14 checks: shortage 15, one purchase request, planner 403, purchaser approve/receive, auto-release, completion, final stock);
  refuses a consumed baseline (exit 3).
- Tests: `test-reset-demo.sh` 38/38 (disposable PostgreSQL; includes a Keycloak-like database, ambiguous containers, bad seed -> rollback, identical fingerprints after repeated run+reset);
  `test-prod-stack.sh` 55/55 (demo run, refused second run, reset, identical second run, refusal of `keycloak-db` on the live test stack; smoke-auth 38/38 after the library refactor).
- Bug caught by the positive control: the Flyway check used a glob that could not match `,1,100,` (shared comma); every refusal test had passed anyway. Lesson: always keep a "happy path" test next to refusal tests.
- NOT run against the real development database (explicitly forbidden); to use it locally add `PRODFLOW_DEMO_RESET=allowed` to the local `.env` first.

## Milestone 7 – first-deployment readiness (branch `feature/17-first-deployment-readiness`, local only, 2026-10-17)
Audit of bootstrap, preflight, deploy, agent, Compose, Caddy, Keycloak and CI for the first real AWS run (instance stopped, never contacted; compromised DuckDNS token never used).
- **Clean-Ubuntu dry run** (`scripts/test-bootstrap-ubuntu.sh`): real `bootstrap-server.sh` on Ubuntu 24.04 in a disposable box limited like the t3.small (2 GiB RAM + 2 GiB swap, own Docker daemon);
  real Docker/Compose installation, real GHCR image, real stack; stubs only for systemd, swap, the DuckDNS API (fake token) and Let's Encrypt (`tls internal`). **48/48**, also with half the CPU (`BOOT_CPUS=1`, 177 s). Bootstrap duration 113 s.
- **Real defects found and fixed:** (1) the documented Let's Encrypt staging recipe (`tls { ca ... }` on one line) is invalid Caddyfile syntax and would have crashed Caddy -> replaced by `ACME_CA` (tested offline, `scripts/test-caddyfile.sh` 9/9);
  (2) apt on a freshly started instance can hit the dpkg lock held by unattended-upgrades -> `DPkg::Lock::Timeout=300`; (3) the backend image healthcheck (about 130 s) is tight for a cold Spring Boot start on a 2-vCPU burstable instance
  -> Compose override (start period 150 s, 6 retries); (4) `agent.sh` ran `cd` without a failure guard; (5) a skipped Verify job was green with only a warning -> now `if: vars.PROD_APP_URL != ''` (skipped = grey) and the build summary says that a green build means "image published", not "deployed";
  (6) stats sampler listed all containers when the project had none yet (harness only).
- **Memory (t3.small):** peak of all containers together about 0.95 GiB over start, 38 login checks, API calls and a Keycloak restart (Keycloak about 560 MiB, backend about 300 MiB, databases about 75 MiB, Caddy about 15 MiB); the whole 2 GiB box peaked at 1.6 GiB including dockerd and cached image layers,
  no OOM kill, no restart. Limits are now consistent with a 2 GiB host (sum 1.76 GiB: Keycloak heap 384m / limit 768m, `KC_CACHE=local`, PostgreSQL 32 MB buffers / 192m). SerialGC for the backend was measured and rejected (no gain).
  Ubuntu itself needs roughly 0.2-0.3 GiB more on the real instance: t3.small is plausible, the 2 GiB swap file is the safety net, switch to t3.medium if swap is used or OOM appears.
- **Secrets audit:** the whole Git history (all refs) contains no UUID-like tokens, DuckDNS token assignments, AWS/GitHub keys or private keys; the token is read from a hidden prompt, travels to curl via stdin, is written only to `deploy/.env` (600) and was proven absent from bootstrap output,
  stub log, all container environments and the resolved Compose config (with a fake token). The bootstrap now warns when the token arrives via the environment (shell history).
- **Static analysis:** ShellCheck (production scripts clean at warning level), hadolint (info only), actionlint clean, `systemd-analyze verify` clean for the agent units.
- **Deliverables:** `docs/first-deployment-runbook.md` (DE; PowerShell + Ubuntu commands, staging rehearsal, troubleshooting), `docs/presentation/deployment-architektur-de.md` (DE, short explanation), updated `docs/aws-deployment.md`.
- **Final test results on the committed state:** test-bootstrap-ubuntu 48/48, test-prod-stack 51/51, test-preflight 14/14, test-deploy-agent 23/23, test-caddyfile 9/9, `mvn -q verify` 100/100.
- **Not verified (needs the real environment):** Let's Encrypt issuance for the real names, DuckDNS with a new token, the real EC2 instance and its timing, the Verify job with `PROD_APP_URL` set, the `if: vars...` condition on GitHub (actionlint accepts it).

## Current blockers (permission boundaries)
1. **Merging** PRs #25-#29, push/PR for `feature/9-demo-reset`, branch protection and the repository variable `PROD_APP_URL`: need approval.
2. **AWS** (#17): EC2, security group, Elastic IP, DuckDNS account/token and the Syntax sandbox rules (D-6) need the project owner; runbook ready in `docs/aws-deployment.md`.
3. Recreating the dev `keycloak` container (guard activation) needs approval.

## Exact next step
Merge sequence #25 -> #29 (approval needed), then branch protection, `PROD_APP_URL`, and the AWS steps in `docs/agents/GATE_CHECKLIST.md`.
