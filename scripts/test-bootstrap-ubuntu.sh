#!/usr/bin/env bash
# Dry run of the REAL first-deployment bootstrap on a clean Ubuntu 24.04 (Issue #17), inside a disposable container that is limited like the
# planned EC2 t3.small: 2 GiB RAM + 2 GiB swap. The container runs its own Docker daemon (privileged, own volume), so the real steps run:
# apt packages, Docker + Compose plugin installation, repository clone, pre-flight against the real registry (anonymous GHCR), generation of
# deploy/.env with random secrets, start of the whole stack with the REAL published backend image, health gate, agent run.
# Stubbed (cannot work without a VM/the internet service): systemd (starts dockerd instead), swapon/fallocate/mkswap, the DuckDNS API call
# (a fake token is used; the stub logs only the names), the DNS pre-flight (SKIP_DNS_CHECK, unit-tested separately) and Let's Encrypt
# (TLS_DIRECTIVE='tls internal' with test names). It never contacts the real DuckDNS names, never uses a real token, never touches AWS,
# the development stack, or any .env file. The repository is cloned from the committed HEAD of this checkout (commit before running).
# Run: scripts/test-bootstrap-ubuntu.sh        Exit: 0 = all passed, 1 = a check failed, 3 = pre-check failed
set -u
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && { pwd -W 2>/dev/null || pwd; })
C=prodflow-bootcheck; VOL=prodflow-bootcheck-docker
APP=app-bootcheck.duckdns.org; AUTH=auth-bootcheck.duckdns.org
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL  $1${2:+  ($2)}"; }
check() { if [ "$1" = 0 ]; then ok "$2"; else bad "$2" "${3:-}"; fi; }
WORK=$(mktemp -d); WORK_N=$(cd "$WORK" && { pwd -W 2>/dev/null || pwd; })
cleanup() { [ -n "${SAMPLER:-}" ] && kill "$SAMPLER" >/dev/null 2>&1; docker rm -f $C >/dev/null 2>&1; docker volume rm $VOL >/dev/null 2>&1; rm -rf "$WORK"; }
trap cleanup EXIT
inc() { docker exec -e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=safe.directory -e 'GIT_CONFIG_VALUE_0=*' \
         -e PATH=/stubs:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin "$@"; }

docker version >/dev/null 2>&1 || { echo "pre-check failed: Docker not available"; exit 3; }
[ -z "$(docker ps -aq --filter "name=^$C\$")" ] || { echo "pre-check failed: container $C exists"; exit 3; }
git -C "$HERE/.." diff --quiet HEAD -- deploy keycloak docker-compose.yml 2>/dev/null || echo "NOTE: uncommitted changes under deploy/ are NOT part of this test (the bootstrap clones the committed HEAD)"
STACK_BEFORE=$(docker ps -a --filter 'label=com.docker.compose.project=prodflow' --format '{{.ID}}' | sort | tr '\n' ' ')
docker pull -q ghcr.io/sababif-bit/prodflow:prod >/dev/null 2>&1
REV=$(docker inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' ghcr.io/sababif-bit/prodflow:prod 2>/dev/null)
[[ $REV =~ ^[0-9a-f]{40}$ ]] || { echo "pre-check failed: cannot read the revision of the published prod image"; exit 3; }
TAG="sha-${REV:0:7}"

# ---- stubs ----
mkdir -p "$WORK/stubs"
cat >"$WORK/stubs/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >>/var/log/systemctl-stub.log
case "$*" in
  *"enable --now docker"*)
    if [ ! -S /var/run/docker.sock ]; then
      # nested cgroup v2 (same preparation as the official docker:dind image): move all processes out of the root cgroup, delegate controllers
      if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
        mkdir -p /sys/fs/cgroup/init
        xargs -rn1 </sys/fs/cgroup/cgroup.procs >/sys/fs/cgroup/init/cgroup.procs 2>/dev/null || true
        sed -e 's/ / +/g' -e 's/^/+/' </sys/fs/cgroup/cgroup.controllers >/sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true
      fi
      (nohup dockerd >/var/log/dockerd.log 2>&1 &)
      for _ in $(seq 1 90); do docker info >/dev/null 2>&1 && break; sleep 1; done
    fi ;;
