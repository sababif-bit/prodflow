#!/usr/bin/env bash
# Scripted run of the demo workflow against a running ProdFlow (Issues #9/#19): production order MR-200 x10 -> material shortage ->
# ONE purchase request (SC-M8, 15) -> planner may NOT approve (403) -> purchaser approves and receives -> order released -> planner completes
# -> final stock. Uses real Keycloak logins (Authorization Code + PKCE) and the real API with real tokens.
#
# PRECONDITION: the demo baseline (run scripts/reset-demo-data.sh first). The run CONSUMES the baseline (creates order FA-00001 and
# changes stock), so it refuses to start if the baseline is not intact (exit 3) and tells you to reset.
#
#   DEMO_PLANNER_PASSWORD=... DEMO_PURCHASER_PASSWORD=... scripts/demo-run.sh --auth-url https://auth.example.org --app-url https://app.example.org
#   options: --client prodflow-swagger  --insecure-local (only hosts *.test / *.localhost)  --realm prodflow
# Exit: 0 = workflow behaved exactly as specified, 1 = a check failed, 2 = usage/precondition (tools, login), 3 = baseline not intact.
set -u
AUTH_URL=''; APP_URL=''; CLIENT=prodflow-swagger; REALM=prodflow; INSECURE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --auth-url) AUTH_URL=${2%/}; shift 2 ;;
    --app-url) APP_URL=${2%/}; shift 2 ;;
    --client) CLIENT=$2; shift 2 ;;
    --realm) REALM=$2; shift 2 ;;
    --insecure-local) INSECURE=1; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[ -n "$AUTH_URL" ] && [ -n "$APP_URL" ] || { echo "usage: --auth-url <url> --app-url <url>" >&2; exit 2; }
for t in curl openssl jq sed tr base64; do command -v "$t" >/dev/null 2>&1 || { echo "missing tool: $t" >&2; exit 2; }; done
case "$AUTH_URL" in https://*|http://localhost*|http://127.0.0.1*) ;; *) echo "refusing to send credentials over plain HTTP" >&2; exit 2 ;; esac
CURL_TLS=''
if [ "$INSECURE" = 1 ]; then
  case "$(printf '%s' "$AUTH_URL" | sed -E 's#^https?://([^/:]+).*#\1#')" in *.test|*.localhost|localhost) CURL_TLS='-k' ;; *) echo "--insecure-local only for *.test / *.localhost" >&2; exit 2 ;; esac
fi
WORK=$(mktemp -d) || exit 2; chmod 700 "$WORK"; trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL  $1${2:+  ($2)}"; }
check() { if [ "$1" = 0 ]; then ok "$2"; else bad "$2" "${3:-}"; fi; }
. "$(dirname "$0")/lib/oidc.sh" || exit 2
OIDC="$AUTH_URL/realms/$REALM/protocol/openid-connect"
REDIRECT="$APP_URL/swagger-ui/oauth2-redirect.html"
START=$SECONDS

