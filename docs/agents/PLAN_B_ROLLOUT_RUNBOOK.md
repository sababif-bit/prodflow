# Plan B runbook: controlled manual first rollout of the frontend (DRAFT, nothing in it has been executed)

Written 2026-10-20, updated after the approved local corrections C1-C3 (section 8). Repository base `fb13489` plus the correction commits (local branch `feature/frontend-foundation`, 7 commits ahead of production).
Authority: read-only analysis. Every stage below needs the approvals listed in section 9. Working document in English (like the other `docs/agents/*.md`);
a German version for `docs/` can follow after approval.

Variables used below (PowerShell on the laptop unless stated otherwise):
```powershell
$app  = 'https://prodflow-farhad.duckdns.org'
$auth = 'https://prodflow-auth-farhad.duckdns.org'
$key  = '<path to the EC2 key>'          # never printed, never pasted into chat
$ip   = '<current EC2 public IP>'        # changes after stop/start without an Elastic IP
```
Baseline measured read-only on 2026-10-20: `GET $app/version` -> `fb08e68ce7956864c9c70f504dbbad90caa718aa` (= `origin/main`, merge of PR #30), `/actuator/health` UP,
`GET /` -> 401 and `/config.json` -> 401 (old backend, no SPA). Production image tag therefore `sha-fb08e68`.

## 0. Verdict
Plan B is executable. With the corrections C1/C2 in the PR (section 8) the procedure is: run the manual deploy under the agent's own lock, pre-position the new `deploy.sh`, and roll back with
`DEPLOY_ROLLBACK_TO_BACKEND_ONLY=1` (or, as a fallback, "checkout first, then the old deploy.sh"). Nothing here was verified on the server; "verified" means read from the repository or reproduced locally
(`scripts/test-deploy-agent.sh` 42/42, `scripts/test-deploy-gate.sh` 18/18 with the real `deploy.sh` and real containers).

## 1. How the hold works (verified by reading `deploy/agent.sh`, `deploy/deploy.sh`, `deploy/prodflow-agent.*`, `deploy/bootstrap-server.sh`)
| Question | Answer |
|---|---|
| Which process checks `/var/lib/prodflow/hold`? | Only `deploy/agent.sh`, started by `prodflow-agent.service` (oneshot, every minute via `prodflow-agent.timer`, `OnBootSec=2min`, `OnUnitActiveSec=1min`). `STATE_DIR` defaults to `/var/lib/prodflow`; the unit sets no override. `deploy.sh` never looks at it. |
| Where in the agent? | After `flock -n` on `agent.lock` and after the `.env` check, **before** `docker pull`. With the hold present the agent logs `hold file present - deployments paused` and exits 0: it does not even pull `:prod`. |
| Does it prevent automatic deployments? | Yes, for every agent run that **starts** after the file exists. It survives reboots (`/var/lib` is persistent; the timer restarts, the file stays). Only root can remove it (directory is root-owned). |
| Can a manual `deploy.sh` run while it exists? | Yes. `deploy.sh` ignores the hold. Hold and manual deploy do not conflict, but see F1. |
| Can an already-running deployment continue after the hold is created? | **Yes.** The check happens once at agent start. An agent run that passed the check keeps going (`deploy.sh` is its child; systemd does not stop it; `TimeoutStartSec=900`). Creating the hold does not interrupt it. Detect with `systemctl is-active prodflow-agent.service` (`activating` = running) and `flock -n /var/lib/prodflow/agent.lock true` (fails while a run is active). |
| What happens when the hold is removed? | At the next timer tick (<= ~70 s) the agent pulls `:prod`, reads its revision label, compares `sha-<7>` with `IMAGE_TAG` in `.env`: equal -> silent no-op; different -> it deploys that image **forward** immediately (also after a manual rollback!). A tag recorded in `/var/lib/prodflow/failed` is skipped until a newer image appears. |

## 2. Conflicts found between hold and manual `deploy.sh`
- **F1 (race): the manual deploy does not take the agent's lock.** The agent holds `flock` on `agent.lock` for its whole run (fd 9 is inherited by `deploy.sh`), but a manual `deploy.sh` does not.
  If an agent run started before the hold was created, both can run at once (two `docker compose up`, two `git checkout`). Mitigation without code change: **run the manual deploy under the same lock**:
  `sudo flock -n -E 99 /var/lib/prodflow/agent.lock bash deploy.sh <tag>` (exit 99 = lock busy = an agent run is active, nothing was done). This also protects the manual run if the hold file were removed by mistake while it runs.
- **F2: manual failures leave no marker.** `/var/lib/prodflow/failed` is written only by the agent. A failed manual deploy is not remembered: after the hold is removed the agent would retry the `prod` image once. Check `ls /var/lib/prodflow` before removing the hold.
- **F3 (important, handled by C2): the new `deploy.sh` refuses a rollback to a release without the SPA unless told otherwise.** `verify_app` runs on every `deploy.sh <tag>`, also for a rollback target. Rolling back with the **new** script to `sha-fb08e68` makes the gate fail
  (old backend: `GET /` -> 401, no `<app-root`), and the script's failure branch then restores the **new** release and exits 1. Reproduced with real containers (`test-deploy-gate.sh`, step D). Correct rollback: **`DEPLOY_ROLLBACK_TO_BACKEND_ONLY=1`** (R1), which skips only the SPA-shell and `/config.json` checks and prints a warning; health and the API 401 check stay in force (tested). Fallback without the switch: check out the old commit first, then run the old script (R1b, also tested for real). The script's own automatic rollback (failure branch) is unaffected: it does not run `verify_app`.
- **F4: the gate checks the backend only.** `wait_healthy`/`verify_app` do not look at Caddy. A Caddy that fails to start or crash-loops after the recreate (e.g. a Caddyfile problem) leaves the backend healthy and the site unreachable, and `deploy.sh` exits 0.
  Caught only by the external verification in S7.
- **F5: CI `verify` window.** If `vars.PROD_APP_URL` is set, the `verify` job starts after `build` and polls up to 15 minutes for the new revision, then runs `verify-deployment.sh`. If the manual deploy finishes later, the job is red (cosmetic; "Re-run failed jobs" after the deploy fixes it). Whether the variable is set could not be read (`gh` is not installed here): check GitHub -> Settings -> Secrets and variables -> Actions -> Variables.

## 3. The old `deploy.sh` problem and the mitigation (task 6)
The server runs the `deploy.sh` of commit `fb08e68`: it waits for `healthy` only (no `verify_app`), and `agent.sh` would call it. Mitigation without any unapproved live change (**Variant A, recommended**):
1. The agent stays paused (hold) and no automatic run is possible.
2. As the first step of the approved deploy, move the server checkout to the release commit **before** running the script: `sudo git -C /opt/prodflow/repo checkout --detach <merge-sha>`. This is the same checkout the script performs as its first action; nothing restarts yet. The on-disk `deploy.sh` is now the new one.
3. Run the new `deploy.sh` under the lock: it checks out (no-op), sets the tag, pulls, starts, waits for healthy **and** runs `verify_app`; on any failure it restores tag and commit `fb08e68` and restarts the old stack.
4. Independently verify externally (S7) because of F4.
Variant B (fallback if A is not wanted): run the old script and rely only on S7; a broken SPA is then not rolled back automatically, only by hand (R1). Not recommended.
**C1 (done):** `verify_app` matches `HTTP/<ver> 401` followed by a non-digit or end, so every status-line shape works (with/without reason phrase, trailing space). Measured with the real backend image: Tomcat sends `HTTP/1.1 401 ` (trailing space), so the old match would have worked, but the new one no longer depends on it. Tested with 8 status-line variants (fakes) and against the real container (`test-deploy-gate.sh`, step C).

## 4. Sequence with STOP/GO gates
Stages S1..S8; "G" = gate. Do not continue past a gate without an explicit GO from you.

### S1 Baseline (read-only)
Laptop (PowerShell):
```powershell
curl.exe -sS "$app/version"; curl.exe -sS "$app/actuator/health"
git -C C:\Projects\prodflow ls-remote origin refs/heads/main        # expect fb08e68ce795...
```
EC2 (`ssh -i $key ubuntu@$ip`; never `cat .env`, never `docker compose config`, never plain `docker inspect`: they print secrets):
```bash
cd /opt/prodflow/repo
sudo git rev-parse HEAD ; sudo git status --short                    # expect fb08e68..., clean
sudo sed -n 's/^IMAGE_TAG=//p;s/^APP_URL=//p;s/^AUTH_URL=//p' deploy/.env   # tag and the two public URLs only
cd deploy && sudo docker compose --env-file .env -f docker-compose.prod.yml ps
sudo docker image ls ghcr.io/sababif-bit/prodflow --digests
sudo docker manifest inspect ghcr.io/sababif-bit/prodflow:sha-fb08e68 >/dev/null && echo "rollback image pullable"
systemctl is-active prodflow-agent.timer prodflow-agent.service ; systemctl list-timers prodflow-agent.timer --no-pager
ls -la /var/lib/prodflow ; sudo journalctl -u prodflow-agent --since "-30min" --no-pager | tail -5
free -m
```
Save the output to a local note (no secrets in it). **G1 GO** only if: revision = `fb08e68`, `.env` tag = `sha-fb08e68`, repo clean, rollback image pullable, no `failed` file, service `inactive`.

### S2 Pause and prove it
EC2:
```bash
systemctl is-active prodflow-agent.service            # expect inactive; if "activating": a run is active -> wait, repeat
sudo mkdir -p /var/lib/prodflow && sudo touch /var/lib/prodflow/hold && ls -l /var/lib/prodflow/hold
# wait up to 90 s for the next timer run, then:
sudo journalctl -u prodflow-agent --since "-3min" --no-pager | tail -5    # expect "hold file present - deployments paused"
systemctl is-active prodflow-agent.service                                 # inactive
sudo flock -n /var/lib/prodflow/agent.lock true && echo "lock free (no run active)"
sudo sed -n 's/^IMAGE_TAG=//p' /opt/prodflow/repo/deploy/.env              # still sha-fb08e68
```
Optional belt and braces (decision D2): `sudo systemctl stop prodflow-agent.timer` (restore later with `sudo systemctl start prodflow-agent.timer`). Not needed with hold + flock; it adds a second thing to restore.
**G2 GO** only if the journal shows the hold message, the service is inactive, the lock is free and the tag is unchanged. Undo: `sudo rm /var/lib/prodflow/hold` (only with approval; no deployment follows while `prod` still equals the running tag).

### S3 GitHub (needs approval; `gh` is not installed: use the web UI or approve installing it)
1. Create the issue from `docs/agents/ISSUE_DRAFT_frontend.md` (no labels). 2. Optionally rename the local branch `git branch -m feature/<n>-frontend-spa`. 3. `git push -u origin <branch>`. 4. Open the PR into `main` (body: summary, test evidence, "merge only while the production hold is active", rollback pointer, `🤖 Generated with [Claude Code](https://claude.com/claude-code)`).
5. CI on the PR runs `test`, `frontend`, `ops` (`build` and `verify` run only on `main`). **G3 GO** only if all three are green and you have reviewed the diff (note: commit `265f6a8` is mislabeled, it only deletes two files). **No merge in this stage.**

### S4 Keycloak: dry run -> apply (needs approval for the apply)
Laptop, window 1 (leave open; local port 18280 because the dev Keycloak owns 127.0.0.1:8180 on this machine):
```powershell
ssh -i $key -N -L 18280:127.0.0.1:8180 ubuntu@$ip
```
Window 2 (credentials are read into process memory and never displayed; `.Trim()` removes the CR that Windows ssh adds):
```powershell
$env:KC_BOOTSTRAP_ADMIN_USERNAME = (ssh -i $key ubuntu@$ip "sudo sed -n 's/^KC_BOOTSTRAP_ADMIN_USERNAME=//p' /opt/prodflow/repo/deploy/.env").Trim()
$env:KC_BOOTSTRAP_ADMIN_PASSWORD = (ssh -i $key ubuntu@$ip "sudo sed -n 's/^KC_BOOTSTRAP_ADMIN_PASSWORD=//p' /opt/prodflow/repo/deploy/.env").Trim()
cd C:\Projects\prodflow
# baseline (read-only): the production redirect URI is rejected before the change
$cc='E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM'
curl.exe -s -o NUL -w "%{http_code}`n" "$auth/realms/prodflow/protocol/openid-connect/auth?client_id=prodflow-web&response_type=code&scope=openid&code_challenge_method=S256&code_challenge=$cc&state=x&redirect_uri=$([uri]::EscapeDataString("$app/"))"   # expect 400
.\scripts\provision-web-client.ps1 -KeycloakUrl http://localhost:18280 -AppUrl $app -DryRun
```
Expected dry run: `before` shows `redirectUris: http://localhost:4200/*`, `webOrigins: http://localhost:4200`, logout list `(follows the redirect URIs)` (default `+`); `after` shows only additions of `https://prodflow-farhad.duckdns.org/*` / `https://prodflow-farhad.duckdns.org`; `DRY RUN: nothing was written.`, exit 0.
Failure conditions: exit 3 (admin login/tunnel/URL; nothing changed), exit 4 (client not the expected public PKCE client; nothing changed), "before" containing unexpected extra entries, any removal in "after". **G4 GO** only for a clean dry run whose "after" is a pure addition.
Apply (after your explicit approval), then prove idempotence and effect, then clean up:
```powershell
.\scripts\provision-web-client.ps1 -KeycloakUrl http://localhost:18280 -AppUrl $app          # expect DONE, exit 0
.\scripts\provision-web-client.ps1 -KeycloakUrl http://localhost:18280 -AppUrl $app          # expect "Already up to date"
curl.exe -s -o NUL -w "%{http_code}`n" "<same authorization URL as above>"                  # expect 200 (login page) instead of 400
Remove-Item Env:KC_BOOTSTRAP_ADMIN_PASSWORD, Env:KC_BOOTSTRAP_ADMIN_USERNAME ; # Ctrl+C in window 1
```
Recovery: exit 2 = unexpected error, re-run is safe (single PUT, then verified read). Rollback: admin console through the tunnel (`http://localhost:18280`, realm prodflow -> Clients -> prodflow-web) and remove the added values; leaving them is harmless (the old app does not use them) and requires no action when the app is rolled back.

### S5 Merge (needs approval) and image check
Merge with "Create a merge commit" (precedent: PRs #25-#32). With the hold active nothing deploys; the CI `build` job pushes `sha-<7>`, `latest`, `prod`. Then:
```powershell
$sha = (git -C C:\Projects\prodflow ls-remote origin refs/heads/main).Split("`t")[0]; $tag = "sha-$($sha.Substring(0,7))"; $tag
```
EC2:
```bash
TAG=sha-XXXXXXX                                   # from above
sudo bash /opt/prodflow/repo/deploy/preflight.sh image ghcr.io/sababif-bit/prodflow:$TAG    # "image ... exists"
sudo docker pull -q ghcr.io/sababif-bit/prodflow:$TAG >/dev/null
sudo docker inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' ghcr.io/sababif-bit/prodflow:$TAG   # must equal the merge commit SHA
```
**G5 GO** only if the build job is green, the image exists and the label equals the merge SHA. If `PROD_APP_URL` is set, start S6 within 15 minutes of the build finishing (F5).

### S6 Manual deploy (Variant A)
EC2:
```bash
cd /opt/prodflow/repo
sudo git status --short                              # expect empty
sudo git fetch --quiet origin
sudo git checkout --quiet --detach "${TAG#sha-}"     # new files on disk; nothing restarts yet
grep -c verify_app deploy/deploy.sh                  # expect >= 1 (new script)
bash -n deploy/deploy.sh && echo syntax-ok
cd deploy
sudo flock -n -E 99 /var/lib/prodflow/agent.lock bash deploy.sh "$TAG" 2>&1 | tee ~/deploy-$TAG.log
echo "exit: ${PIPESTATUS[0]}"
```
Expected: `deploy: sha-fb08e68 -> sha-XXXXXXX`, compose pull/recreate of `backend` and `caddy` (Keycloak and the databases are not recreated), `deploy: sha-XXXXXXX is healthy and serves the application`, exit 0, after ~2-4 min; the site is briefly unavailable (backend and Caddy restart, certificates stay in the `caddy_data` volume).
Exit codes: 99 = lock busy (an agent run is active: wait, re-check S2, retry; nothing changed), 2 = bad tag/.env missing, 1 = failed **and rolled back** (read the output; verify with R0).
**G6 GO** only for exit 0. For exit 1: run R0, then STOP.

### S7 External verification and browser checks
Three vantage points (all read-only):
```bash
# EC2 (jq is installed by bootstrap):
cd /opt/prodflow/repo && bash scripts/verify-deployment.sh --app-url https://prodflow-farhad.duckdns.org --expect-revision "$(sudo git rev-parse HEAD)" --expect-auth-url https://prodflow-auth-farhad.duckdns.org
sudo bash -c 'set -a; . /opt/prodflow/repo/deploy/.env; set +a; /opt/prodflow/repo/scripts/smoke-auth.sh --auth-url "$AUTH_URL" --app-url "$APP_URL"'     # roles/API unchanged: 0 FAIL
```
```powershell
# laptop (Git Bash has no jq: use a container):
docker run --rm -v "C:\Projects\prodflow\scripts:/s:ro" alpine:3 sh -c "apk add -q --no-cache bash curl jq && bash /s/verify-deployment.sh --app-url $app --expect-revision $sha --expect-auth-url $auth"
```
GitHub: the CI `verify` job (if the variable is set; re-run it after the deploy if it timed out). Expected: `0 FAIL` everywhere.
Browser (laptop, normal window, DevTools open, read-only actions only; no orders created, nothing approved or received, no demo reset):
1. `$app` -> redirected to the Keycloak login (no `invalid redirect_uri` page). 2. Log in as planner (password read on the server only if needed). 3. Open Übersicht, Fertigungsaufträge, Bestellanforderungen, Bestand; reload on `/bestand`. 4. Console: no "Content Security Policy" errors; Network: `main-*.js` with `cache-control: public, max-age=31536000, immutable`. 5. "Abmelden" -> back at the login form. 6. Log in as purchaser: approve/receive buttons visible (do not click); planner: not visible. 7. `$app/swagger-ui.html` still opens.
**G7 GO** only if every check passes. Any FAIL, login error, blocking CSP violation, 5xx or Caddy problem -> rollback R1.

### S8 Soak and restore automatic deployment (needs approval)
Wait the agreed soak time (suggest >= 30 min), check `free -m`, `sudo docker stats --no-stream`, `sudo journalctl -u prodflow-agent --since "-1h"`. Before removing the hold:
```bash
sudo docker pull -q ghcr.io/sababif-bit/prodflow:prod >/dev/null
sudo docker inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' ghcr.io/sababif-bit/prodflow:prod   # must equal: sudo git -C /opt/prodflow/repo rev-parse HEAD
sudo sed -n 's/^IMAGE_TAG=//p' /opt/prodflow/repo/deploy/.env ; ls /var/lib/prodflow         # tag matches; no "failed" file
```
Equal -> `sudo rm /var/lib/prodflow/hold` (and `sudo systemctl start prodflow-agent.timer` if it was stopped); after ~2 minutes `systemctl status prodflow-agent.service` shows a clean run and the tag is unchanged. Not equal (a newer main commit exists): deploy it first with S6 (or decide to let the agent do it, which from now on has the application gate).

## 5. Recovery procedures
| Failure | What you see | Action |
|---|---|---|
| Keycloak dry run fails | exit 3/4/2 | Nothing was changed. Exit 3: tunnel/credentials/URL; exit 4: STOP and inspect the client in the admin console. Do not proceed to S5 until a dry run is clean. |
| Keycloak apply partly done | error text, exit 2 | Re-run (idempotent) or inspect in the admin console; additive values are harmless. |
| Image missing / pull fails | `preflight: FAILED`, or `dc pull` error in S6 | S5 gate stops before S6. In S6 `deploy.sh` rolls back (the old containers keep running). Cause: build not finished, wrong tag, package not public. Retry later. |
| Backend unhealthy | `did NOT become healthy ... rolling back`, exit 1 | Automatic rollback to `sha-fb08e68`. Run R0, collect `sudo docker compose --env-file .env -f docker-compose.prod.yml logs --tail 100 backend caddy` (logs contain no secrets, still read before pasting). STOP. |
| SPA/config/401 gate fails (`verify_app`) | message `deploy: GET / does not return...` etc., exit 1 | Automatic rollback. If the message is the 401 check, compare the real status line inside the container (`wget -S`). STOP. |
| Gate passes but external verify fails | S7 FAIL | R1. Typical causes: Caddy not running (F4: `docker compose ps`, `logs caddy`), CSP/header mismatch, wrong `/config.json`. |
| Authentication fails in the browser | Keycloak error page or login loop | Check `curl $app/config.json` (https, realm prodflow), the Keycloak client values (S4), CSP `connect-src`, console. If not fixed within the agreed time -> R1 (Keycloak needs no rollback). |
| Lock busy | `flock` exit 99 | An agent run is active: `systemctl is-active prodflow-agent.service`; wait for it; re-verify S2; retry. |

### R0 Is the old release really running again? (read-only)
```bash
sudo git -C /opt/prodflow/repo rev-parse HEAD ; sudo sed -n 's/^IMAGE_TAG=//p' /opt/prodflow/repo/deploy/.env     # fb08e68..., sha-fb08e68
curl -fsS https://prodflow-farhad.duckdns.org/version ; curl -fsS https://prodflow-farhad.duckdns.org/actuator/health
```
### R1 Manual rollback to the previous release `sha-fb08e68` (works while the hold exists)
```bash
cd /opt/prodflow/repo/deploy
sudo env DEPLOY_ROLLBACK_TO_BACKEND_ONLY=1 flock -n -E 99 /var/lib/prodflow/agent.lock bash deploy.sh sha-fb08e68
# expect: "deploy: WARNING DEPLOY_ROLLBACK_TO_BACKEND_ONLY=1 ..." then "deploy: sha-fb08e68 is healthy and serves the application", exit 0
```
The script checks out `fb08e68` (old compose and Caddyfile), sets the tag, pulls (the image is a tagged GHCR image, still pullable; Docker usually still has it locally), recreates `backend` and `caddy`, waits for healthy and checks the API 401. Exit 99 = an agent run is active (nothing changed). Exit 1 = even the rollback failed its gate: read the output, STOP.
Then R0. Keep the hold in place until the cause is understood. (If `git checkout` is refused because of local changes, STOP and inspect `sudo git status`; do not use `reset --hard` or `clean`.)

### R1b Fallback without the switch: old script
```bash
cd /opt/prodflow/repo
sudo git checkout --quiet --detach fb08e68                 # old compose, Caddyfile AND old deploy.sh (no application gate)
cd deploy && sudo flock -n -E 99 /var/lib/prodflow/agent.lock bash deploy.sh sha-fb08e68
```

## 6. Avoiding an accidental deployment (task 8)
- The hold exists **before** the push and stays until S8; verified in G2 by the journal line, not just by `ls`.
- The workflow has no deploy job: a merge only builds and pushes `sha-<7>`, `latest`, `prod`; only the agent (paused) deploys.
- The manual deploy runs under the agent's lock, so an agent run cannot start during it even if the hold file vanished.
- Never remove the hold as a "cleanup". Removal is S8 only, after the equality check; it needs `sudo`, so it cannot happen by accident from the `ubuntu` user.
- A further merge to `main` while paused only moves `prod`; it is deployed when the hold is removed (S8 check catches this).
- Do not run `bootstrap-server.sh` again and do not delete `/var/lib/prodflow` (it also holds `agent.lock`; a new lock file would not exclude a run that holds the old one).
- A reboot is safe: the timer restarts, the hold persists.

## 7. Security, credentials, irreversible steps, assumptions
- **Secrets:** `deploy/.env` holds all production secrets. Only `sed -n 's/^NAME=//p'` for non-secret names; never `cat`, `docker compose config` or plain `docker inspect` (demo and admin passwords appear in container environments). The Keycloak admin password is read into process memory with `ssh ... sed` (not echoed), used by the script, then removed from the environment. Do not paste verbose terminal output into chat without reading it.
- **Tunnel:** Keycloak admin stays on the server loopback; the tunnel is local-only; close it after S4.
- **Irreversible/hard to reverse:** merge to `main` (reverting means a new PR), the moved GHCR pointers `prod`/`latest` (sha tags stay, pointers can only be moved by CI), Keycloak additions (reversible by hand), the brief downtime. **No database migration** is in this release (no change under `db/migration`, none in `application.yml`), so an app rollback is data-safe.
- **Assumptions to confirm:** (1) the bootstrap admin credentials still work against the production master realm and the admin API works through a tunnel on another local port (the dry run proves both without writing); (2) `PROD_APP_URL` set or not (F5); (3) branch protection on `main` unknown (also unverified in `CLAUDE.md`); (4) GHCR package is public (the agent relies on it); (5) hairpin access from the server to its own public URL works (otherwise use the laptop/CI vantage point); (6) Tomcat's 401 status line (C1).
- **Residual risk:** Chromium is the only browser tested; real Let's Encrypt/HSTS behavior and load on the `t3.small` are production-only observations.

## 8. Corrections (approved 2026-10-20, implemented locally, in the PR once approved; they change `deploy/deploy.sh`, so they ship before the first rollout)
- **C1 done** HTTP 401 detection robust (see section 3); tests in `scripts/test-deploy-agent.sh` (status-line variants) and the real-container proof in `scripts/test-deploy-gate.sh`.
- **C2 done** `DEPLOY_ROLLBACK_TO_BACKEND_ONLY=1` (exact value 1 only) skips ONLY the SPA-shell and `/config.json` checks, prints a warning; the health gate and the API 401 check stay in force (tests: override does not disable the 401 check, the health gate, or accept a backend that answers nothing; `true` does not activate it). It must never be set for a forward release.
- **C3 done** docs corrected: tunnel port 18280 (`docs/first-deployment-runbook.md`, `docs/frontend-rollout.md`), manual deploy under the agent lock, rollback with the switch (`docs/first-deployment-runbook.md`, `docs/aws-deployment.md`, `docs/architecture.md`, `docs/frontend-rollout.md`), this runbook.
- Optional, not required for Plan B: make `deploy.sh` take `agent.lock` itself and refuse while the hold exists unless `FORCE=1` (removes F1 by design).

## 9. Approvals needed from you
1. **A1** Execute S1+S2 on EC2 (S1 read-only; S2 creates the hold file) and the SSH access it needs.
2. **A2** C1/C2/C3 code and doc corrections (local commits), plus a local real-container proof of `verify_app` (disposable containers only).
3. **A3** GitHub writes: create the issue, push the branch, open the PR, and (separately) merge with a merge commit; install `gh` or use the web UI.
4. **A4** Live Keycloak: the dry run (read-only; token request + GETs) and, separately, the additive apply.
5. **A5** The manual deploy (S6) including the short downtime window, and the rollback authority (R1) if G7 fails.
6. **A6** Restoring automatic deployment (S8) and the soak time.
7. Decisions: D1 Variant A (recommended) or B; D2 also stop the timer (optional); D3 deploy window relative to the CI `verify` job; D4 whether to read-only browser-test with planner/purchaser (passwords stay on the server).