esac
exit 0
EOF
cat >"$WORK/stubs/swapon" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$WORK/stubs/fallocate" <<'EOF'
#!/usr/bin/env bash
touch "${@: -1}"
EOF
printf '#!/usr/bin/env bash\nexit 0\n' >"$WORK/stubs/mkswap"
cat >"$WORK/stubs/curl" <<'EOF'
#!/usr/bin/env bash
# DuckDNS API stub: answers OK and logs only the NAMES (the config on stdin contains the token, which is never logged).
if [[ " $* " == *" -K - "* ]]; then
  cfg=$(cat)
  if grep -q 'www.duckdns.org' <<<"$cfg"; then
    echo "duckdns-stub $(grep -o 'domains=[^&]*' <<<"$cfg")" >>/var/log/duckdns-stub.log
    echo OK; exit 0
  fi
  printf '%s\n' "$cfg" | exec /usr/bin/curl "$@"
fi
exec /usr/bin/curl "$@"
EOF
chmod +x "$WORK/stubs/"*

echo "== start the clean Ubuntu 24.04 'server' (2 GiB RAM + 2 GiB swap, own Docker daemon)"
docker run -d --name $C --privileged --memory 2g --memory-swap 4g -v $VOL:/var/lib/docker -v "$REPO:/src:ro" -v "$WORK_N/stubs:/stubs:ro" ubuntu:24.04 sleep infinity >/dev/null
check $? 'container started'
check $([ "$(docker exec $C sh -c '. /etc/os-release; echo $VERSION_ID')" = 24.04 ] && echo 0 || echo 1) 'the base image is Ubuntu 24.04'
check $([ "$(docker exec $C sh -c 'command -v docker || echo none')" = none ] && echo 0 || echo 1) 'Docker is NOT preinstalled (the bootstrap must install it)'
( while :; do docker stats --no-stream --format '{{.MemUsage}}' $C 2>/dev/null | awk '{v=$1;u=v;gsub(/[0-9.]/,"",u);n=v;gsub(/[A-Za-z]/,"",n);if(u=="GiB")n*=1024;print n}'; sleep 2; done ) >"$WORK/outer-mem.log" &
SAMPLER=$!

echo "== bootstrap (real script, committed HEAD of this checkout)"
inc -e REPO_URL=file:///src -e APP_HOST=$APP -e AUTH_HOST=$AUTH -e IMAGE_TAG="$TAG" -e DUCKDNS_TOKEN=FAKE-TEST-TOKEN-NOT-SECRET \
   -e SKIP_DNS_CHECK=1 -e DEPLOY_SKIP_GIT=1 -e "TLS_DIRECTIVE=tls internal" -e DEPLOY_TIMEOUT=420 \
   $C bash /src/deploy/bootstrap-server.sh >"$WORK/bootstrap.log" 2>&1
rc=$?
check $([ $rc -eq 0 ] && echo 0 || echo 1) 'bootstrap exits 0' "exit $rc"
[ $rc -eq 0 ] || { echo "---- last lines of the bootstrap output:"; tail -25 "$WORK/bootstrap.log" | cut -c1-200; docker exec $C tail -5 /var/log/dockerd.log 2>/dev/null; }
for marker in 'packages and Docker' 'swap' 'repository' 'pre-flight: image tag exists' 'preflight: image' 'deploy/.env' 'DuckDNS' 'start the stack' 'deployment agent' 'is healthy'; do
  check $(grep -q "$marker" "$WORK/bootstrap.log" && echo 0 || echo 1) "bootstrap step reached: $marker"
