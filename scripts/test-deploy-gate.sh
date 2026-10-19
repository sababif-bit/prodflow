#!/usr/bin/env bash
# Runs the REAL deploy/deploy.sh against REAL containers (disposable Compose project "prodflow-gatecheck", loopback ports 18098/18453/18183,
# random secrets in this process only) and proves the application gate (verify_app) and the rollback paths with the real Tomcat/busybox:
#   - a release without the SPA is refused by the gate (default) and accepted ONLY with DEPLOY_ROLLBACK_TO_BACKEND_ONLY=1
#   - the current release (SPA) passes the gate; the HTTP 401 detection works against what Tomcat really sends
#   - rolling back with the new script WITHOUT the override fails and restores the new release (documents the reason for the override)
#   - rolling back WITH the override works; the OLD deploy.sh of the production commit also works (checkout-first path)
#   - Caddy is recreated for every release (RELEASE_TAG), so it reads the Caddyfile of the release
# Images: prodflow-backend:$NEW_TAG (default prodcheck: docker build -f backend/Dockerfile --build-arg GIT_SHA=<40 hex> -t prodflow-backend:prodcheck .)
# and prodflow-backend:gate-old, built here from the production commit $OLD_REV (default fb08e68, the backend-only release) when missing.
# Never touches the development project "prodflow", its volumes, ports 8080/8180, any .env file, GHCR or a server.
# Run: scripts/test-deploy-gate.sh      Exit: 0 = all passed, 1 = a check failed, 3 = pre-check failed
set -u
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/.." && pwd)
REPO_N=$(cd "$REPO" && { pwd -W 2>/dev/null || pwd; })   # native path for git.exe/docker.exe
PROJECT=prodflow-gatecheck
NEW_TAG=${NEW_TAG:-prodcheck}; OLD_TAG=gate-old; OLD_REV=${OLD_REV:-fb08e68}
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "PASS  $1"; }; bad() { FAIL=$((FAIL + 1)); echo "FAIL  $1${2:+  ($2)}"; }
check() { if [ "$1" = 0 ]; then ok "$2"; else bad "$2" "${3:-}"; fi; }
secret() { openssl rand -base64 18 | tr -d '\r\n'; }
WORK=$(mktemp -d)
dc() { ( cd "$WORK/repo/deploy" && docker compose --env-file .env -f docker-compose.prod.yml "$@" ); }
cleanup() { [ -d "$WORK/repo/deploy" ] && dc down -v --remove-orphans >/dev/null 2>&1; rm -rf "$WORK"; }
trap cleanup EXIT

command -v docker >/dev/null && command -v openssl >/dev/null && docker version >/dev/null 2>&1 || { echo "pre-check failed: docker/openssl"; exit 3; }
[ -z "$(docker ps -aq --filter "label=com.docker.compose.project=$PROJECT")" ] || { echo "pre-check failed: project $PROJECT already exists"; exit 3; }
docker image inspect "prodflow-backend:$NEW_TAG" >/dev/null 2>&1 || { echo "pre-check failed: image prodflow-backend:$NEW_TAG missing (see header)"; exit 3; }
STACK_BEFORE=$(docker ps -a --filter 'label=com.docker.compose.project=prodflow' --format '{{.ID}}' | sort | tr '\n' ' ')
if ! docker image inspect "prodflow-backend:$OLD_TAG" >/dev/null 2>&1; then
  echo "== building the previous (backend-only) release from commit $OLD_REV"
  full=$(git -C "$REPO_N" rev-parse "$OLD_REV") || { echo "pre-check failed: commit $OLD_REV unknown"; exit 3; }
  mkdir -p "$WORK/old" && git -C "$REPO_N" archive "$OLD_REV" backend | tar -x -C "$WORK/old"
  docker build -q --build-arg "GIT_SHA=$full" -t "prodflow-backend:$OLD_TAG" "$(cd "$WORK/old/backend" && { pwd -W 2>/dev/null || pwd; })" >/dev/null || { echo "pre-check failed: old image build"; exit 3; }
fi

