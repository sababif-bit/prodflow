#!/usr/bin/env bash
# Points the two DuckDNS names of the production stack (APP_HOST, AUTH_HOST) at this server's current public IP.
# Run on the server (cron/systemd timer, or by hand after every IP change, e.g. after a stop/start without Elastic IP):
#   deploy/../scripts/duckdns-update.sh [path-to-.env]        (default: deploy/.env next to docker-compose.prod.yml)
# The token is read from DUCKDNS_TOKEN in that .env and sent via a curl config on stdin, so it never appears in the process list,
# the shell history or this script's output. Output: "OK" or "KO" per update, nothing else.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ENV_FILE=${1:-$HERE/../deploy/.env}
[ -r "$ENV_FILE" ] || { echo "cannot read $ENV_FILE" >&2; exit 2; }
getv() { sed -n "s/^$1=//p" "$ENV_FILE" | tail -1 | tr -d '\r'; }
TOKEN=$(getv DUCKDNS_TOKEN); APP_HOST=$(getv APP_HOST); AUTH_HOST=$(getv AUTH_HOST)
{ [ -n "$TOKEN" ] && [ "$TOKEN" != CHANGE_ME ]; } || { echo "DUCKDNS_TOKEN is not set in $ENV_FILE" >&2; exit 2; }
[ -n "$APP_HOST" ] && [ -n "$AUTH_HOST" ] || { echo "APP_HOST/AUTH_HOST missing in $ENV_FILE" >&2; exit 2; }
domains=''
for h in "$APP_HOST" "$AUTH_HOST"; do
  case "$h" in
    *.duckdns.org) domains="${domains:+$domains,}${h%.duckdns.org}" ;;
    *) echo "refusing to update a non-DuckDNS host: $h" >&2; exit 2 ;;
  esac
done
# empty ip= lets DuckDNS use the address the request comes from (the server's public IP)
answer=$(printf 'url = "https://www.duckdns.org/update?domains=%s&token=%s&ip="\n' "$domains" "$TOKEN" | curl -fsS --max-time 20 -K - 2>/dev/null)
case "$answer" in OK*) echo "OK ($domains)"; exit 0 ;; *) echo "KO ($domains)"; exit 1 ;; esac
