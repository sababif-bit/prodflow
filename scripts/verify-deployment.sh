#!/usr/bin/env bash
# Verifies a RUNNING ProdFlow deployment from the outside: the single-page application, its runtime configuration, the API's
# authorization and the operational endpoints. Read-only: only GET requests (plus POST/GET requests that MUST be rejected for lack of a token).
# Used by the CI "verify" job after every release, by scripts/test-prod-stack.sh against a local production-like stack, and by hand.
#
#   scripts/verify-deployment.sh --app-url https://app.example.org [--expect-revision <40-hex commit>] [--expect-auth-url https://auth.example.org]
#                                [--insecure-local] [--no-edge-headers]
#
#   --expect-revision     GET /version must report exactly this commit
#   --expect-auth-url     /config.json must point at exactly this sign-in server
#   --insecure-local      accept the self-signed certificate of the local test stack (only for localhost / *.test hosts)
#   --no-edge-headers     skip the checks of headers that the reverse proxy (Caddy) adds (CSP, HSTS); for talking to the backend directly
# Exit: 0 = every check passed, 1 = a check failed, 3 = usage error / prerequisite missing.
set -u
APP=""; REV=""; AUTH_EXPECT=""; INSECURE=0; EDGE=1
while [ $# -gt 0 ]; do
  case "$1" in
    --app-url) APP=${2:-}; shift 2 ;;
    --expect-revision) REV=${2:-}; shift 2 ;;
    --expect-auth-url) AUTH_EXPECT=${2:-}; shift 2 ;;
    --insecure-local) INSECURE=1; shift ;;
    --no-edge-headers) EDGE=0; shift ;;
    *) echo "unknown option: $1" >&2; exit 3 ;;
  esac
done
command -v curl >/dev/null && command -v jq >/dev/null || { echo "curl and jq are required" >&2; exit 3; }
[ -n "$APP" ] || { echo "usage: $0 --app-url <https://host> [options]" >&2; exit 3; }
APP=${APP%/}
case "$APP" in https://*) ;; http://localhost*|http://127.0.0.1*) ;; *) echo "--app-url must be https (http only for localhost)" >&2; exit 3 ;; esac
CURL=(curl -sS --max-time 20)
if [ "$INSECURE" = 1 ]; then
  case "$APP" in *localhost*|*127.0.0.1*|*.test|*.test:*|*.test/*) CURL+=(-k) ;; *) echo "--insecure-local is only allowed for localhost / *.test hosts" >&2; exit 3 ;; esac
fi

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
check() { if [ "$1" = 0 ]; then PASS=$((PASS + 1)); echo "PASS  $2"; else FAIL=$((FAIL + 1)); echo "FAIL  $2${3:+  ($3)}"; fi; }
# get <path> [curl options...]  ->  $WORK/h (headers), $WORK/b (body); prints the status code
get() { local path=$1 code; shift; code=$("${CURL[@]}" -o "$WORK/b" -D "$WORK/h" -w '%{http_code}' "$@" "$APP$path" 2>/dev/null) || true; echo "${code:-000}"; }
header() { tr -d '\r' <"$WORK/h" | grep -i "^$1:" | head -1 | cut -d: -f2- | sed 's/^ *//'; }
has() { grep -qiE "$1" <<<"$2" && echo 0 || echo 1; }

echo "== application shell"
c=$(get /); check $([ "$c" = 200 ] && echo 0 || echo 1) 'GET / returns the application' "HTTP $c"
ct=$(header content-type); check $(has '^text/html' "$ct") 'GET / is HTML' "$ct"
check $(grep -q '<app-root' "$WORK/b" && echo 0 || echo 1) 'the HTML contains the Angular root element'
cc=$(header cache-control); check $(has 'no-store|no-cache' "$cc") 'index.html is not cacheable (a new release is picked up immediately)' "$cc"
cp "$WORK/b" "$WORK/index.html"
script=$(grep -o 'src="[^"]*\.js"' "$WORK/index.html" | head -1 | sed 's/src="//; s/"$//')
check $([ -n "$script" ] && echo 0 || echo 1) 'index.html references its main script' "$script"
if [ -n "$script" ]; then
  c=$(get "/$script"); ct=$(header content-type)
  check $([ "$c" = 200 ] && echo 0 || echo 1) "the main script is served (/$script)" "HTTP $c"
  check $(has 'javascript' "$ct") 'the main script has a JavaScript content type (not index.html)' "$ct"
  if [ "$EDGE" = 1 ]; then cc=$(header cache-control); check $(has 'immutable' "$cc") 'hashed bundles are cached for a long time (immutable)' "$cc"; fi
fi
for route in /uebersicht /auftraege /auftraege/1 /bestellanforderungen /bestand /bestand/1; do
  c=$(get "$route"); body_ok=$(grep -q '<app-root' "$WORK/b" && echo 0 || echo 1)
  check $([ "$c" = 200 ] && [ "$body_ok" = 0 ] && echo 0 || echo 1) "deep link $route returns the application (reload works)" "HTTP $c"
