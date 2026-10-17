#!/usr/bin/env bash
# Real login check for Linux/CI (bash + curl + openssl + jq). Counterpart of smoke-auth.ps1, intended for the deployed stack
# (AWS, Verify stage) and for the disposable production-stack test.
#
# Per demo user it performs the browser flow: Authorization Code + PKCE S256 against Keycloak (no password grant), then checks
# the access token (issuer, audience, role, lifetime), the CORS answer of the token endpoint, a refresh-token exchange, the API
# with the real token (401 without token, 200 with token, 403/404 on the purchase approval depending on the role) and that the
# literal placeholder text is NOT accepted as a password. Passwords come ONLY from the environment; nothing secret is printed.
#
# Usage (passwords in the environment, never as arguments):
#   DEMO_PLANNER_PASSWORD=... DEMO_PURCHASER_PASSWORD=... DEMO_ADMIN_PASSWORD=... \
#   scripts/smoke-auth.sh --auth-url https://auth.example.org --app-url https://app.example.org [--users planner,purchaser,admin]
# Options: --client prodflow-swagger  --expected-lifespan 1800  --no-api  --resolve-host <ip> (curl --resolve is NOT used; use DNS)
#          --insecure-local   accept an untrusted certificate, ONLY for hosts ending in .test or .localhost
# Exit code: 0 = all checks passed, 1 = a check failed, 2 = usage/precondition error.
set -u

AUTH_URL=''; APP_URL=''; CLIENT='prodflow-swagger'; LIFESPAN=1800; USERS='planner,purchaser,admin'; API=1; INSECURE=0; REALM='prodflow'
while [ $# -gt 0 ]; do
  case "$1" in
    --auth-url) AUTH_URL=${2%/}; shift 2 ;;
    --app-url) APP_URL=${2%/}; shift 2 ;;
    --client) CLIENT=$2; shift 2 ;;
    --expected-lifespan) LIFESPAN=$2; shift 2 ;;
    --users) USERS=$2; shift 2 ;;
    --realm) REALM=$2; shift 2 ;;
    --no-api) API=0; shift ;;
    --insecure-local) INSECURE=1; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[ -n "$AUTH_URL" ] && [ -n "$APP_URL" ] || { echo "usage: --auth-url <url> --app-url <url>" >&2; exit 2; }
for t in curl openssl jq sed tr base64; do command -v "$t" >/dev/null 2>&1 || { echo "missing tool: $t" >&2; exit 2; }; done

host_of() { printf '%s' "$1" | sed -E 's#^https?://([^/:]+).*#\1#'; }
case "$AUTH_URL" in
  https://*) ;;
  http://localhost*|http://127.0.0.1*) ;;
  *) echo "refusing to send credentials over plain HTTP to $(host_of "$AUTH_URL")" >&2; exit 2 ;;
esac
CURL_TLS=''
if [ "$INSECURE" -eq 1 ]; then
  case "$(host_of "$AUTH_URL")" in
    *.test|*.localhost|localhost) CURL_TLS='-k' ;;
    *) echo "--insecure-local is only allowed for hosts ending in .test or .localhost" >&2; exit 2 ;;
  esac
fi

