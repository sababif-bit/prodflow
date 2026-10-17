#!/usr/bin/env bash
# One-time setup of a fresh Ubuntu 24.04 EC2 instance for the ProdFlow production stack (Issue #17). Repeatable (idempotent).
#
#   sudo APP_HOST=app-xyz.duckdns.org AUTH_HOST=auth-xyz.duckdns.org IMAGE_TAG=sha-1a2b3c4 bash bootstrap-server.sh
#   (the DuckDNS token is asked for interactively and never echoed; or pass DUCKDNS_TOKEN in the environment of THIS command only)
#
# What it does: installs Docker (official apt repository), adds swap, clones the public repository to /opt/prodflow/repo,
# creates deploy/.env with RANDOM secrets generated on this server (mode 600, never printed, never leaves the server),
# updates the DuckDNS names, then starts the stack with deploy/deploy.sh. This script contains no secret and is safe to keep in Git
# and to download from the repository; it must NOT be placed in EC2 user-data together with secrets.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo)" >&2; exit 2; }
: "${APP_HOST:?APP_HOST (DuckDNS name of the application)}" "${AUTH_HOST:?AUTH_HOST (DuckDNS name of Keycloak)}" "${IMAGE_TAG:?IMAGE_TAG, e.g. sha-1a2b3c4}"
REPO_URL=${REPO_URL:-https://github.com/sababif-bit/prodflow.git}
BASE=/opt/prodflow
SWAP_GB=${SWAP_GB:-2}

echo "== packages and Docker"
export DEBIAN_FRONTEND=noninteractive
# a freshly started instance often runs unattended-upgrades/cloud-init for a few minutes and holds the dpkg lock: wait for it instead of failing
apt-get -o DPkg::Lock::Timeout=300 update -qq
apt-get -o DPkg::Lock::Timeout=300 install -y -qq ca-certificates curl git openssl jq >/dev/null
if ! command -v docker >/dev/null 2>&1; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" >/etc/apt/sources.list.d/docker.list
  apt-get -o DPkg::Lock::Timeout=300 update -qq
  apt-get -o DPkg::Lock::Timeout=300 install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin >/dev/null
fi
systemctl enable --now docker >/dev/null

echo "== swap (${SWAP_GB} GB) as a safety net for Keycloak's start-up memory peak"
if ! swapon --show | grep -q /swapfile; then
  fallocate -l "${SWAP_GB}G" /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
fi

echo "== repository"
mkdir -p "$BASE"
if [ -d "$BASE/repo/.git" ]; then git -C "$BASE/repo" fetch --quiet origin; else git clone --quiet "$REPO_URL" "$BASE/repo"; fi
DEPLOY="$BASE/repo/deploy"

echo "== pre-flight: image tag exists in the registry"
bash "$DEPLOY/preflight.sh" image "${BACKEND_IMAGE:-ghcr.io/sababif-bit/prodflow}:$IMAGE_TAG"

echo "== deploy/.env (secrets generated here)"
if [ -e "$DEPLOY/.env" ]; then
  echo "deploy/.env already exists - keeping it (delete it deliberately to regenerate; that also requires fresh volumes)"
else
  if [ -z "${DUCKDNS_TOKEN:-}" ]; then
    read -r -s -p "DuckDNS token (input hidden): " DUCKDNS_TOKEN; echo
  else
    echo "NOTE: the DuckDNS token came from the environment. If you typed it on a command line it is in your shell history - prefer the hidden prompt and rotate the token if in doubt." >&2
  fi
  gen() { openssl rand -base64 18 | tr -d '\r\n'; }
  umask 077
  cat >"$DEPLOY/.env" <<ENVEOF
APP_HOST=$APP_HOST
AUTH_HOST=$AUTH_HOST
APP_URL=https://$APP_HOST
AUTH_URL=https://$AUTH_HOST
BACKEND_IMAGE=ghcr.io/sababif-bit/prodflow
IMAGE_TAG=$IMAGE_TAG
PRODFLOW_DB_PASSWORD=$(gen)
KEYCLOAK_DB_NAME=keycloak
KEYCLOAK_DB_USER=keycloak
KEYCLOAK_DB_PASSWORD=$(gen)
KC_BOOTSTRAP_ADMIN_USERNAME=admin
KC_BOOTSTRAP_ADMIN_PASSWORD=$(gen)
DEMO_PLANNER_PASSWORD=$(gen)
DEMO_PURCHASER_PASSWORD=$(gen)
DEMO_ADMIN_PASSWORD=$(gen)
DUCKDNS_TOKEN=$DUCKDNS_TOKEN
ENVEOF
  # optional: ACME directory, e.g. the Let's Encrypt STAGING directory for a rehearsal (see docs/first-deployment-runbook.md); not for the real run
  case "${ACME_CA:-}" in
    '') ;;
    https://*) case "$ACME_CA" in *[!A-Za-z0-9./:_-]*) echo "ACME_CA contains unexpected characters" >&2; exit 2 ;; *) printf 'ACME_CA=%s\n' "$ACME_CA" >>"$DEPLOY/.env" ;; esac ;;
    *) echo "ACME_CA must be an https URL" >&2; exit 2 ;;
  esac
  # optional: Caddy TLS directive, only for tests (e.g. 'tls internal'); never needed for the real run
  case "${TLS_DIRECTIVE:-}" in
    *"'"*) echo "TLS_DIRECTIVE must not contain a single quote" >&2; exit 2 ;;
    '') ;;
    *) printf "TLS_DIRECTIVE='%s'\n" "$TLS_DIRECTIVE" >>"$DEPLOY/.env" ;;
  esac
  chmod 600 "$DEPLOY/.env"
  unset DUCKDNS_TOKEN
fi

echo "== DuckDNS"
bash "$BASE/repo/scripts/duckdns-update.sh" "$DEPLOY/.env" || { echo "ERROR: DuckDNS update failed (token/names wrong?) - not starting the stack, Caddy could not get certificates" >&2; exit 1; }
if [ "${SKIP_DNS_CHECK:-0}" != 1 ]; then
  echo "== pre-flight: both names must resolve to this server before Caddy starts (up to 5 minutes)"
  bash "$DEPLOY/preflight.sh" dns "$APP_HOST" "$AUTH_HOST"
fi

echo "== start the stack"
chmod +x "$DEPLOY/deploy.sh"
DEPLOY_SKIP_GIT="${DEPLOY_SKIP_GIT:-0}" bash "$DEPLOY/deploy.sh" "$IMAGE_TAG"

echo "== deployment agent (pull-based: checks GHCR tag 'prod' every minute, no inbound access needed)"
install -m 0644 "$DEPLOY/prodflow-agent.service" "$DEPLOY/prodflow-agent.timer" /etc/systemd/system/
chmod +x "$DEPLOY/agent.sh"
systemctl daemon-reload
systemctl enable --now prodflow-agent.timer >/dev/null

cat <<'DONE'

Done. Next:
  - Read the demo passwords ONLY on the server, when you need them:  sudo grep '^DEMO_' /opt/prodflow/repo/deploy/.env
  - Verify from your laptop: scripts/smoke-auth.sh (or smoke-auth.ps1) against the https URLs.
  - New releases arrive by themselves: CI moves the GHCR tag 'prod'; the agent deploys it (log: journalctl -u prodflow-agent).
  - Keycloak administration: SSH tunnel  ssh -L 8180:127.0.0.1:8180 <user>@<server>  then http://localhost:8180
DONE