# ---- a copy of the deploy directory (the real scripts and the real compose file), adapted only for isolation ----
mkdir -p "$WORK/repo"; cp -r "$REPO/deploy" "$WORK/repo/deploy"; cp -r "$REPO/keycloak" "$WORK/repo/keycloak"; rm -f "$WORK/repo/deploy/.env"
f="$WORK/repo/deploy/docker-compose.prod.yml"
sed -i "s/^name: prodflow-prod.*/name: $PROJECT/; s#127.0.0.1:8180:8080#127.0.0.1:18183:8080#" "$f"
sed -i 's#^\(    image: \${BACKEND_IMAGE:-ghcr.io/sababif-bit/prodflow}:\${IMAGE_TAG:?image tag (sha-...) to run}\)#\1\n    pull_policy: never#' "$f"
grep -q 'pull_policy: never' "$f" && grep -q "name: $PROJECT" "$f" && grep -q 18183 "$f" || { echo "pre-check failed: could not adapt the compose copy"; exit 3; }
cat >"$WORK/repo/deploy/.env" <<EOF
APP_HOST=app.prodflow.test
AUTH_HOST=auth.prodflow.test
APP_URL=https://app.prodflow.test
AUTH_URL=https://auth.prodflow.test
BACKEND_IMAGE=prodflow-backend
IMAGE_TAG=$OLD_TAG
PUBLISH_BIND=127.0.0.1
HTTP_PUBLISH=18098
HTTPS_PUBLISH=18453
TLS_DIRECTIVE='tls internal'
PRODFLOW_DB_PASSWORD=$(secret)
KEYCLOAK_DB_NAME=keycloak
KEYCLOAK_DB_USER=keycloak
KEYCLOAK_DB_PASSWORD=$(secret)
KC_BOOTSTRAP_ADMIN_USERNAME=gatecheck
KC_BOOTSTRAP_ADMIN_PASSWORD=$(secret)
DEMO_PLANNER_PASSWORD=$(secret)
DEMO_PURCHASER_PASSWORD=$(secret)
DEMO_ADMIN_PASSWORD=$(secret)
EOF
chmod 600 "$WORK/repo/deploy/.env"
git -C "$REPO_N" show "$OLD_REV:deploy/deploy.sh" >"$WORK/repo/deploy/deploy-old.sh"

