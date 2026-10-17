#!/usr/bin/env bash
# Pull-based deployment agent (Issue #18): runs on the server every minute (systemd timer) and needs NO inbound connection.
# CI moves the GHCR tag "prod" to every image that passed Test and Build. This agent pulls that tag, reads the commit the image was
# built from (OCI label org.opencontainers.image.revision) and, when it differs from the running tag, calls deploy.sh (health gate +
# automatic rollback). A tag that failed to deploy is remembered and not retried until a newer image appears.
# Pause automatic deployments (e.g. after a manual rollback):  touch /var/lib/prodflow/hold   (resume: rm it).
#
#   deploy/agent.sh            (environment: PROD_IMAGE overrides the image reference, STATE_DIR the state directory)
set -uo pipefail
# Whole script inside main(): the repository is replaced during a deployment (see deploy.sh), parse everything first.
main() {
  cd "$(dirname "$0")"
  IMAGE=${PROD_IMAGE:-$(sed -n 's/^BACKEND_IMAGE=//p' .env 2>/dev/null | tail -1 | tr -d '\r')}
  IMAGE=${IMAGE:-ghcr.io/sababif-bit/prodflow}
  STATE_DIR=${STATE_DIR:-/var/lib/prodflow}
  mkdir -p "$STATE_DIR"
  exec 9>"$STATE_DIR/agent.lock"
  flock -n 9 || { echo "agent: another run is active"; exit 0; }
  log() { echo "$(date -u +%FT%TZ) agent: $*"; }

  [ -r .env ] || { log ".env missing - bootstrap first"; exit 0; }
  [ ! -e "$STATE_DIR/hold" ] || { log "hold file present - deployments paused"; exit 0; }
  if ! docker pull -q "$IMAGE:prod" >/dev/null 2>&1; then log "cannot pull $IMAGE:prod (registry unreachable or tag missing) - nothing to do"; exit 0; fi
  rev=$(docker inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$IMAGE:prod" 2>/dev/null || true)
  if ! [[ $rev =~ ^[0-9a-f]{40}$ ]]; then log "prod image has no valid revision label - ignoring"; exit 0; fi
  tag="sha-${rev:0:7}"
  current=$(sed -n 's/^IMAGE_TAG=//p' .env | tail -1 | tr -d '\r')
  if [ "$current" = "$tag" ]; then exit 0; fi
  if [ -r "$STATE_DIR/failed" ] && [ "$(cat "$STATE_DIR/failed")" = "$tag" ]; then log "$tag failed earlier - waiting for a newer image"; exit 0; fi

  log "new release $tag (running: ${current:-none})"
  if bash ./deploy.sh "$tag"; then
    rm -f "$STATE_DIR/failed"; log "$tag deployed"
  else
    echo "$tag" >"$STATE_DIR/failed"; log "$tag FAILED and was rolled back"; exit 1
  fi
}
main "$@"; exit $?
