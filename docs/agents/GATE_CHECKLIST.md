# Gate checklist: what only the project owner can do (state: 2026-10-17)

Everything below needs an explicit decision or action by the project owner. Claude Code has prepared the rest. Order matters.

## A. GitHub merges (5 open PRs, all CI-green, all MERGEABLE/CLEAN)
Facts checked: the repository allows merge commits, squash and rebase; "delete branch on merge" is OFF; `main` is not protected; no Actions variables exist;
default Actions token permission is `read` (the build job declares `packages: write` itself).

**Use "Create a merge commit" for every PR. Do NOT squash or rebase-merge:** #27-#29 are stacked on the previous branch; a squash would give `main` a different
commit than the one the next PR was built on, and the retargeted PR would show (and conflict with) the earlier commits again.

| Step | PR | Merge into | After the merge |
|---|---|---|---|
| 1 | #25 (#7 runner pin) | `main` | delete branch |
| 2 | #26 (#8 PKCE, import guard, CI trigger) | `main` | **delete branch** (this retargets #27 to `main`) |
| 3 | #27 (#14/#16 production stack) | `main` (check the base says `main` first) | delete branch (retargets #28) |
| 4 | #28 (#10 `GET /version`) | `main` | delete branch (retargets #29) |
| 5 | #29 (#18 pull-based pipeline) | `main` | delete branch |

- After steps 2-5 wait for the CI run on the retargeted PR (push an update or press "Update branch" if it did not start) before merging it.
- Every merge to `main` runs Test + Build and publishes images (`sha-<commit>`, `latest`). The `prod` tag and the Verify job exist only after step 5.
  The old SSH deploy job still exists until step 5 and skips itself (no `EC2_HOST`).
- Claude Code can execute the merges (`gh pr merge --merge --delete-branch`) once you approve the whole sequence or each step.

## B. Repository settings (after step 5; Claude Code may not change them without your approval)
1. **Branch protection on `main` (Issue #15):** require status check `test`; no required reviews (solo); do not restrict force-push for admins if you want an escape hatch,
   but disallow force-push/deletion for everyone else. Reason: the server agent deploys whatever reaches `main`.
2. **Actions variable `PROD_APP_URL`** = `https://<your app host>` (not a secret). Without it the Verify job only warns "not executed".
3. Check that the GHCR package `prodflow` is **public** (the server pulls anonymously).

## C. AWS / DuckDNS (only you; Claude Code has no AWS access) - details in `docs/aws-deployment.md`
Before the first step ask Syntax/Marcus (Roadmap D-6): allowed instance types, public ports, Elastic IP, budget ($15/month), reset policy.
1. DuckDNS account; create two names, e.g. `app-<x>` and `auth-<x>`; keep the token ready (never in chat/Git/user-data).
2. EC2: Ubuntu 24.04, `t3.small` (measured stack ~0.9 GB; swap is added) or `t3.medium` if budget allows; 20 GB gp3; key pair kept locally.
3. Security group: inbound TCP 80 and 443 from anywhere, TCP 22 only from your IP. Nothing else (not 8180).
4. Elastic IP attached to the instance.
5. SSH in, then run the bootstrap (prompts for the DuckDNS token, generates all other secrets on the server):
   `sudo APP_HOST=<app>.duckdns.org AUTH_HOST=<auth>.duckdns.org IMAGE_TAG=sha-<commit of main after step 5> bash bootstrap-server.sh`
6. Verify from your laptop (Windows PowerShell): `scripts\smoke-auth.ps1 -KeycloakUrl https://<auth host> -RedirectUri https://<app host>/swagger-ui/oauth2-redirect.html`
   with `DEMO_*_PASSWORD` read once from the server (`sudo grep ^DEMO_ /opt/prodflow/repo/deploy/.env`). On the server itself:
   `scripts/demo-run.sh` runs the full workflow (needs the baseline; reset first with `scripts/reset-demo-data.sh`, see below).
7. Add `PRODFLOW_DEMO_RESET=allowed` to the server `deploy/.env` (demo marker for the reset script) - only on the demo server.
8. Gate checks (Roadmap section 5): both certificates valid, Swagger login as planner and purchaser, demo steps 1-5, only 80/443 public, memory measured
   (`docker stats --no-stream`, `free -m`), DNS update procedure known.

## D. Local development stack (optional, needs your approval each time)
- `docker compose up -d` would recreate only the `keycloak` container so it uses the import guard (the guard sees the existing realm and passes).
  Claude Code will not do this without approval. To use the reset locally, add `PRODFLOW_DEMO_RESET=allowed` to your local `.env` (a name only; do not paste secrets).

## E. Smallest next action
Approve step A (merge sequence #25 → #29). Everything else (B, C) depends on it because the server clones `main` and needs an image that contains `/version`.