deploy() { # deploy [VAR=value ...] -- script tag   -> exit code; output in $WORK/out.log
  local envs=(); while [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
  ( cd "$WORK/repo/deploy" && env DEPLOY_SKIP_GIT=1 DEPLOY_TIMEOUT=360 "${envs[@]}" bash "$1" "$2" ) >"$WORK/out.log" 2>&1; echo $?
}
tag_in_env() { sed -n 's/^IMAGE_TAG=//p' "$WORK/repo/deploy/.env"; }
running_rev() { dc exec -T backend wget -qO- http://localhost:8080/version 2>/dev/null | sed -n 's/.*"revision":"\([0-9a-z]*\)".*/\1/p'; }
caddy_release() { docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$(dc ps -q caddy)" 2>/dev/null | sed -n 's/^RELEASE_TAG=//p'; }   # Caddy holds no secrets
full_old=$(git -C "$REPO_N" rev-parse "$OLD_REV")

echo "== A: first start of the backend-only release (no SPA) needs the explicit override"
rc=$(deploy DEPLOY_ROLLBACK_TO_BACKEND_ONLY=1 -- deploy.sh $OLD_TAG)
check $([ "$rc" = 0 ] && echo 0 || echo 1) 'deploy.sh with DEPLOY_ROLLBACK_TO_BACKEND_ONLY=1 accepts the release without SPA' "exit $rc: $(tail -2 "$WORK/out.log" | tr '\n' ' ')"
check $(grep -q 'WARNING DEPLOY_ROLLBACK_TO_BACKEND_ONLY=1' "$WORK/out.log" && echo 0 || echo 1) 'the override printed its warning'
check $([ "$(running_rev)" = "$full_old" ] && echo 0 || echo 1) 'the running backend is the old production revision' "$(running_rev)"
check $([ "$(caddy_release)" = "$OLD_TAG" ] && echo 0 || echo 1) 'Caddy carries RELEASE_TAG of this release' "$(caddy_release)"

echo "== B: the same release without the override is refused by the gate"
rc=$(deploy -- deploy.sh $OLD_TAG)
check $([ "$rc" = 1 ] && grep -q 'GET / does not return the application' "$WORK/out.log" && echo 0 || echo 1) 'default gate: a healthy backend without SPA fails the application check' "exit $rc: $(grep -m1 'deploy:' "$WORK/out.log")"

echo "== C: the current release (with SPA) passes the real gate (real Tomcat status line, real config.json)"
rc=$(deploy -- deploy.sh $NEW_TAG)
check $([ "$rc" = 0 ] && echo 0 || echo 1) 'deploy.sh accepts the release with SPA, config.json and API 401' "exit $rc: $(grep 'deploy:' "$WORK/out.log" | tail -2 | tr '\n' ' ')"
check $([ "$(tag_in_env)" = "$NEW_TAG" ] && echo 0 || echo 1) 'IMAGE_TAG is the new release' "$(tag_in_env)"
check $([ "$(caddy_release)" = "$NEW_TAG" ] && echo 0 || echo 1) 'Caddy was recreated for the new release (reads its Caddyfile)' "$(caddy_release)"
status_line=$(dc exec -T backend wget -S -qO- http://localhost:8080/api/items 2>&1 | grep -m1 'HTTP/' | cat -A | sed 's/^ *//')
echo "      (real status line of an unauthenticated API call inside the container: $status_line)"

echo "== D: rolling back with the NEW script and NO override fails and restores the new release (reason for the override)"
rc=$(deploy -- deploy.sh $OLD_TAG)
check $([ "$rc" = 1 ] && [ "$(tag_in_env)" = "$NEW_TAG" ] && echo 0 || echo 1) 'without the override the rollback target is refused and the new release is restored' "exit $rc, tag $(tag_in_env)"
check $([ -n "$(running_rev)" ] && [ "$(running_rev)" != "$full_old" ] && echo 0 || echo 1) 'the new release is running again after that failed attempt'

echo "== E: deliberate rollback with the override (the documented command)"
rc=$(deploy DEPLOY_ROLLBACK_TO_BACKEND_ONLY=1 -- deploy.sh $OLD_TAG)
check $([ "$rc" = 0 ] && [ "$(tag_in_env)" = "$OLD_TAG" ] && echo 0 || echo 1) 'rollback with the override succeeds and IMAGE_TAG is the old release' "exit $rc, tag $(tag_in_env)"
check $([ "$(running_rev)" = "$full_old" ] && echo 0 || echo 1) 'the old production revision is running' "$(running_rev)"
check $([ "$(caddy_release)" = "$OLD_TAG" ] && echo 0 || echo 1) 'Caddy was recreated for the rollback' "$(caddy_release)"

echo "== F: roll forward again, then G: rollback with the OLD deploy.sh of the production commit (checkout-first path)"
rc=$(deploy -- deploy.sh $NEW_TAG)
check $([ "$rc" = 0 ] && [ "$(tag_in_env)" = "$NEW_TAG" ] && echo 0 || echo 1) 'roll forward after the rollback passes the gate' "exit $rc"
rc=$(deploy -- deploy-old.sh $OLD_TAG)
check $([ "$rc" = 0 ] && [ "$(tag_in_env)" = "$OLD_TAG" ] && [ "$(running_rev)" = "$full_old" ] && echo 0 || echo 1) 'the old script (no application gate) rolls back to the old release' "exit $rc, tag $(tag_in_env)"

echo "== cleanup"
cleanup; trap - EXIT
check $([ -z "$(docker ps -aq --filter "label=com.docker.compose.project=$PROJECT")" ] && echo 0 || echo 1) 'no test containers left'
check $([ -z "$(docker volume ls -q --filter "label=com.docker.compose.project=$PROJECT")" ] && echo 0 || echo 1) 'no test volumes left'
check $([ "$STACK_BEFORE" = "$(docker ps -a --filter 'label=com.docker.compose.project=prodflow' --format '{{.ID}}' | sort | tr '\n' ' ')" ] && echo 0 || echo 1) 'development stack containers unchanged'
echo "test-deploy-gate result: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
