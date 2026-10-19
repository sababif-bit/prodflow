#!/usr/bin/env bash
# Disposable test of scripts/reset-demo-data.sh (Issue #9). Starts throwaway postgres containers that look like the Compose services
# (labels project/service), applies the real schema (V1) and the real demo seed (V100), simulates demo runs in SQL and resets.
# Never touches the real "prodflow" Compose project, its volumes, localhost:8080/8180 or any .env file.
# Run: scripts/test-reset-demo.sh     Exit: 0 = all passed, 1 = a check failed, 3 = pre-check failed
set -u
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
REPO_N=$(cd "$REPO" && { pwd -W 2>/dev/null || pwd; })
SCHEMA="backend/src/main/resources/db/migration/V1__initial_schema.sql"
SEED="backend/src/main/resources/db/demo/V100__demo_data.sql"
RESET="$HERE/reset-demo-data.sh"
P=prodflow-resetcheck
IMG=postgres:16-alpine
APPDB=resetcheck-app; KCDB=resetcheck-kc; EXTRA=resetcheck-app2; MIXED=resetcheck-mixed
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL  $1${2:+  ($2)}"; }
check() { if [ "$1" = 0 ]; then ok "$2"; else bad "$2" "${3:-}"; fi; }
WORK=$(mktemp -d)
cleanup() { docker rm -f $APPDB $KCDB $EXTRA $MIXED >/dev/null 2>&1; rm -rf "$WORK"; }
trap cleanup EXIT

command -v docker >/dev/null && docker version >/dev/null 2>&1 || { echo "pre-check failed: Docker not available"; exit 3; }
[ -z "$(docker ps -aq --filter "name=^resetcheck-")" ] || { echo "pre-check failed: resetcheck-* containers exist"; exit 3; }
STACK_BEFORE=$(docker ps -a --filter 'label=com.docker.compose.project=prodflow' --format '{{.ID}}' | sort | tr '\n' ' ')

start() { # name service dbname
  docker run -d --name "$1" --label "com.docker.compose.project=$P" --label "com.docker.compose.service=$2" \
    -e POSTGRES_USER=u -e POSTGRES_PASSWORD="$(openssl rand -hex 8)" -e POSTGRES_DB="$3" $IMG >/dev/null 2>&1
}
wait_ready() { for _ in $(seq 1 40); do docker exec "$1" pg_isready -h 127.0.0.1 -U u >/dev/null 2>&1 && { sleep 2; return 0; }; sleep 1; done; return 1; }
psqlc() { docker exec -i "$1" sh -c 'exec psql -X -At -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"'; }
install_app_schema() { # container
  psqlc "$1" <"$REPO/$SCHEMA" >/dev/null && psqlc "$1" <"$REPO/$SEED" >/dev/null
  psqlc "$1" >/dev/null <<'EOF'
CREATE TABLE flyway_schema_history (installed_rank int, version varchar, success boolean);
INSERT INTO flyway_schema_history VALUES (1, '1', true), (2, '100', true);
EOF
}
dump() { psqlc "$1" <<'EOF' | sha256sum | cut -c1-16
SELECT 'item', id, code, name, unit, type, qty_on_hand, version FROM item ORDER BY id;
SELECT 'bom', id, parent_item_id, child_item_id, qty_per FROM bom_line ORDER BY id;
SELECT 'orders', count(*) FROM production_order;
SELECT 'requests', count(*) FROM purchase_request;
SELECT 'seq_order', last_value, is_called FROM production_order_id_seq;
SELECT 'seq_request', last_value, is_called FROM purchase_request_id_seq;
SELECT 'seq_item', last_value, is_called FROM item_id_seq;
SELECT 'seq_bom', last_value, is_called FROM bom_line_id_seq;
EOF
}
simulate_demo_run() { # container, variant -> orders, requests, stock changes, an extra user-created item
  psqlc "$1" >/dev/null <<EOF
INSERT INTO production_order (order_no, item_id, quantity, due_date, status) VALUES ('FA-00001', 1, 10, current_date, 'DONE');
INSERT INTO production_order (order_no, item_id, quantity, due_date, status) VALUES ('FA-00002', 1, $2, current_date, 'WAITING_MATERIAL');
INSERT INTO purchase_request (item_id, production_order_id, quantity, status) VALUES (2, 1, 15, 'RECEIVED');
UPDATE item SET qty_on_hand = 0, version = version + 3 WHERE code = 'SC-M8';
UPDATE item SET qty_on_hand = 10, version = version + 1 WHERE code = 'MR-200';
INSERT INTO item (code, name, unit, type, qty_on_hand) VALUES ('X-$2', 'user created', 'pcs', 'MATERIAL', 7);
UPDATE bom_line SET qty_per = 9 WHERE id = 1;
EOF
}
run_reset() { bash "$RESET" "$@" 2>&1; }