done
check $(inc $C docker compose version >/dev/null 2>&1 && echo 0 || echo 1) 'Docker Compose plugin is installed and works'
check $([ "$(inc $C stat -c '%a %U' /opt/prodflow/repo/deploy/.env)" = '600 root' ] && echo 0 || echo 1) 'deploy/.env has mode 600 and is owned by root'
keys=$(inc $C sed -n 's/=.*//p' /opt/prodflow/repo/deploy/.env | sort | tr '\n' ' ')
want="APP_HOST APP_URL AUTH_HOST AUTH_URL BACKEND_IMAGE DEMO_ADMIN_PASSWORD DEMO_PLANNER_PASSWORD DEMO_PURCHASER_PASSWORD DUCKDNS_TOKEN IMAGE_TAG KC_BOOTSTRAP_ADMIN_PASSWORD KC_BOOTSTRAP_ADMIN_USERNAME KEYCLOAK_DB_NAME KEYCLOAK_DB_PASSWORD KEYCLOAK_DB_USER PRODFLOW_DB_PASSWORD TLS_DIRECTIVE "
check $([ "$keys" = "$want" ] && echo 0 || echo 1) 'deploy/.env has exactly the expected variables' "$keys"
check $([ "$(inc $C sh -c "tr -cd '\015' </opt/prodflow/repo/deploy/.env | wc -c" | tr -d ' \015')" = 0 ] && echo 0 || echo 1) 'deploy/.env contains no carriage return'
check $(grep -q 'FAKE-TEST-TOKEN' "$WORK/bootstrap.log" && echo 1 || echo 0) 'the token never appears in the bootstrap output'
check $(inc $C sh -c 'grep -q "domains=app-bootcheck,auth-bootcheck" /var/log/duckdns-stub.log' && echo 0 || echo 1) 'DuckDNS update was called for exactly the two names (stub)'
check $(inc $C sh -c 'grep -q FAKE-TEST /var/log/duckdns-stub.log' && echo 1 || echo 0) 'the token is not in the stub log either'
check $(inc $C sh -c 'docker compose --env-file /opt/prodflow/repo/deploy/.env -f /opt/prodflow/repo/deploy/docker-compose.prod.yml config --quiet' >/dev/null 2>&1 && echo 0 || echo 1) 'docker compose config accepts the generated .env'
check $(inc $C sh -c 'test -f /etc/systemd/system/prodflow-agent.timer && grep -q "enable --now prodflow-agent.timer" /var/log/systemctl-stub.log' && echo 0 || echo 1) 'agent unit installed and its timer enabled'

