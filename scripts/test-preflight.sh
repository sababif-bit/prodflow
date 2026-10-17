#!/usr/bin/env bash
# Unit test of deploy/preflight.sh with fake docker/curl/getent binaries (no network, no Docker). Run: scripts/test-preflight.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
PRE="$HERE/../deploy/preflight.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; mkdir "$T/bin"
PASS=0; FAIL=0
check() { if [ "$1" = 0 ]; then PASS=$((PASS + 1)); echo "PASS  $2"; else FAIL=$((FAIL + 1)); echo "FAIL  $2${3:+  ($3)}"; fi; }

cat >"$T/bin/docker" <<'EOF'
#!/usr/bin/env bash
[ "$1 $2" = "manifest inspect" ] || exit 9
[ -e "$(dirname "$0")/image_missing" ] && exit 1
exit 0
EOF
cat >"$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
[ -e "$(dirname "$0")/no_ip" ] && exit 22
cat "$(dirname "$0")/myip" 2>/dev/null || echo "203.0.113.7"
EOF
cat >"$T/bin/getent" <<'EOF'
#!/usr/bin/env bash
# getent ahostsv4 <host>: answer from files named after the host; missing file = no answer
f="$(dirname "$0")/dns_$2"; [ -e "$f" ] && echo "$(cat "$f")      STREAM $2"
exit 0
EOF
chmod +x "$T/bin/"*
run() { PATH="$T/bin:$PATH" DNS_WAIT_TRIES=2 DNS_WAIT_SECONDS=0 bash "$PRE" "$@" 2>&1; }

out=$(run image ghcr.io/x/y:sha-abc1234); check $([ $? -eq 0 ] && echo 0 || echo 1) 'existing image tag passes'
touch "$T/bin/image_missing"; out=$(run image ghcr.io/x/y:sha-nope); rc=$?
check $([ $rc -eq 1 ] && printf '%s' "$out" | grep -q 'cannot be found' && echo 0 || echo 1) 'missing image tag fails with a clear message' "exit $rc"
rm "$T/bin/image_missing"

echo 203.0.113.7 >"$T/bin/dns_app.example.org"; echo 203.0.113.7 >"$T/bin/dns_auth.example.org"
out=$(run dns app.example.org auth.example.org); rc=$?
check $([ $rc -eq 0 ] && printf '%s' "$out" | grep -q 'auth.example.org -> 203.0.113.7' && echo 0 || echo 1) 'both names resolve to this server -> ok' "exit $rc"
echo 198.51.100.9 >"$T/bin/dns_auth.example.org"; out=$(run dns app.example.org auth.example.org); rc=$?
check $([ $rc -eq 1 ] && printf '%s' "$out" | grep -q "auth.example.org resolves to '198.51.100.9'" && echo 0 || echo 1) 'a name pointing at another IP fails and names both addresses' "exit $rc"
rm "$T/bin/dns_auth.example.org"; out=$(run dns app.example.org auth.example.org); rc=$?
check $([ $rc -eq 1 ] && printf '%s' "$out" | grep -q "resolves to 'nothing'" && echo 0 || echo 1) 'a name that does not resolve yet fails' "exit $rc"
touch "$T/bin/no_ip"; out=$(run dns app.example.org); rc=$?
check $([ $rc -eq 1 ] && printf '%s' "$out" | grep -q 'cannot determine' && echo 0 || echo 1) 'unknown own public IP fails closed' "exit $rc"
rm "$T/bin/no_ip"; out=$(PUBLIC_IP=203.0.113.7 PATH="$T/bin:$PATH" bash "$PRE" dns app.example.org 2>&1); rc=$?
check $([ $rc -eq 0 ] && echo 0 || echo 1) 'PUBLIC_IP override is honoured' "exit $rc"
# DNS that becomes correct on the second try is accepted
rm "$T/bin/dns_app.example.org"
( sleep 0.3; echo 203.0.113.7 >"$T/bin/dns_app.example.org" ) &
out=$(PATH="$T/bin:$PATH" DNS_WAIT_TRIES=30 DNS_WAIT_SECONDS=0.1 bash "$PRE" dns app.example.org 2>&1); rc=$?
check $([ $rc -eq 0 ] && echo 0 || echo 1) 'DNS that appears while waiting is accepted' "exit $rc"
out=$(run); rc=$?; check $([ $rc -eq 2 ] && echo 0 || echo 1) 'no mode -> usage error' "exit $rc"

# --- bootstrap-server.sh wiring (it needs root + apt, so its order is pinned statically): it must stop BEFORE secrets are generated if the
# --- image is missing, and BEFORE the stack/Caddy starts if DuckDNS or DNS is wrong.
BS="$HERE/../deploy/bootstrap-server.sh"
ln() { grep -n -- "$1" "$BS" | head -1 | cut -d: -f1; }
l_strict=$(ln '^set -euo pipefail'); l_img=$(ln 'preflight.sh" image'); l_env=$(ln 'deploy/.env (secrets generated here)')
l_duck=$(ln 'duckdns-update.sh'); l_dns=$(ln 'preflight.sh" dns'); l_start=$(ln 'deploy.sh" "$IMAGE_TAG"')
check $([ -n "$l_strict" ] && [ -n "$l_img" ] && [ -n "$l_dns" ] && [ -n "$l_start" ] && echo 0 || echo 1) 'bootstrap calls preflight image and dns and deploy.sh'
check $([ "$l_strict" -lt "$l_img" ] && [ "$l_img" -lt "$l_env" ] && echo 0 || echo 1) 'strict mode first; image check runs before any secret is generated' "$l_strict/$l_img/$l_env"
check $([ "$l_env" -lt "$l_duck" ] && [ "$l_duck" -lt "$l_dns" ] && [ "$l_dns" -lt "$l_start" ] && echo 0 || echo 1) 'DuckDNS update, then DNS check, then the stack is started' "$l_duck/$l_dns/$l_start"
check $(sed -n "${l_duck}p" "$BS" | grep -q 'exit 1' && echo 0 || echo 1) 'a failed DuckDNS update aborts the bootstrap'
check $(sed -n "$((l_dns - 3)),${l_dns}p" "$BS" | grep -q 'SKIP_DNS_CHECK' && echo 0 || echo 1) 'the DNS check can only be skipped explicitly (SKIP_DNS_CHECK=1)'
echo "test-preflight result: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