get_token planner "${DEMO_PLANNER_PASSWORD-}" || { echo "planner login failed: $LOGIN_RESULT" >&2; exit 2; }; PLANNER=$ACCESS_TOKEN
get_token purchaser "${DEMO_PURCHASER_PASSWORD-}" || { echo "purchaser login failed: $LOGIN_RESULT" >&2; exit 2; }; PURCHASER=$ACCESS_TOKEN
# api <token> <METHOD> <path> [json-body] -> sets HTTP (status) and BODY
api() {
  local tok=$1 method=$2 path=$3 body=${4-} args=()
  [ -n "$body" ] && args=(-H 'Content-Type: application/json' --data "$body")
  BODY=$(c -o - -w '\n%{http_code}' -X "$method" -H "Authorization: Bearer $tok" "${args[@]}" "$APP_URL$path")
  HTTP=${BODY##*$'\n'}; BODY=${BODY%$'\n'*}
}
stock() { printf '%s' "$ITEMS" | jq -r --arg c "$1" '.[] | select(.code==$c) | .qtyOnHand | floor'; }
itemid() { printf '%s' "$ITEMS" | jq -r --arg c "$1" '.[] | select(.code==$c) | .id'; }

echo "== precondition: demo baseline"
api "$PLANNER" GET /api/items; ITEMS=$BODY
[ "$HTTP" = 200 ] || { echo "cannot read items (HTTP $HTTP)" >&2; exit 2; }
api "$PLANNER" GET /api/production-orders; ORDERS=$BODY
api "$PLANNER" GET /api/purchase-requests; REQS=$BODY
base=1
[ "$(stock MR-200)" = 0 ] && [ "$(stock SC-M8)" = 25 ] && [ "$(stock PL-ST3)" = 30 ] && [ "$(stock PR-40)" = 50 ] && [ "$(stock BR-L60)" = 100 ] || base=0
[ "$(printf '%s' "$ORDERS" | jq length)" = 0 ] && [ "$(printf '%s' "$REQS" | jq length)" = 0 ] || base=0
if [ "$base" != 1 ]; then echo "REFUSED: the demo baseline is not intact (stock differs or orders/purchase requests exist). Run scripts/reset-demo-data.sh first." >&2; exit 3; fi
ok 'baseline intact: MR-200 0, SC-M8 25, PL-ST3 30, PR-40 50, BR-L60 100, no orders, no purchase requests'

echo "== 1-2: planner creates the production order MR-200 x 10"
due=$(date -u -d "@$(( $(date +%s) + 14 * 86400 ))" +%F)
api "$PLANNER" POST /api/production-orders "{\"productId\": $(itemid MR-200), \"quantity\": 10, \"dueDate\": \"$due\"}"
check $([ "$HTTP" = 201 ] || [ "$HTTP" = 200 ] && echo 0 || echo 1) 'order created' "HTTP $HTTP"
ORDER_ID=$(printf '%s' "$BODY" | jq -r .orderId)
check $([ "$(printf '%s' "$BODY" | jq -r .status)" = WAITING_MATERIAL ] && echo 0 || echo 1) 'status WAITING_MATERIAL (material shortage)'
check $([ "$(printf '%s' "$BODY" | jq -r '[.lines[] | select(.shortage > 0)] | length')" = 1 ] && [ "$(printf '%s' "$BODY" | jq -r '.lines[] | select(.itemCode=="SC-M8") | .shortage | floor')" = 15 ] && echo 0 || echo 1) 'exactly one shortage: SC-M8 short by 15 (required 40, available 25)'
api "$PLANNER" GET "/api/production-orders/$ORDER_ID"
check $([ "$(printf '%s' "$BODY" | jq -r .orderNo)" = FA-00001 ] && echo 0 || echo 1) 'the first order number is FA-00001' "$(printf '%s' "$BODY" | jq -r .orderNo)"

echo "== 3: exactly one purchase request"
api "$PURCHASER" GET /api/purchase-requests; REQS=$BODY
check $([ "$(printf '%s' "$REQS" | jq length)" = 1 ] && [ "$(printf '%s' "$REQS" | jq -r '.[0].itemCode')" = SC-M8 ] && [ "$(printf '%s' "$REQS" | jq -r '.[0].quantity | floor')" = 15 ] && [ "$(printf '%s' "$REQS" | jq -r '.[0].status')" = OPEN ] && echo 0 || echo 1) 'one OPEN purchase request: SC-M8, quantity 15'
REQ_ID=$(printf '%s' "$REQS" | jq -r '.[0].id')

echo "== 4: separation of duties"
api "$PLANNER" POST "/api/purchase-requests/$REQ_ID/approve"
check $([ "$HTTP" = 403 ] && echo 0 || echo 1) 'planner approving the purchase request -> 403' "HTTP $HTTP"
api "$PLANNER" GET /api/purchase-requests
check $([ "$(printf '%s' "$BODY" | jq -r '.[0].status')" = OPEN ] && echo 0 || echo 1) 'the request is still OPEN after the refused approval'

echo "== 5-6: purchaser approves and receives the goods"
api "$PURCHASER" POST "/api/purchase-requests/$REQ_ID/approve"
check $([ "$HTTP" = 200 ] && [ "$(printf '%s' "$BODY" | jq -r .status)" = APPROVED ] && echo 0 || echo 1) 'purchaser approves -> APPROVED' "HTTP $HTTP"
api "$PURCHASER" POST "/api/purchase-requests/$REQ_ID/receive"
check $([ "$HTTP" = 200 ] && [ "$(printf '%s' "$BODY" | jq -r .status)" = RECEIVED ] && echo 0 || echo 1) 'purchaser receives the goods -> RECEIVED' "HTTP $HTTP"
api "$PLANNER" GET "/api/production-orders/$ORDER_ID"
check $([ "$(printf '%s' "$BODY" | jq -r .status)" = RELEASED ] && echo 0 || echo 1) 'goods receipt released the waiting order automatically' "$(printf '%s' "$BODY" | jq -r .status)"

echo "== 7-8: planner completes the order; final stock"
api "$PLANNER" POST "/api/production-orders/$ORDER_ID/complete"
check $([ "$HTTP" = 200 ] && [ "$(printf '%s' "$BODY" | jq -r .status)" = DONE ] && echo 0 || echo 1) 'planner completes -> DONE' "HTTP $HTTP"
api "$PLANNER" GET /api/items; ITEMS=$BODY
final="MR-200 $(stock MR-200), SC-M8 $(stock SC-M8), PL-ST3 $(stock PL-ST3), PR-40 $(stock PR-40), BR-L60 $(stock BR-L60)"
check $([ "$final" = "MR-200 10, SC-M8 0, PL-ST3 10, PR-40 15, BR-L60 20" ] && echo 0 || echo 1) 'final stock: MR-200 10, SC-M8 0, PL-ST3 10, PR-40 15, BR-L60 20' "$final"
api "$PLANNER" GET /api/purchase-requests
check $([ "$(printf '%s' "$BODY" | jq length)" = 1 ] && echo 0 || echo 1) 'still exactly one purchase request overall'

echo "demo-run: $((SECONDS - START)) s"
echo "demo-run result: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