echo "== the stack runs with the real published image"
states=$(inc $C docker ps -a --format '{{.Names}}={{.State}}' | sort | tr '\n' ' ')
for s in caddy backend keycloak db keycloak-db; do check $(printf '%s' "$states" | grep -q "prodflow-prod-$s-1=running" && echo 0 || echo 1) "service $s is running"; done
check $(printf '%s' "$states" | grep -q 'keycloak-import-guard-1=exited' && echo 0 || echo 1) 'import guard ran once and exited'
check $([ "$(inc $C docker inspect --format '{{.State.ExitCode}}' prodflow-prod-keycloak-import-guard-1)" = 0 ] && echo 0 || echo 1) 'import guard exit code 0'
inc $C sh -c 'docker cp prodflow-prod-caddy-1:/data/caddy/pki/authorities/local/root.crt /tmp/caddy-root.crt' >/dev/null 2>&1
inc $C sh -c "echo '127.0.0.1 $APP $AUTH' >>/etc/hosts"   # the test names point at the box itself (Caddy publishes 443 there)
check $([ -s "$WORK/none" ] && echo 1 || echo 0) 'test names resolve to the box (hosts entry)'
check $(inc $C sh -c "test -s /tmp/caddy-root.crt" && echo 0 || echo 1) "Caddy's internal CA certificate was extracted for trust"
jsonq() { inc $C sh -c "CURL_CA_BUNDLE=/tmp/caddy-root.crt curl -sS --max-time 20 $1 | jq -r $2" 2>/dev/null | tr -d '\015'; }   # jq exists in the box, not on the Windows host
https() { inc $C sh -c "echo '127.0.0.1 $APP $AUTH' >>/etc/hosts 2>/dev/null; CURL_CA_BUNDLE=/tmp/caddy-root.crt curl -sS --max-time 20 $*"; }
ver=$(jsonq "https://$APP/version" .revision)
check $([ "$ver" = "$REV" ] && echo 0 || echo 1) 'GET /version over HTTPS returns the published image revision' "${ver:0:7} vs ${REV:0:7}"
check $([ "$(jsonq "https://$APP/actuator/health" .status)" = UP ] && echo 0 || echo 1) '/actuator/health is UP over HTTPS (certificate trusted via Caddy CA)'
check $([ "$(https "-o /dev/null -w %{http_code} https://$AUTH/admin/")" = 404 ] && echo 0 || echo 1) 'Keycloak admin console is not public'
echo "   waiting for the Keycloak realm (single Keycloak start on 2 GiB)..."
kc=1; for _ in $(seq 1 60); do [ "$(https "-o /dev/null -w %{http_code} https://$AUTH/realms/prodflow/.well-known/openid-configuration")" = 200 ] && { kc=0; break; }; sleep 5; done
check $kc 'Keycloak realm prodflow is served over HTTPS'
docker cp "$HERE/smoke-auth.sh" $C:/tmp/smoke-auth.sh >/dev/null 2>&1
[ -d "$HERE/lib" ] && docker cp "$HERE/lib" $C:/tmp/lib >/dev/null 2>&1   # shared login library, present once the demo-reset PR is merged
inc $C sh -c "set -a; . /opt/prodflow/repo/deploy/.env; set +a; echo '127.0.0.1 $APP $AUTH' >>/etc/hosts; CURL_CA_BUNDLE=/tmp/caddy-root.crt bash /tmp/smoke-auth.sh --auth-url https://$AUTH --app-url https://$APP" >"$WORK/smoke.log" 2>&1
check $? 'smoke-auth.sh passes against the bootstrapped stack (real logins, API, roles)' "$(grep -c '^FAIL' "$WORK/smoke.log") FAIL lines"

echo "== agent and repeatability"
inc $C bash /opt/prodflow/repo/deploy/agent.sh >"$WORK/agent.log" 2>&1; rc=$?
check $([ $rc -eq 0 ] && echo 0 || echo 1) 'agent run exits 0 (the running tag equals the prod image: nothing to do)' "exit $rc: $(tail -2 "$WORK/agent.log" | tr '\n' ' ')"
sum1=$(inc $C sha256sum /opt/prodflow/repo/deploy/.env | cut -c1-16)
inc -e REPO_URL=file:///src -e APP_HOST=$APP -e AUTH_HOST=$AUTH -e IMAGE_TAG=sha-0000000 -e DUCKDNS_TOKEN=FAKE-TEST-TOKEN-NOT-SECRET -e SKIP_DNS_CHECK=1 -e DEPLOY_SKIP_GIT=1 \
   $C bash /src/deploy/bootstrap-server.sh >"$WORK/bad.log" 2>&1; rc=$?
check $([ $rc -ne 0 ] && grep -q 'cannot be found in the registry' "$WORK/bad.log" && echo 0 || echo 1) 'a bootstrap with a nonexistent image tag fails early with a clear message' "exit $rc"
check $([ "$(inc $C sha256sum /opt/prodflow/repo/deploy/.env | cut -c1-16)" = "$sum1" ] && echo 0 || echo 1) '...and leaves the existing .env untouched'
check $([ "$(inc $C docker inspect --format '{{.State.Health.Status}}' prodflow-prod-backend-1)" = healthy ] && echo 0 || echo 1) '...and the running stack stays healthy'
inc -e REPO_URL=file:///src -e APP_HOST=$APP -e AUTH_HOST=$AUTH -e IMAGE_TAG="$TAG" -e DUCKDNS_TOKEN=FAKE-TEST-TOKEN-NOT-SECRET -e SKIP_DNS_CHECK=1 -e DEPLOY_SKIP_GIT=1 \
   $C bash /src/deploy/bootstrap-server.sh >"$WORK/rerun.log" 2>&1; rc=$?
check $([ $rc -eq 0 ] && [ "$(inc $C sha256sum /opt/prodflow/repo/deploy/.env | cut -c1-16)" = "$sum1" ] && echo 0 || echo 1) 'running the bootstrap again is idempotent (exit 0, .env unchanged)' "exit $rc"

echo "== memory on the 2 GiB box"
kill "$SAMPLER" >/dev/null 2>&1; SAMPLER=''
peak=$(sort -n "$WORK/outer-mem.log" | tail -1)
echo "   whole 'server' container peak: ${peak} MiB of 2048 MiB RAM (limit includes dockerd, page cache and everything)"
inc $C free -m | sed 's/^/   /'
inc $C docker stats --no-stream --format '   {{.Name}}: {{.MemUsage}}' | sed 's/prodflow-prod-//'
check $([ "$(docker inspect --format '{{.State.OOMKilled}}' $C)" = false ] && echo 0 || echo 1) 'the 2 GiB container was not OOM-killed'
oom=0; restarts=0; for x in $(inc $C docker ps -aq); do [ "$(inc $C docker inspect --format '{{.State.OOMKilled}}' "$x")" = true ] && oom=1; restarts=$((restarts + $(inc $C docker inspect --format '{{.RestartCount}}' "$x"))); done
check $oom 'no service container was OOM-killed'
check $([ "$restarts" = 0 ] && echo 0 || echo 1) 'no service container had to restart' "restarts=$restarts"

cleanup; trap - EXIT
check $([ -z "$(docker ps -aq --filter "name=^$C\$")" ] && [ -z "$(docker volume ls -q --filter "name=^$VOL\$")" ] && echo 0 || echo 1) 'test container and volume removed'
check $([ "$STACK_BEFORE" = "$(docker ps -a --filter 'label=com.docker.compose.project=prodflow' --format '{{.ID}}' | sort | tr '\n' ' ')" ] && echo 0 || echo 1) 'development stack containers unchanged'
echo "test-bootstrap-ubuntu result: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