done
c=$(get /does-not-exist-123); check $([ "$c" = 401 ] || [ "$c" = 404 ] && echo 0 || echo 1) 'an unknown path is not turned into the application (deny by default)' "HTTP $c"

echo "== runtime configuration"
c=$(get /config.json); check $([ "$c" = 200 ] && echo 0 || echo 1) 'GET /config.json answers' "HTTP $c"
cc=$(header cache-control); check $(has 'no-store' "$cc") 'config.json is never cached' "$cc"
kc_url=$(jq -r '.keycloak.url // empty' "$WORK/b" 2>/dev/null); realm=$(jq -r '.keycloak.realm // empty' "$WORK/b" 2>/dev/null); cid=$(jq -r '.keycloak.clientId // empty' "$WORK/b" 2>/dev/null)
check $([ "$realm" = prodflow ] && [ "$cid" = prodflow-web ] && echo 0 || echo 1) 'config.json names the realm prodflow and the public client prodflow-web' "realm=$realm client=$cid"
case "$APP" in
  https://*) check $(has '^https://' "$kc_url") 'the sign-in server is reached over https (no localhost value leaked into production)' "$kc_url"
             check $(grep -qiE 'localhost|127\.0\.0\.1' <<<"$kc_url" && echo 1 || echo 0) 'the sign-in server is not a localhost address' "$kc_url" ;;
  *) : ;;
esac
[ -z "$AUTH_EXPECT" ] || check $([ "$kc_url" = "${AUTH_EXPECT%/}" ] && echo 0 || echo 1) 'config.json points at the expected sign-in server' "$kc_url"
if [ -n "$kc_url" ]; then
  c=$("${CURL[@]}" -o /dev/null -w '%{http_code}' "$kc_url/realms/$realm/.well-known/openid-configuration" 2>/dev/null) || true; c=${c:-000}
  check $([ "$c" = 200 ] && echo 0 || echo 1) 'the sign-in server answers for that realm' "HTTP $c"
fi

echo "== API authorization (all requests WITHOUT a valid token must be rejected)"
for p in /api/items /api/production-orders /api/purchase-requests; do c=$(get "$p"); check $([ "$c" = 401 ] && echo 0 || echo 1) "GET $p without token -> 401" "HTTP $c"; done
c=$(get /api/production-orders -X POST -H 'Content-Type: application/json' -d '{}'); check $([ "$c" = 401 ] && echo 0 || echo 1) 'POST /api/production-orders without token -> 401' "HTTP $c"
c=$(get /api/items -H 'Authorization: Bearer not-a-real-token'); check $([ "$c" = 401 ] && echo 0 || echo 1) 'a forged bearer token -> 401' "HTTP $c"
c=$(get /api/unknown); check $([ "$c" = 401 ] && echo 0 || echo 1) 'an unmapped API path -> 401 (deny by default)' "HTTP $c"

echo "== operations"
c=$(get /actuator/health); st=$(jq -r '.status // empty' "$WORK/b" 2>/dev/null); check $([ "$c" = 200 ] && [ "$st" = UP ] && echo 0 || echo 1) '/actuator/health is UP' "HTTP $c $st"
for p in /actuator/info /actuator/env /actuator/beans; do c=$(get "$p"); check $([ "$c" != 200 ] && echo 0 || echo 1) "$p is not public" "HTTP $c"; done
c=$(get /version); rev=$(jq -r '.revision // empty' "$WORK/b" 2>/dev/null)
check $([ "$c" = 200 ] && printf '%s' "$rev" | grep -qE '^[0-9a-f]{40}$' && echo 0 || echo 1) '/version reports a commit revision' "HTTP $c rev=${rev:0:12}"
[ -z "$REV" ] || check $([ "$rev" = "$REV" ] && echo 0 || echo 1) 'the running revision is the expected commit' "running ${rev:0:7}, expected ${REV:0:7}"

if [ "$EDGE" = 1 ]; then
  echo "== reverse proxy headers"
  get / >/dev/null; csp=$(header content-security-policy)
  check $(has "script-src 'self'(;|$)" "$csp") "CSP: scripts only from the application itself (no 'unsafe-inline')"
  check $(has "frame-ancestors 'none'" "$csp") 'CSP: the application cannot be framed (clickjacking)'
  check $(has "object-src 'none'" "$csp") 'CSP: no plug-ins'
  [ -z "$kc_url" ] || check $(has "connect-src [^;]*$(printf '%s' "$kc_url" | sed 's/[.[\*^$/]/\\&/g')" "$csp") 'CSP: the only external connection is the sign-in server'
  check $(has '^max-age=' "$(header strict-transport-security)") 'HSTS is sent'
  check $(has 'nosniff' "$(header x-content-type-options)") 'X-Content-Type-Options: nosniff is sent'
  [ -z "$(header server)" ] && check 0 'no Server header' || check 1 'no Server header' "$(header server)"
fi

echo "verify-deployment result: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
