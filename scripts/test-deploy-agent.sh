#!/usr/bin/env bash
# Unit test of deploy/agent.sh and deploy/deploy.sh with fake docker/git/flock binaries (no Docker, no network, no server).
# Verifies: no-op when nothing changed, deploy of a new revision, health-gated rollback, "failed" memory, newer image after a failure,
# registry errors, invalid labels/tags, and that replacing the scripts during a deployment (git checkout) cannot corrupt the run.
# Run: scripts/test-deploy-agent.sh      Exit: 0 = all passed, 1 = a check failed
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
DEPLOY="$HERE/../deploy"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL  $1${2:+  ($2)}"; }
check() { if [ "$1" = 0 ]; then ok "$2"; else bad "$2" "${3:-}"; fi; }

SHA_OLD=aaaaaaa1111111111111111111111111111111aa
SHA_NEW=bbbbbbb2222222222222222222222222222222bb
SHA_NEWER=ccccccc3333333333333333333333333333333cc

setup() { # fresh fake server tree
  rm -rf "$T/srv" "$T/bin" "$T/state"; mkdir -p "$T/srv/repo/deploy" "$T/bin" "$T/state"
  cp "$DEPLOY/agent.sh" "$DEPLOY/deploy.sh" "$T/srv/repo/deploy/"
  printf 'BACKEND_IMAGE=ghcr.io/example/prodflow\nIMAGE_TAG=sha-aaaaaaa\nSECRET_PLACEHOLDER=keep-me\n' >"$T/srv/repo/deploy/.env"
  : >"$T/calls.log"; echo 0 >"$T/pull_status"; echo "$SHA_NEW" >"$T/rev"; echo healthy >"$T/health"; rm -f "$T/git_corrupt"
  cat >"$T/bin/docker" <<'EOF'
#!/usr/bin/env bash
T=$(dirname "$(dirname "$0")")
case "$1" in
  pull) echo "docker pull $*" >>"$T/calls.log"; exit "$(cat "$T/pull_status")" ;;
  inspect) case "$*" in *Labels*) cat "$T/rev" ;; *Health*) cat "$T/health" ;; esac ;;
  compose) shift; echo "docker compose $*" >>"$T/calls.log"; case "$*" in *"ps -q backend"*) echo fakecontainer ;; esac ;;
esac
exit 0
EOF
  cat >"$T/bin/git" <<'EOF'
#!/usr/bin/env bash
T=$(dirname "$(dirname "$0")")
echo "git $*" >>"$T/calls.log"
if [ -e "$T/git_corrupt" ] && [[ "$*" == *checkout* ]]; then   # a checkout replaces the scripts while they are running
  echo 'echo CORRUPTED; exit 99' >"$T/srv/repo/deploy/deploy.sh"; echo 'echo CORRUPTED; exit 99' >"$T/srv/repo/deploy/agent.sh"
fi
exit 0
EOF
  printf '#!/usr/bin/env bash\nexit 0\n' >"$T/bin/flock"
  chmod +x "$T/bin/"*
}
run_agent() { PATH="$T/bin:$PATH" STATE_DIR="$T/state" DEPLOY_TIMEOUT=1 bash "$T/srv/repo/deploy/agent.sh" >"$T/out.log" 2>&1; echo $?; }
env_tag() { sed -n 's/^IMAGE_TAG=//p' "$T/srv/repo/deploy/.env"; }
ups() { grep -c 'compose .* up -d' "$T/calls.log"; }

echo "== nothing changed"
setup; echo "$SHA_OLD" >"$T/rev"
rc=$(run_agent); check $([ "$rc" = 0 ] && [ "$(ups)" = 0 ] && echo 0 || echo 1) 'same revision -> no deployment' "exit $rc, ups $(ups)"

echo "== new revision is deployed"
setup
rc=$(run_agent)
check $([ "$rc" = 0 ] && echo 0 || echo 1) 'agent exits 0' "exit $rc"
check $([ "$(env_tag)" = sha-bbbbbbb ] && echo 0 || echo 1) 'IMAGE_TAG is now sha-<first 7 of the revision>' "$(env_tag)"
check $(grep -q 'git -C .. checkout --quiet --detach bbbbbbb' "$T/calls.log" && echo 0 || echo 1) 'repository moved to the released commit'
check $([ "$(ups)" = 1 ] && echo 0 || echo 1) 'stack started once' "ups $(ups)"
check $(grep -q 'keep-me' "$T/srv/repo/deploy/.env" && echo 0 || echo 1) 'other .env lines are untouched'
check $([ ! -e "$T/state/failed" ] && echo 0 || echo 1) 'no failure recorded'

echo "== unhealthy release is rolled back and remembered"
setup; echo unhealthy >"$T/health"
rc=$(run_agent)
check $([ "$rc" = 1 ] && echo 0 || echo 1) 'agent exits 1' "exit $rc"
check $([ "$(env_tag)" = sha-aaaaaaa ] && echo 0 || echo 1) 'IMAGE_TAG is back to the previous tag' "$(env_tag)"
check $([ "$(ups)" = 2 ] && echo 0 || echo 1) 'previous version started again (two compose up)' "ups $(ups)"
check $(grep -q 'checkout --quiet --detach aaaaaaa' "$T/calls.log" && echo 0 || echo 1) 'repository moved back to the previous commit'
check $([ "$(cat "$T/state/failed" 2>/dev/null)" = sha-bbbbbbb ] && echo 0 || echo 1) 'failed tag recorded'
n=$(ups); rc=$(run_agent)
check $([ "$rc" = 0 ] && [ "$(ups)" = "$n" ] && grep -q 'failed earlier' "$T/out.log" && echo 0 || echo 1) 'the same failed release is not retried' "exit $rc"
echo "$SHA_NEWER" >"$T/rev"; echo healthy >"$T/health"; rc=$(run_agent)
check $([ "$rc" = 0 ] && [ "$(env_tag)" = sha-ccccccc ] && [ ! -e "$T/state/failed" ] && echo 0 || echo 1) 'a newer image is deployed and clears the failure' "exit $rc, tag $(env_tag)"

echo "== registry and input errors"
setup; echo 1 >"$T/pull_status"; rc=$(run_agent)
check $([ "$rc" = 0 ] && [ "$(ups)" = 0 ] && echo 0 || echo 1) 'registry unreachable -> no deployment, exit 0' "exit $rc"
setup; echo "not-a-sha" >"$T/rev"; rc=$(run_agent)
check $([ "$rc" = 0 ] && [ "$(ups)" = 0 ] && echo 0 || echo 1) 'image without a valid revision label is ignored' "exit $rc"
setup; PATH="$T/bin:$PATH" bash "$T/srv/repo/deploy/deploy.sh" 'sha-x;touch /tmp/pwned' >/dev/null 2>&1; rc=$?
check $([ "$rc" = 2 ] && [ "$(ups)" = 0 ] && echo 0 || echo 1) 'deploy.sh rejects a tag with shell metacharacters' "exit $rc"
setup; rm "$T/srv/repo/deploy/.env"; rc=$(run_agent)
check $([ "$rc" = 0 ] && [ "$(ups)" = 0 ] && echo 0 || echo 1) 'missing .env -> agent does nothing' "exit $rc"

echo "== scripts replaced during the deployment"
setup; touch "$T/git_corrupt"; rc=$(run_agent)
check $([ "$rc" = 0 ] && [ "$(env_tag)" = sha-bbbbbbb ] && ! grep -q CORRUPTED "$T/out.log" && echo 0 || echo 1) 'deployment completes although git checkout overwrote agent.sh and deploy.sh' "exit $rc"

echo "test-deploy-agent result: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