WORK=$(mktemp -d) || exit 2
chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); echo "PASS  $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "FAIL  $1${2:+  ($2)}"; }
check() { if [ "$1" = 0 ]; then ok "$2"; else bad "$2" "${3:-}"; fi; }
c() { curl -sS --max-time 25 $CURL_TLS "$@"; }

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
jwt_payload() { # $1 = JWT -> decoded payload JSON
  local p=${1#*.}; p=${p%%.*}; p=$(printf '%s' "$p" | tr '_-' '/+')
  case $(( ${#p} % 4 )) in 2) p="$p==" ;; 3) p="$p=" ;; esac
  printf '%s' "$p" | base64 -d 2>/dev/null
}
html_decode() { sed -e 's/&amp;/\&/g' -e 's/&#61;/=/g' -e 's/&quot;/"/g'; }
urlenc() { jq -rn --arg v "$1" '$v|@uri'; }
password_of() { local v="DEMO_$(printf '%s' "$1" | tr 'a-z' 'A-Z')_PASSWORD"; printf '%s' "${!v-}"; }

OIDC="$AUTH_URL/realms/$REALM/protocol/openid-connect"
REDIRECT="$APP_URL/swagger-ui/oauth2-redirect.html"
[ "$CLIENT" = prodflow-web ] && REDIRECT='http://localhost:4200/callback'
ORIGIN=$(printf '%s' "$APP_URL" | sed -E 's#^(https?://[^/]+).*#\1#')

# login <user> <password> -> sets LOGIN_RESULT (code|rejected|error:...), LOGIN_CODE, VERIFIER
login() {
  local user=$1 pw=$2 jar="$WORK/jar.$$.$RANDOM" state nonce challenge page action
  LOGIN_CODE=''; LOGIN_RESULT=''
  VERIFIER=$(openssl rand 48 | b64url)
  challenge=$(printf '%s' "$VERIFIER" | openssl dgst -sha256 -binary | b64url)
  state=$(openssl rand -hex 8); nonce=$(openssl rand -hex 8)
  page=$(c -c "$jar" -b "$jar" -G "$OIDC/auth" \
        --data-urlencode "client_id=$CLIENT" --data-urlencode "redirect_uri=$REDIRECT" --data-urlencode 'response_type=code' \
        --data-urlencode 'scope=openid' --data-urlencode "state=$state" --data-urlencode "nonce=$nonce" \
        --data-urlencode "code_challenge=$challenge" --data-urlencode 'code_challenge_method=S256' -w '\n%{http_code}') || { LOGIN_RESULT='error: authorization request failed'; return; }
  local status=${page##*$'\n'}; page=${page%$'\n'*}
  [ "$status" = 200 ] || { LOGIN_RESULT="error: authorization endpoint answered HTTP $status"; return; }
  action=$(printf '%s' "$page" | tr '\n' ' ' | sed -n 's/.*id="kc-form-login"[^>]*action="\([^"]*\)".*/\1/p' | html_decode)
  [ -n "$action" ] || { LOGIN_RESULT='error: no login form on the page'; return; }
  local headers="$WORK/h.$$.$RANDOM"
  c -c "$jar" -b "$jar" -D "$headers" -o "$WORK/body.$$" -X POST "$action" \
    --data-urlencode "username=$user" --data-urlencode "password=$pw" --data-urlencode 'credentialId=' >/dev/null || { LOGIN_RESULT='error: login post failed'; return; }
  local loc; loc=$(tr -d '\r' <"$headers" | sed -n 's/^[Ll]ocation: //p' | head -1)
  case "$loc" in
    "$REDIRECT"*) LOGIN_CODE=$(printf '%s' "$loc" | sed -n 's/.*[?&]code=\([^&]*\).*/\1/p')
                  [ "$(printf '%s' "$loc" | sed -n 's/.*[?&]state=\([^&]*\).*/\1/p')" = "$state" ] || { LOGIN_RESULT='error: state mismatch'; return; }
                  [ -n "$LOGIN_CODE" ] && LOGIN_RESULT=code || LOGIN_RESULT='error: no code in redirect' ;;
    '') if grep -qi 'invalid username or password' "$WORK/body.$$" 2>/dev/null; then LOGIN_RESULT=rejected; else LOGIN_RESULT='error: unexpected login answer'; fi ;;
    *) LOGIN_RESULT="error: redirected to an unexpected target" ;;
  esac
}

echo "== smoke-auth.sh: $AUTH_URL (client $CLIENT, realm $REALM)"
c -o /dev/null -w '%{http_code}' "$AUTH_URL/realms/$REALM/.well-known/openid-configuration" >"$WORK/wk.code"
check "$([ "$(cat "$WORK/wk.code")" = 200 ] && echo 0 || echo 1)" 'OIDC discovery document is served' "HTTP $(cat "$WORK/wk.code")"
ISS=$(c "$AUTH_URL/realms/$REALM/.well-known/openid-configuration" | jq -r .issuer 2>/dev/null)
check "$([ "$ISS" = "$AUTH_URL/realms/$REALM" ] && echo 0 || echo 1)" 'issuer equals the public realm URL (hostname/proxy configuration)'

IFS=',' read -r -a USER_LIST <<<"$USERS"
for user in "${USER_LIST[@]}"; do
  pw=$(password_of "$user")
  [ -n "$pw" ] || { bad "$user: password variable DEMO_$(printf '%s' "$user" | tr 'a-z' 'A-Z')_PASSWORD is not set"; continue; }
  login "$user" "$pw"
  if [ "$LOGIN_RESULT" != code ]; then bad "$user: Authorization Code + PKCE login" "$LOGIN_RESULT"; continue; fi
  ok "$user: Authorization Code + PKCE login without interruption"
  tok=$(c -D "$WORK/th" -X POST "$OIDC/token" -H "Origin: $ORIGIN" \
        --data-urlencode 'grant_type=authorization_code' --data-urlencode "client_id=$CLIENT" --data-urlencode "code=$LOGIN_CODE" \
        --data-urlencode "redirect_uri=$REDIRECT" --data-urlencode "code_verifier=$VERIFIER")
  at=$(printf '%s' "$tok" | jq -r '.access_token // empty'); rt=$(printf '%s' "$tok" | jq -r '.refresh_token // empty')
  [ -n "$at" ] || { bad "$user: token exchange" "$(printf '%s' "$tok" | jq -r '.error // "no access_token"')"; continue; }
  ok "$user: token exchange with the PKCE verifier"
  cors=$(tr -d '\r' <"$WORK/th" | sed -n 's/^[Aa]ccess-[Cc]ontrol-[Aa]llow-[Oo]rigin: //p')
  check "$([ "$cors" = "$ORIGIN" ] && echo 0 || echo 1)" "$user: token endpoint answers CORS for the app origin (Swagger UI)"
  claims=$(jwt_payload "$at")
  check "$([ "$(printf '%s' "$claims" | jq -r .iss)" = "$AUTH_URL/realms/$REALM" ] && echo 0 || echo 1)" "$user: iss claim is the public realm URL"
  check "$(printf '%s' "$claims" | jq -e '(.aud|tostring)|contains("prodflow-api")' >/dev/null 2>&1 && echo 0 || echo 1)" "$user: audience contains prodflow-api"
  want=$(printf '%s' "$user" | tr 'a-z' 'A-Z')
  check "$(printf '%s' "$claims" | jq -e --arg r "$want" '.realm_access.roles|index($r)' >/dev/null 2>&1 && echo 0 || echo 1)" "$user: realm role $want present"
  life=$(printf '%s' "$claims" | jq -r '.exp - .iat')
  check "$([ "$life" = "$LIFESPAN" ] && echo 0 || echo 1)" "$user: access token lifetime is $LIFESPAN s" "exp-iat=$life"
  if [ -n "$rt" ]; then
    r=$(c -X POST "$OIDC/token" --data-urlencode 'grant_type=refresh_token' --data-urlencode "client_id=$CLIENT" --data-urlencode "refresh_token=$rt")
    check "$([ -n "$(printf '%s' "$r" | jq -r '.access_token // empty')" ] && echo 0 || echo 1)" "$user: refresh-token exchange yields a new access token"
  else bad "$user: no refresh token issued"; fi
  if [ "$API" -eq 1 ]; then
    code=$(c -o /dev/null -w '%{http_code}' "$APP_URL/api/items")
    check "$([ "$code" = 401 ] && echo 0 || echo 1)" "$user: API without token -> 401" "HTTP $code"
    code=$(c -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $at" "$APP_URL/api/items")
    check "$([ "$code" = 200 ] && echo 0 || echo 1)" "$user: API with the real token -> 200" "HTTP $code"
    code=$(c -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $at" "$APP_URL/api/purchase-requests/999999/approve")
    case "$user" in
      planner) exp=403 ;; purchaser|admin) exp=404 ;; *) exp='' ;;
    esac
    [ -z "$exp" ] || check "$([ "$code" = "$exp" ] && echo 0 || echo 1)" "$user: purchase approval -> $exp (role rule; 404 = authorized, request does not exist)" "HTTP $code"
  fi
  login "$user" '${DEMO_'"$(printf '%s' "$user" | tr 'a-z' 'A-Z')"'_PASSWORD}'
  check "$([ "$LOGIN_RESULT" = rejected ] && echo 0 || echo 1)" "$user: the literal placeholder text is not accepted as a password" "$LOGIN_RESULT"
done

echo "smoke-auth.sh result: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
