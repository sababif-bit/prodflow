#!/usr/bin/env bash
# Deploys one backend image tag on the server and rolls back automatically when it does not become healthy.
#   deploy/deploy.sh sha-1a2b3c4          (run on the server; also the manual path, and the unit the pull agent calls in #18)
#
# - The tag must be a commit tag "sha-<commit>" (or any tag matching [A-Za-z0-9._-]+ when DEPLOY_SKIP_GIT=1). The repository on the
#   server is moved to that commit so Compose file, Caddyfile and realm import match the image that is started.
# - .env (mode 600, never in Git) keeps the secrets; only the IMAGE_TAG line is rewritten.
# - Health gate: the backend container must become healthy within DEPLOY_TIMEOUT seconds (default 240), otherwise the previous
#   tag (and commit) is started again and the script exits 1.
set -euo pipefail
# The whole script lives in main() and is called on the last line: bash has parsed the complete file before anything runs, so the
# repository checkout below (which replaces this very file) cannot corrupt the running script.
main() {
  cd "$(dirname "$0")"
  TAG=${1:?usage: deploy.sh <image-tag, e.g. sha-1a2b3c4>}
  TIMEOUT=${DEPLOY_TIMEOUT:-240}
  [[ $TAG =~ ^[A-Za-z0-9._-]{1,128}$ ]] || { echo "invalid tag" >&2; exit 2; }
  [ -r .env ] || { echo "deploy/.env missing (run bootstrap-server.sh first)" >&2; exit 2; }
  dc() { docker compose --env-file .env -f docker-compose.prod.yml "$@"; }
  current_tag() { sed -n 's/^IMAGE_TAG=//p' .env | tail -1 | tr -d '\r'; }
  set_tag() { sed -i "s/^IMAGE_TAG=.*/IMAGE_TAG=$1/" .env; }
  checkout_for() { # move the repository to the commit encoded in the tag
    [ "${DEPLOY_SKIP_GIT:-0}" = 1 ] && return 0
    case "$1" in sha-*) git -C .. fetch --quiet origin && git -C .. checkout --quiet --detach "${1#sha-}" ;; *) echo "tag is not sha-<commit>; set DEPLOY_SKIP_GIT=1 to deploy it anyway" >&2; return 1 ;; esac
  }
  wait_healthy() {
    local deadline=$((SECONDS + TIMEOUT)) id state
    while [ $SECONDS -lt $deadline ]; do
      id=$(dc ps -q backend 2>/dev/null || true)
      if [ -n "$id" ]; then
        state=$(docker inspect --format '{{.State.Health.Status}}' "$id" 2>/dev/null || echo none)
        [ "$state" = healthy ] && return 0
      fi
      sleep 5
    done
    return 1
  }

  # Inside an `if` condition set -e does not abort: a failing pull/up (e.g. Compose gives up because the backend never becomes
  # healthy) must lead to the rollback below, not end the script with the bad release still configured.
  release() { dc pull --quiet backend && dc up -d --remove-orphans; }

  PREV=$(current_tag)
  echo "deploy: ${PREV:-<none>} -> $TAG"
  if checkout_for "$TAG" && set_tag "$TAG" && release && wait_healthy; then
    echo "deploy: $TAG is healthy"
    exit 0
  fi
  echo "deploy: $TAG could not be started or did NOT become healthy within ${TIMEOUT}s - rolling back to ${PREV:-<none>}" >&2
  if [ -n "$PREV" ] && [ "$PREV" != "$TAG" ]; then
    checkout_for "$PREV" || true
    set_tag "$PREV"
    dc up -d --remove-orphans || true
  fi
  exit 1
}
main "$@"; exit $?
