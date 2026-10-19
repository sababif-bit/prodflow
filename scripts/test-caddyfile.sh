#!/usr/bin/env bash
# Offline test of deploy/Caddyfile with the real Caddy image (no network access to Let's Encrypt, no certificates, no containers kept).
# It exists because a documented rehearsal setting (a one-line "tls { ca ... }" block) turned out to be invalid Caddyfile syntax:
# every supported way of configuring TLS/ACME must pass `caddy validate`, and the ACME directory must really end up in the configuration.
# Run: scripts/test-caddyfile.sh       Exit: 0 = all passed, 1 = a check failed, 3 = Docker not available
set -u
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
HERE=$(cd "$(dirname "$0")" && pwd)
CF="$(cd "$HERE/../deploy" && { pwd -W 2>/dev/null || pwd; })/Caddyfile"
IMG=caddy:2.8-alpine
PASS=0; FAIL=0
check() { if [ "$1" = 0 ]; then PASS=$((PASS + 1)); echo "PASS  $2"; else FAIL=$((FAIL + 1)); echo "FAIL  $2${3:+  ($3)}"; fi; }
docker version >/dev/null 2>&1 || { echo "Docker not available"; exit 3; }
caddy() { # caddy <validate|adapt> [docker -e options...]
  local cmd=$1; shift
  docker run --rm -e APP_HOST=app.example.org -e AUTH_HOST=auth.example.org "$@" -v "$CF:/etc/caddy/Caddyfile:ro" $IMG \
    caddy "$cmd" --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1
}
valid() { caddy validate "$@" | grep -q 'Valid configuration'; }

valid -e TLS_DIRECTIVE=; check $? 'production: ACME_CA not set at all falls back to the production directory'
valid -e TLS_DIRECTIVE= -e ACME_CA=https://acme-staging-v02.api.letsencrypt.org/directory; check $? 'staging ACME directory is accepted'
valid -e "TLS_DIRECTIVE=tls internal"; check $? 'tls internal (local tests) is accepted'
out=$(caddy validate -e "TLS_DIRECTIVE=tls { ca https://acme-staging-v02.api.letsencrypt.org/directory }")
check $(printf '%s' "$out" | grep -q 'Valid configuration' && echo 1 || echo 0) 'the old one-line "tls { ca ... }" form stays invalid (must never be documented again)'

prod=$(caddy adapt -e TLS_DIRECTIVE=)
stg=$(caddy adapt -e TLS_DIRECTIVE= -e ACME_CA=https://acme-staging-v02.api.letsencrypt.org/directory)
check $(printf '%s' "$prod" | tr -d ' \n' | grep -q '"ca":"https://acme-v02.api.letsencrypt.org/directory"' && echo 0 || echo 1) 'default configuration uses the production Let'"'"'s Encrypt directory'
check $(printf '%s' "$stg" | tr -d ' \n' | grep -q '"ca":"https://acme-staging-v02.api.letsencrypt.org/directory"' && echo 0 || echo 1) 'ACME_CA switches the configuration to the staging directory'
check $(printf '%s' "$prod" | tr -d ' \n' | grep -q '"app.example.org"' && printf '%s' "$prod" | tr -d ' \n' | grep -q '"auth.example.org"' && echo 0 || echo 1) 'both hostnames are served'
check $(printf '%s' "$prod" | tr -d ' \n' | grep -q '"admin":{"disabled":true}' && echo 0 || echo 1) 'the Caddy admin API is disabled'
# Compose maps an EMPTY ACME_CA in deploy/.env to the production directory (Caddy itself would reject an empty value)
COMPOSE="$(cd "$HERE/../deploy" && { pwd -W 2>/dev/null || pwd; })/docker-compose.prod.yml"
cfg=$(ACME_CA= APP_HOST=a AUTH_HOST=b APP_URL=https://a AUTH_URL=https://b IMAGE_TAG=x PRODFLOW_DB_PASSWORD=p KEYCLOAK_DB_NAME=k KEYCLOAK_DB_USER=k KEYCLOAK_DB_PASSWORD=p       KC_BOOTSTRAP_ADMIN_USERNAME=a KC_BOOTSTRAP_ADMIN_PASSWORD=p DEMO_PLANNER_PASSWORD=p DEMO_PURCHASER_PASSWORD=p DEMO_ADMIN_PASSWORD=p       COMPOSE_DISABLE_ENV_FILE=1 docker compose -f "$COMPOSE" config 2>/dev/null)
check $(printf '%s' "$cfg" | grep -q 'ACME_CA: https://acme-v02.api.letsencrypt.org/directory' && echo 0 || echo 1) 'compose turns an empty ACME_CA into the production directory'
echo "test-caddyfile result: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
