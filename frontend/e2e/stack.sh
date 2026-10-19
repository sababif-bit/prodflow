#!/usr/bin/env bash
# Disposable end-to-end stack for the frontend tests.
#   e2e/stack.sh up      start (generates random secrets into e2e/.stack.env on first use; builds the backend image if missing)
#   e2e/stack.sh down    stop and DELETE the stack including its volumes (project prodflow-fe-e2e only)
#   e2e/stack.sh reset   down + up (a clean demo baseline)
#   e2e/stack.sh build   rebuild the backend image (it contains the SPA: run after frontend or backend changes)
#   e2e/stack.sh status
# Never touches the development stack (project "prodflow", ports 8080/8180) or production. Secrets stay in the git-ignored file.
set -u
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
HERE=$(cd "$(dirname "$0")" && pwd)
NATIVE=$(cd "$HERE" && { pwd -W 2>/dev/null || pwd; })
ENV_FILE="$HERE/.stack.env"
PROJECT=prodflow-fe-e2e
dc() { COMPOSE_DISABLE_ENV_FILE=1 docker compose -p "$PROJECT" --env-file "$NATIVE/.stack.env" -f "$NATIVE/stack/docker-compose.yml" "$@"; }

gen() { openssl rand -base64 18 | tr -d '\r\n=+/'; }

ensure_env() {
  if [ ! -s "$ENV_FILE" ]; then
    umask 077
    {
      echo "E2E_DB_PASSWORD=$(gen)"
      echo "E2E_KC_DB_PASSWORD=$(gen)"
      echo "E2E_KC_ADMIN_PASSWORD=$(gen)"
      echo "E2E_PLANNER_PASSWORD=Pl-$(gen)"
      echo "E2E_PURCHASER_PASSWORD=Pu-$(gen)"
      echo "E2E_ADMIN_PASSWORD=Ad-$(gen)"
    } >"$ENV_FILE"
    echo "created $ENV_FILE (random secrets, git-ignored)"
  fi
}

case "${1:-}" in
  up)
    ensure_env
    docker image inspect prodflow-backend:fe-e2e >/dev/null 2>&1 || dc build backend
    dc up -d --wait --wait-timeout 300 || { dc ps; exit 1; }
    echo "stack is up: backend http://localhost:18080  Keycloak http://localhost:18180  (realm prodflow)"
    ;;
  build)
    dc build backend
    ;;
  down)
    dc down -v --remove-orphans
    ;;
  reset)
    "$0" down && "$0" up
    ;;
  status)
    dc ps
    ;;
  *)
    echo "usage: e2e/stack.sh build|up|down|reset|status" >&2
    exit 2
    ;;
esac
