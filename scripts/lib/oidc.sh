#!/usr/bin/env bash
# Shared helpers for the bash OIDC checks (smoke-auth.sh, demo-run.sh): browser-style Authorization Code + PKCE S256 login against
# Keycloak with curl (no password grant). Callers set before use: OIDC (realm openid-connect base URL), CLIENT, REDIRECT, WORK (temp dir),
# CURL_TLS (empty, or -k for local test hosts). Nothing secret is printed; callers must not print tokens either.

c() { curl -sS --max-time 25 $CURL_TLS "$@"; }

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
jwt_payload() { # $1 = JWT -> decoded payload JSON
  local p=${1#*.}; p=${p%%.*}; p=$(printf '%s' "$p" | tr '_-' '/+')
  case $(( ${#p} % 4 )) in 2) p="$p==" ;; 3) p="$p=" ;; esac
  printf '%s' "$p" | base64 -d 2>/dev/null
}
html_decode() { sed -e 's/&amp;/\&/g' -e 's/&#61;/=/g' -e 's/&quot;/"/g'; }
urlenc() { jq -rn --arg v "$1" '$v|@uri'; }

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

# get_token <user> <password>: login + code exchange. Sets ACCESS_TOKEN and REFRESH_TOKEN; returns 0 on success, 1 otherwise (LOGIN_RESULT explains).
get_token() {
  ACCESS_TOKEN=''; REFRESH_TOKEN=''
  login "$1" "$2"; [ "$LOGIN_RESULT" = code ] || return 1
  local tok
  tok=$(c -X POST "$OIDC/token" --data-urlencode 'grant_type=authorization_code' --data-urlencode "client_id=$CLIENT" \
        --data-urlencode "code=$LOGIN_CODE" --data-urlencode "redirect_uri=$REDIRECT" --data-urlencode "code_verifier=$VERIFIER")
  ACCESS_TOKEN=$(printf '%s' "$tok" | jq -r '.access_token // empty')
  REFRESH_TOKEN=$(printf '%s' "$tok" | jq -r '.refresh_token // empty')
  [ -n "$ACCESS_TOKEN" ] || { LOGIN_RESULT='error: token exchange failed'; return 1; }
}