echo "== setup"
start $APPDB db prodflow; start $KCDB keycloak-db keycloak
wait_ready $APPDB && wait_ready $KCDB; check $? 'disposable containers are ready'
install_app_schema $APPDB; check $? 'application schema + demo seed applied'
psqlc $KCDB >/dev/null <<'EOF'
CREATE TABLE realm (id varchar primary key, name varchar); CREATE TABLE user_entity (id varchar primary key);
EOF
printf 'SOME_SETTING=1\r\nPRODFLOW_DEMO_RESET=allowed\r\n' >"$WORK/demo.env"
printf 'SOME_SETTING=1\n' >"$WORK/plain.env"
printf 'PRODFLOW_DEMO_RESET=no\n' >"$WORK/no.env"
BASE=$(dump $APPDB); echo "   baseline fingerprint $BASE"

echo "== guards refuse before anything changes"
simulate_demo_run $APPDB 5; DIRTY=$(dump $APPDB)
check $([ "$DIRTY" != "$BASE" ] && echo 0 || echo 1) 'simulated demo run changed the data'
refused() { # label expected-text args...
  local label=$1 text=$2; shift 2
  out=$(run_reset "$@"); rc=$?
  check $([ $rc -eq 2 ] && printf '%s' "$out" | grep -q "$text" && echo 0 || echo 1) "$label" "exit $rc"
  check $([ "$(dump $APPDB)" = "$DIRTY" ] && echo 0 || echo 1) "   ...and the data is unchanged"
}
refused 'no --project' 'project' --env-file "$WORK/demo.env" --yes
refused 'env file without the demo marker' 'marker' --project $P --env-file "$WORK/plain.env" --yes
refused 'marker with another value' 'marker' --project $P --env-file "$WORK/no.env" --yes
refused 'missing env file' 'env-file' --project $P --env-file "$WORK/none.env" --yes
refused 'service keycloak-db is refused' "service must be exactly 'db'" --project $P --env-file "$WORK/demo.env" --service keycloak-db --yes
refused 'database name keycloak is refused' "database must be exactly 'prodflow'" --project $P --env-file "$WORK/demo.env" --database keycloak --yes
refused 'unknown project (no container)' 'no running container' --project no-such-project --env-file "$WORK/demo.env" --yes
out=$(run_reset --project $P --env-file "$WORK/demo.env" --dry-run); rc=$?
check $([ $rc -eq 0 ] && printf '%s' "$out" | grep -q 'verified target: project=prodflow-resetcheck service=db' && printf '%s' "$out" | grep -q 'dry run: nothing changed' && echo 0 || echo 1) 'dry run shows the verified target and plan' "exit $rc"
check $([ "$(dump $APPDB)" = "$DIRTY" ] && echo 0 || echo 1) '   ...and changes nothing'
out=$(run_reset --project $P --env-file "$WORK/demo.env"); rc=$?
check $([ $rc -eq 3 ] && echo 0 || echo 1) 'without --yes nothing is executed (exit 3)' "exit $rc"
check $([ "$(dump $APPDB)" = "$DIRTY" ] && echo 0 || echo 1) '   ...and the data is unchanged'
check $(printf '%s' "$out" | grep -qiE 'password|secret|token' && echo 1 || echo 0) 'output contains no secret-like words'

echo "== a container whose service is db but whose content is Keycloak's is refused"
docker rm -f $APPDB >/dev/null 2>&1; start $MIXED db prodflow; wait_ready $MIXED; install_app_schema $MIXED
psqlc $MIXED >/dev/null <<'EOF'
CREATE TABLE realm (id varchar primary key, name varchar);
EOF
M0=$(dump $MIXED)
out=$(run_reset --project $P --env-file "$WORK/demo.env" --yes); rc=$?
check $([ $rc -eq 2 ] && printf '%s' "$out" | grep -q "Keycloak table 'realm'" && echo 0 || echo 1) 'Keycloak table in the target database -> refused' "exit $rc"
check $([ "$(dump $MIXED)" = "$M0" ] && echo 0 || echo 1) '   ...and the data is unchanged'
docker rm -f $MIXED >/dev/null 2>&1

