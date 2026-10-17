#!/usr/bin/env bash
# Disposable end-to-end test of the PRODUCTION stack (deploy/docker-compose.prod.yml, Issues #14/#16) on this machine.
#
# Starts the stack as its own Compose project (prodflow-prodcheck: own containers/volumes/network, published ports only on
# 127.0.0.1:18443/18080/18181), with random secrets that exist only in this process' environment. Verifies:
#   - missing required variables stop Compose (${VAR:?}); a bad demo password makes the import guard refuse Keycloak's start
#   - HTTPS through Caddy (internal CA, hostnames app.prodflow.test / auth.prodflow.test), issuer = public URL
#   - real Authorization Code + PKCE logins, refresh, API 401/200/403 with real tokens (scripts/smoke-auth.sh, run in the network)
#   - Keycloak path allowlist: admin console, admin API, master realm, metrics, encoded/dot-segment tricks are NOT public
#   - only the intended ports are published; admin interface only on 127.0.0.1; /actuator/info not public
#   - restart keeps the realm; memory use per container; no secret in logs
# Never touches the development project "prodflow", its volumes, localhost:8180/8080 or any .env file.
# Run (Git Bash or Linux):  scripts/test-prod-stack.sh      Exit: 0 = all passed, 1 = a check failed, 3 = pre-check failed
set -u
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'   # Git Bash on Windows must not rewrite container paths

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
DEPLOY="$REPO/deploy"
PROJECT=prodflow-prodcheck
HTTPS_PORT=18443; HTTP_PORT=18080; ADMIN_PORT=18181
APP=https://app.prodflow.test; AUTH=https://auth.prodflow.test
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL  $1${2:+  ($2)}"; }
check() { if [ "$1" = 0 ]; then ok "$2"; else bad "$2" "${3:-}"; fi; }

secret() { openssl rand -base64 18 | tr -d '\r\n'; }   # Windows openssl ends lines with CRLF
WORK=$(mktemp -d)
HERE_NATIVE=$(cd "$HERE" && { pwd -W 2>/dev/null || pwd; })   # host path as the Docker daemon sees it (Git Bash on Windows: C:/...)
DEPLOY_NATIVE=$(cd "$DEPLOY" && { pwd -W 2>/dev/null || pwd; })
export COMPOSE_DISABLE_ENV_FILE=1                              # never read a .env file: all values come from this process
dc() { docker compose -p "$PROJECT" -f "$DEPLOY_NATIVE/docker-compose.prod.yml" -f "$DEPLOY_NATIVE/docker-compose.local-test.yml" "$@"; }
NET="${PROJECT}_default"

cleanup() {
  [ -n "${SAMPLER:-}" ] && kill "$SAMPLER" >/dev/null 2>&1
  dc down -v --remove-orphans >/dev/null 2>&1
  rm -rf "$WORK"
  unset PRODFLOW_DB_PASSWORD KEYCLOAK_DB_PASSWORD KC_BOOTSTRAP_ADMIN_PASSWORD DEMO_PLANNER_PASSWORD DEMO_PURCHASER_PASSWORD DEMO_ADMIN_PASSWORD
}
trap cleanup EXIT

# ---- pre-checks ----
[ ! -e "$DEPLOY/.env" ] || { echo "pre-check failed: $DEPLOY/.env exists (the test must not run next to a real server .env)"; exit 3; }
command -v docker >/dev/null && command -v openssl >/dev/null || { echo "pre-check failed: docker/openssl missing"; exit 3; }
docker version >/dev/null 2>&1 || { echo "pre-check failed: Docker not available"; exit 3; }
[ -z "$(docker ps -aq --filter "label=com.docker.compose.project=$PROJECT")" ] || { echo "pre-check failed: project $PROJECT already exists"; exit 3; }
docker image inspect prodflow-backend:latest >/dev/null 2>&1 || { echo "pre-check failed: local image prodflow-backend:latest missing (docker compose build backend)"; exit 3; }
STACK_BEFORE=$(docker ps -a --filter 'label=com.docker.compose.project=prodflow' --format '{{.ID}}' | sort | tr '\n' ' ')

