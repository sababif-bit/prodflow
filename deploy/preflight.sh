#!/usr/bin/env bash
# Pre-flight checks used by bootstrap-server.sh before the stack is started (Issue #17). Fails early, with a clear message, instead of
# letting Compose or Caddy fail half-way (a Caddy that cannot validate its names burns Let's Encrypt's failed-validation limit).
#
#   deploy/preflight.sh image <image-ref>            the image tag exists in the registry (anonymous pull, no login)
#   deploy/preflight.sh dns <host> [<host> ...]      every host resolves to THIS server's public IPv4 address
# Environment: DNS_WAIT_TRIES (default 30) x DNS_WAIT_SECONDS (default 10) = how long to wait for DNS; PUBLIC_IP overrides the detected IP.
# Exit: 0 = ok, 1 = check failed, 2 = usage.
set -u
fail() { echo "preflight: FAILED - $1" >&2; exit 1; }
mode=${1:-}; shift || true
case "$mode" in
  image)
    ref=${1:?image reference required}
    docker manifest inspect "$ref" >/dev/null 2>&1 || fail "image '$ref' cannot be found in the registry (wrong IMAGE_TAG? has the CI build of that commit finished? is the package public?)"
    echo "preflight: image $ref exists" ;;
  dns)
    [ $# -ge 1 ] || { echo "usage: preflight.sh dns <host>..." >&2; exit 2; }
    mine=${PUBLIC_IP:-$(curl -fsS --max-time 10 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]')}
    [[ $mine =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "cannot determine this server's public IPv4 address"
    tries=${DNS_WAIT_TRIES:-30}; wait=${DNS_WAIT_SECONDS:-10}
    for h in "$@"; do
      ok=0; seen=''
      for ((i = 1; i <= tries; i++)); do
        seen=$(getent ahostsv4 "$h" 2>/dev/null | awk 'NR==1 {print $1}')
        [ "$seen" = "$mine" ] && { ok=1; break; }
        [ "$i" -lt "$tries" ] && sleep "$wait"
      done
      [ "$ok" = 1 ] || fail "$h resolves to '${seen:-nothing}', this server is $mine - update DuckDNS (scripts/duckdns-update.sh) and wait for it before starting Caddy"
      echo "preflight: $h -> $mine"
    done ;;
  *) echo "usage: preflight.sh image <ref> | dns <host>..." >&2; exit 2 ;;
esac