echo "== database without the expected schema / Flyway state"
start $EXTRA db prodflow; wait_ready $EXTRA
out=$(run_reset --project $P --env-file "$WORK/demo.env" --yes); rc=$?
check $([ $rc -eq 2 ] && printf '%s' "$out" | grep -q "table 'item' is missing" && echo 0 || echo 1) 'empty database -> refused' "exit $rc"
install_app_schema $EXTRA; psqlc $EXTRA >/dev/null <<'EOF'
DELETE FROM flyway_schema_history WHERE version = '100';
EOF
out=$(run_reset --project $P --env-file "$WORK/demo.env" --yes); rc=$?
check $([ $rc -eq 2 ] && printf '%s' "$out" | grep -q 'versions 1 and 100' && echo 0 || echo 1) 'Flyway without demo data (version 100) -> refused' "exit $rc"
docker rm -f $EXTRA >/dev/null 2>&1

echo "== two containers match -> refused"
start $APPDB db prodflow; start $EXTRA db prodflow; wait_ready $APPDB; wait_ready $EXTRA
out=$(run_reset --project $P --env-file "$WORK/demo.env" --yes); rc=$?
check $([ $rc -eq 2 ] && printf '%s' "$out" | grep -q 'more than one container' && echo 0 || echo 1) 'ambiguous target -> refused' "exit $rc"
docker rm -f $EXTRA >/dev/null 2>&1

echo "== reset restores the exact baseline, repeatably"
install_app_schema $APPDB; B1=$(dump $APPDB)
check $([ "$B1" = "$BASE" ] && echo 0 || echo 1) 'a freshly seeded database has the baseline fingerprint'
simulate_demo_run $APPDB 5
out=$(run_reset --project $P --env-file "$WORK/demo.env" --yes); rc=$?
check $([ $rc -eq 0 ] && echo 0 || echo 1) 'reset succeeds' "exit $rc"
check $([ "$(dump $APPDB)" = "$BASE" ] && echo 0 || echo 1) 'after a demo run the reset restores items, BOM, versions and identity sequences exactly'
check $(printf '%s' "$out" | grep -q 'SC-M8 25' && printf '%s' "$out" | grep -q 'MR-200 0' && printf '%s' "$out" | grep -q 'next order number: FA-00001' && echo 0 || echo 1) 'output reports the baseline (MR-200 0, SC-M8 25, first order FA-00001)'
simulate_demo_run $APPDB 8
out=$(run_reset --project $P --env-file "$WORK/demo.env" --yes); rc=$?
check $([ $rc -eq 0 ] && [ "$(dump $APPDB)" = "$BASE" ] && echo 0 || echo 1) 'a second run + reset gives the identical state' "exit $rc"
out=$(run_reset --project $P --env-file "$WORK/demo.env" --yes); rc=$?
check $([ $rc -eq 0 ] && [ "$(dump $APPDB)" = "$BASE" ] && echo 0 || echo 1) 'resetting an already clean database is idempotent' "exit $rc"
check $([ "$(psqlc $APPDB <<<"SELECT count(*) FROM item WHERE code LIKE 'X-%'")" = 0 ] && echo 0 || echo 1) 'user-created items are removed'

echo "== a failing baseline check rolls everything back"
simulate_demo_run $APPDB 9; D2=$(dump $APPDB)
sed "s/'MATERIAL', 25)/'MATERIAL', 24)/" "$REPO/$SEED" >"$WORK/bad-seed.sql"
cmp -s "$WORK/bad-seed.sql" "$REPO/$SEED" && bad 'test setup: bad seed was not produced'
out=$(run_reset --project $P --env-file "$WORK/demo.env" --seed-file "$WORK/bad-seed.sql" --yes); rc=$?
check $([ $rc -eq 1 ] && [ "$(dump $APPDB)" = "$D2" ] && echo 0 || echo 1) 'a seed that does not match the baseline -> transaction rolled back, data unchanged' "exit $rc"

echo "== Keycloak database untouched"
check $([ "$(psqlc $KCDB <<<"SELECT count(*) FROM information_schema.tables WHERE table_schema='public'")" = 2 ] && echo 0 || echo 1) 'Keycloak-like database still has exactly its two tables'

cleanup; trap - EXIT
check $([ -z "$(docker ps -aq --filter 'name=^resetcheck-')" ] && echo 0 || echo 1) 'no test containers left'
check $([ "$STACK_BEFORE" = "$(docker ps -a --filter 'label=com.docker.compose.project=prodflow' --format '{{.ID}}' | sort | tr '\n' ' ')" ] && echo 0 || echo 1) 'development stack containers unchanged'
echo "test-reset-demo result: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