# ---- environment (names only are exported; values are random and never printed) ----
export APP_HOST=app.prodflow.test AUTH_HOST=auth.prodflow.test APP_URL=$APP AUTH_URL=$AUTH
export TLS_DIRECTIVE='tls internal' PUBLISH_BIND=127.0.0.1 HTTP_PUBLISH=$HTTP_PORT HTTPS_PUBLISH=$HTTPS_PORT TEST_ADMIN_PUBLISH=$ADMIN_PORT
export BACKEND_IMAGE=prodflow-backend IMAGE_TAG=latest
export KEYCLOAK_DB_NAME=keycloak KEYCLOAK_DB_USER=keycloak KC_BOOTSTRAP_ADMIN_USERNAME=prodcheck
export PRODFLOW_DB_PASSWORD=$(secret) KEYCLOAK_DB_PASSWORD=$(secret) KC_BOOTSTRAP_ADMIN_PASSWORD=$(secret)
export DEMO_PLANNER_PASSWORD=$(secret) DEMO_PURCHASER_PASSWORD=$(secret) DEMO_ADMIN_PASSWORD=$(secret)

echo "== configuration"
dc config --quiet 2>/dev/null; check $? 'docker compose config is valid with all variables set'
( unset DEMO_PLANNER_PASSWORD; dc config --quiet >/dev/null 2>&1 ); check $([ $? -ne 0 ] && echo 0 || echo 1) 'a missing DEMO_PLANNER_PASSWORD stops Compose (${VAR:?})'
( unset AUTH_URL; dc config --quiet >/dev/null 2>&1 ); check $([ $? -ne 0 ] && echo 0 || echo 1) 'a missing AUTH_URL stops Compose (${VAR:?})'
( unset IMAGE_TAG; dc config --quiet >/dev/null 2>&1 ); check $([ $? -ne 0 ] && echo 0 || echo 1) 'a missing IMAGE_TAG stops Compose (${VAR:?})'

echo "== import guard blocks a weak demo password on the first start"
( export DEMO_PLANNER_PASSWORD=CHANGE_ME; dc up -d keycloak >/dev/null 2>&1 ); rc=$?
check $([ $rc -ne 0 ] && echo 0 || echo 1) 'compose up refuses to start Keycloak' "exit $rc"
check $([ -z "$(docker ps -q --filter "label=com.docker.compose.project=$PROJECT" --filter 'label=com.docker.compose.service=keycloak')" ] && echo 0 || echo 1) 'Keycloak container is not running'
dc down >/dev/null 2>&1

echo "== start the stack"
# memory sampler: peak usage per container from the first start until the end of the test (input for the instance-type decision)
( while :; do ids=$(docker ps -q --filter "label=com.docker.compose.project=$PROJECT"); [ -n "$ids" ] && docker stats --no-stream --format '{{.Name}} {{.MemUsage}}' $ids 2>/dev/null; sleep 1; done ) >"$WORK/mem.log" 2>&1 &   # (empty id list would make docker stats show ALL containers)
SAMPLER=$!
dc up -d >"$WORK/up.log" 2>&1; check $? 'compose up -d succeeds' "$(tail -3 "$WORK/up.log" | tr '\n' ' ')"
client() { # run a command in the compose network inside a small alpine toolbox (curl, openssl, jq, bash)
  docker run --rm --network "$NET" -v "$HERE_NATIVE:/scripts:ro" -e DEMO_PLANNER_PASSWORD -e DEMO_PURCHASER_PASSWORD -e DEMO_ADMIN_PASSWORD \
    alpine:3 sh -c "apk add -q --no-cache bash curl openssl jq coreutils >/dev/null 2>&1 && $*"
}
ready=1
for i in $(seq 1 90); do
  if client "curl -sk -o /dev/null -w '%{http_code}' $AUTH/realms/prodflow/.well-known/openid-configuration" 2>/dev/null | grep -q 200; then ready=0; break; fi
  sleep 4
done
check $ready 'Keycloak realm is served over HTTPS through Caddy (within 6 min)'
if [ $ready -ne 0 ]; then dc ps -a; dc logs --tail 15 keycloak keycloak-import-guard caddy 2>&1 | sed -E 's/(password|secret)[^ ]*/\1=<hidden>/Ig'; fi

echo "== real logins and API (scripts/smoke-auth.sh)"
client "bash /scripts/smoke-auth.sh --auth-url $AUTH --app-url $APP --insecure-local" | tee "$WORK/smoke.log"
check ${PIPESTATUS[0]} 'smoke-auth.sh passes for planner, purchaser and admin' "$(grep -c '^FAIL' "$WORK/smoke.log") FAIL lines"

echo "== public surface"
code() { client "curl -sk -o /dev/null -w '%{http_code}' $1" 2>/dev/null; }
for p in /admin/ /admin/master/console/ /admin/realms/prodflow /realms/master/.well-known/openid-configuration /realms/master /metrics /health /health/ready / \
         /realms/prodflow/../master/ '/realms/prodflow/%2e%2e/master/' '/realms/prodflow/%2e%2e/%2e%2e/admin/' '/realms/prodflow/..%2fmaster' /resources/../admin/ /js/keycloak.js; do
  c=$(code "$AUTH$p"); check $([ "$c" = 404 ] || [ "$c" = 400 ] && echo 0 || echo 1) "auth host: $p is not public" "HTTP $c"
done
for p in /realms/prodflow/.well-known/openid-configuration /realms/prodflow/protocol/openid-connect/certs; do
  c=$(code "$AUTH$p"); check $([ "$c" = 200 ] && echo 0 || echo 1) "auth host: $p is public" "HTTP $c"
done
c=$(code "$APP/actuator/health"); check $([ "$c" = 200 ] && echo 0 || echo 1) 'app host: /actuator/health is public' "HTTP $c"
for p in /actuator/info /actuator /actuator/env /actuator/beans; do c=$(code "$APP$p"); check $([ "$c" = 404 ] && echo 0 || echo 1) "app host: $p is not public" "HTTP $c"; done
c=$(code "$APP/swagger-ui/index.html"); check $([ "$c" = 200 ] && echo 0 || echo 1) 'app host: Swagger UI is served (documented demo exception)' "HTTP $c"
c=$(code "$APP/v3/api-docs"); check $([ "$c" = 200 ] && echo 0 || echo 1) 'app host: /v3/api-docs is served' "HTTP $c"
c=$(code "$APP/api/items"); check $([ "$c" = 401 ] && echo 0 || echo 1) 'app host: /api/items without token -> 401' "HTTP $c"
docs=$(client "curl -sk $APP/v3/api-docs" 2>/dev/null)
check $(printf '%s' "$docs" | grep -q "$AUTH/realms/prodflow/protocol/openid-connect/auth" && echo 0 || echo 1) 'OpenAPI OAuth2 scheme points at the public HTTPS Keycloak URL'
check $(printf '%s' "$docs" | grep -q '"url":"https://app.prodflow.test' && echo 0 || echo 1) 'OpenAPI server URL honours the proxy headers (https app host)'
spoof=$(client "curl -sk -H 'Forwarded: host=evil.test;proto=http' -H 'X-Forwarded-Prefix: /evil' -H 'X-Forwarded-Host: evil.test' $APP/v3/api-docs" 2>/dev/null)
check $(printf '%s' "$spoof" | grep -q 'evil' && echo 1 || echo 0) 'client-supplied Forwarded/X-Forwarded-* headers cannot change generated URLs'
hdr=$(client "curl -skI $APP/swagger-ui/index.html" 2>/dev/null | tr -d '\r')
check $(printf '%s' "$hdr" | grep -qi '^strict-transport-security' && echo 0 || echo 1) 'HSTS header is sent'
check $(printf '%s' "$hdr" | grep -qi '^server:' && echo 1 || echo 0) 'Server header is removed'

echo "== exposure of the host"
ports=$(docker ps --filter "label=com.docker.compose.project=$PROJECT" --format '{{.Names}} {{.Ports}}' | grep -v '^$')
exposed=$(printf '%s\n' "$ports" | grep -o '[0-9.]*:[0-9]*->' | sort -u | tr '\n' ' ')
check $([ "$exposed" = "127.0.0.1:$HTTP_PORT-> 127.0.0.1:$ADMIN_PORT-> 127.0.0.1:$HTTPS_PORT-> " ] && echo 0 || echo 1) 'only Caddy (80/443 mapping) and the Keycloak admin port are published, all on 127.0.0.1' "$exposed"
c=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$ADMIN_PORT/realms/master/.well-known/openid-configuration" 2>/dev/null)
check $([ "$c" = 200 ] && echo 0 || echo 1) 'Keycloak admin interface answers on the loopback port (SSH-tunnel path)' "HTTP $c"
c=$(curl -sk --resolve auth.prodflow.test:$HTTPS_PORT:127.0.0.1 -o /dev/null -w '%{http_code}' "https://auth.prodflow.test:$HTTPS_PORT/realms/prodflow/.well-known/openid-configuration" 2>/dev/null)
check $([ "$c" = 200 ] && echo 0 || echo 1) 'HTTPS is reachable from the host on the published loopback port' "HTTP $c"

echo "== restart keeps the realm and the logins (guard sees the existing realm)"
dc stop keycloak >/dev/null 2>&1; dc up -d keycloak >/dev/null 2>&1; check $? 'stop + up -d keycloak succeeds'
ready=1; for i in $(seq 1 60); do client "curl -sk -o /dev/null -w '%{http_code}' $AUTH/realms/prodflow/.well-known/openid-configuration" 2>/dev/null | grep -q 200 && { ready=0; break; }; sleep 4; done
check $ready 'realm served again after the restart'
client "bash /scripts/smoke-auth.sh --auth-url $AUTH --app-url $APP --insecure-local --users planner --no-api" >"$WORK/smoke2.log" 2>&1
check $? 'the original planner password still works after the restart'

echo "== memory: peak per container since the first start (the t3.small has 2 GiB for everything, Linux and Docker included)"
kill "$SAMPLER" >/dev/null 2>&1; SAMPLER=''
awk '{ v=$2; u=v; gsub(/[0-9.]/,"",u); n=v; gsub(/[A-Za-z]/,"",n); n=n+0; if(u=="GiB") n*=1024; else if(u=="KiB") n/=1024; else if(u=="B") n/=1048576;
       name=$1; sub(/^prodflow-prodcheck-/,"",name); if(n>peak[name]) peak[name]=n }
     END { for (k in peak) { printf("  %-22s peak %6.0f MiB%c", k, peak[k], 10); total+=peak[k] }
           printf("  %-22s peak %6.0f MiB (sum of the individual peaks)%c", "ALL", total, 10) }' "$WORK/mem.log" | sort
oom=0; for c in $(docker ps -aq --filter "label=com.docker.compose.project=$PROJECT"); do [ "$(docker inspect --format '{{.State.OOMKilled}}' "$c")" = true ] && oom=1; done
check $oom 'no container was killed for exceeding its memory limit'
restarts=0; for c in $(docker ps -aq --filter "label=com.docker.compose.project=$PROJECT"); do n=$(docker inspect --format '{{.RestartCount}}' "$c"); restarts=$((restarts + n)); done
check $([ "$restarts" = 0 ] && echo 0 || echo 1) 'no container had to be restarted' "restarts=$restarts"

echo "== secrets"
logs=$(dc logs 2>&1); leaked=0
for v in "$PRODFLOW_DB_PASSWORD" "$KEYCLOAK_DB_PASSWORD" "$KC_BOOTSTRAP_ADMIN_PASSWORD" "$DEMO_PLANNER_PASSWORD" "$DEMO_PURCHASER_PASSWORD" "$DEMO_ADMIN_PASSWORD"; do
  printf '%s' "$logs" | grep -qF -- "$v" && leaked=1
done
check $leaked 'no secret value appears in the container logs'   # leaked=0 -> pass

cleanup; trap - EXIT
echo "== cleanup"
check $([ -z "$(docker ps -aq --filter "label=com.docker.compose.project=$PROJECT")" ] && echo 0 || echo 1) 'no test containers left'
check $([ -z "$(docker volume ls -q --filter "label=com.docker.compose.project=$PROJECT")" ] && echo 0 || echo 1) 'no test volumes left'
check $([ "$STACK_BEFORE" = "$(docker ps -a --filter 'label=com.docker.compose.project=prodflow' --format '{{.ID}}' | sort | tr '\n' ' ')" ] && echo 0 || echo 1) 'development stack containers unchanged'
echo "test-prod-stack result: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
