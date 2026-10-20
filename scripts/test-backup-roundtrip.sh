#!/usr/bin/env bash
# DRAFT (S10C). REAL local round trip of the backup drafts with disposable PostgreSQL 16 containers and SYNTHETIC data only:
#   real pg_dump -Fc  ->  streaming gpg encryption  ->  set on disk  ->  (copy instead of ssh)  ->  gpg decryption piped into real pg_restore
# in the disposable restore containers of restore-test.sh, then comparison with the source (schema, table counts, per-table content hashes, sequences).
# Also: corrupted archive, wrong key, incomplete set, failed restore, checksum mismatch, a stopped source database, and a scan proving that no plaintext
# dump (PostgreSQL archive signature) exists anywhere on disk.
#
# Safety: local Docker only (the context is verified; DOCKER_HOST must be unset); no SSH, no AWS, no production data, no production keys (throw-away keys
# in a temporary directory); every container, network and temporary directory has a unique name/label and ONLY those are removed afterwards. Pre-existing
# Docker resources are listed before and after and must be identical. The only stand-in is a no-op `flock` when the system has none (Git Bash).
# Run: scripts/test-backup-roundtrip.sh      Exit: 0 = all passed, 1 = a check failed, 3 = Docker isolation could not be verified (nothing started)
set -u
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' LC_ALL=C
HERE=$(cd "$(dirname "$0")" && pwd); B="$HERE/backup"
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL  $1${2:+  ($2)}"; }
check() { if [ "$1" = 0 ]; then ok "$2"; else bad "$2" "${3:-}"; fi; }

# ---------------------------------------------------------------- Docker isolation must be verified FIRST
[ -z "${DOCKER_HOST:-}" ] || { echo "STOP: DOCKER_HOST is set; this test only uses the local engine"; exit 3; }
CTX=$(docker context show 2>/dev/null || echo unknown)
case "$CTX" in default|desktop-linux|desktop-windows|colima) ;; *) echo "STOP: Docker context '$CTX' is not a known local context"; exit 3 ;; esac
docker version >/dev/null 2>&1 || { echo "STOP: Docker is not available"; exit 3; }
ENDPOINT=$(docker context inspect "$CTX" --format '{{(index .Endpoints "docker").Host}}' 2>/dev/null)
case "$ENDPOINT" in npipe://*|unix://*) ;; *) echo "STOP: Docker endpoint '$ENDPOINT' is not a local pipe/socket"; exit 3 ;; esac
for h in "$(hostname 2>/dev/null)" "$(docker info --format '{{.Name}}' 2>/dev/null)"; do case "$h" in ip-[0-9]*-[0-9]*-[0-9]*-[0-9]*) echo "STOP: looks like an AWS instance ($h)"; exit 3 ;; esac; done
docker image inspect postgres:16-alpine >/dev/null 2>&1 || { echo "STOP: image postgres:16-alpine is not available locally (this test does not pull images)"; exit 3; }
echo "Docker isolation verified: context '$CTX', local endpoint '$ENDPOINT', engine '$(docker info --format '{{.Name}}')'"

ID="pfrt$(date +%s)$RANDOM"; PROJECT="$ID"
T=$(mktemp -d); mkdir -p "$T/bin" "$T/server" "$T/laptop" "$T/gpg-pub" "$T/gpg-priv" "$T/gpg-wrong"
chmod 700 "$T/gpg-pub" "$T/gpg-priv" "$T/gpg-wrong" 2>/dev/null
BEFORE=$(docker ps -a --format '{{.ID}} {{.Names}}' | sort); NETS_BEFORE=$(docker network ls --format '{{.ID}}' | sort); VOLS_BEFORE=$(docker volume ls -q | sort)
PF_BEFORE=$(docker ps -aq --filter 'name=pfrestore-' | sort); NETNAMES_BEFORE=$(docker network ls --format '{{.Name}}' | sort)
cleanup() {
  local ids; ids=$(docker ps -aq --filter "label=pfrt=$ID" 2>/dev/null)
  [ -n "$ids" ] && docker rm -f $ids >/dev/null 2>&1
  # restore-test containers created by THIS run only: those that did not exist before
  for r in $(docker ps -aq --filter 'name=pfrestore-' 2>/dev/null | sort); do printf '%s\n' "$PF_BEFORE" | grep -qx "$r" || docker rm -f "$r" >/dev/null 2>&1; done
  for n in $(docker network ls --format '{{.Name}}' | grep -E '^pfrestore-'); do printf '%s\n' "$NETNAMES_BEFORE" | grep -qx "$n" || docker network rm "$n" >/dev/null 2>&1; done
  docker network rm "$ID" >/dev/null 2>&1
  for h in gpg-pub gpg-priv gpg-wrong; do gpgconf --homedir "$T/$h" --kill gpg-agent >/dev/null 2>&1; done
  rm -rf "$T"
}
trap cleanup EXIT
command -v flock >/dev/null 2>&1 || { printf '#!/usr/bin/env bash\nexit 0\n' >"$T/bin/flock"; chmod +x "$T/bin/flock"; echo "(no flock on this system: a no-op stand-in is used for the lock primitive only)"; }
export PATH="$T/bin:$PATH"
docker network create --label "pfrt=$ID" "$ID" >/dev/null || { echo "STOP: cannot create the test network"; exit 3; }

# ---------------------------------------------------------------- throw-away keys (NOT production keys)
gen_key() { GNUPGHOME="$T/$1" gpg --batch --quiet --pinentry-mode loopback --passphrase '' --quick-generate-key "$2 <$2@example.invalid>" default default never >/dev/null 2>&1; }
gen_key gpg-priv roundtrip-test; gen_key gpg-wrong wrong-key
FPR=$(GNUPGHOME="$T/gpg-priv" gpg --batch --with-colons --list-keys roundtrip-test@example.invalid | awk -F: '/^fpr:/{print $10; exit}')
[ -n "$FPR" ] || { echo "could not create a throw-away key"; exit 1; }
GNUPGHOME="$T/gpg-priv" gpg --batch --export "$FPR" | GNUPGHOME="$T/gpg-pub" gpg --batch --quiet --import >/dev/null 2>&1
check $([ -z "$(GNUPGHOME="$T/gpg-pub" gpg --batch --list-secret-keys --with-colons 2>/dev/null)" ] && echo 0 || echo 1) 'the "server" keyring holds the public key only'

# ---------------------------------------------------------------- disposable source databases (named like the production ones, own Compose project label)
start_db() { # service container-suffix database
  local c="$PROJECT-$2"
  docker run -d --name "$c" --network "$ID" --label "pfrt=$ID" --label "com.docker.compose.project=$PROJECT" --label "com.docker.compose.service=$1" \
    --memory 256m --tmpfs /var/lib/postgresql/data:rw,size=512m -e POSTGRES_USER="$3" -e POSTGRES_DB="$3" -e POSTGRES_PASSWORD="$(openssl rand -hex 12)" postgres:16-alpine >/dev/null || return 1
  for _ in $(seq 1 90); do docker exec "$c" pg_isready -h 127.0.0.1 -U "$3" -d "$3" >/dev/null 2>&1 && return 0; sleep 1; done; return 1
}
echo "== starting disposable source databases ($PROJECT-db-1, $PROJECT-keycloak-db-1)"
start_db db db-1 prodflow && start_db keycloak-db keycloak-db-1 keycloak || { echo "source databases did not start"; exit 1; }
APP="$PROJECT-db-1"; KC="$PROJECT-keycloak-db-1"
psql_in() { docker exec -i "$1" psql -U "$2" -d "$2" -X -At -v ON_ERROR_STOP=1 "${@:3}"; }

cat >"$T/app.sql" <<'SQL'
CREATE TABLE item (id bigserial PRIMARY KEY, code varchar(40) NOT NULL UNIQUE, name varchar(200) NOT NULL, unit varchar(10) NOT NULL, type varchar(20) NOT NULL, qty_on_hand numeric(14,3) NOT NULL DEFAULT 0, version bigint NOT NULL DEFAULT 0);
CREATE TABLE bom_line (id bigserial PRIMARY KEY, parent_item_id bigint NOT NULL REFERENCES item(id), child_item_id bigint NOT NULL REFERENCES item(id), qty_per numeric(14,3) NOT NULL);
CREATE TABLE production_order (id bigserial PRIMARY KEY, order_no varchar(20) NOT NULL UNIQUE, product_id bigint NOT NULL REFERENCES item(id), quantity numeric(14,3) NOT NULL, due_date date NOT NULL, status varchar(20) NOT NULL, created_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE purchase_request (id bigserial PRIMARY KEY, item_id bigint NOT NULL REFERENCES item(id), quantity numeric(14,3) NOT NULL, status varchar(20) NOT NULL, order_no varchar(20), note text);
CREATE TABLE flyway_schema_history (installed_rank int PRIMARY KEY, version varchar(50), description varchar(200) NOT NULL, type varchar(20) NOT NULL, script varchar(1000) NOT NULL, checksum int, installed_by varchar(100) NOT NULL, installed_on timestamp NOT NULL DEFAULT now(), execution_time int NOT NULL, success boolean NOT NULL);
INSERT INTO flyway_schema_history VALUES (1,'1','init','SQL','V1__init.sql',111,'synthetic',now(),5,true),(2,'100','demo data','SQL','V100__demo.sql',222,'synthetic',now(),3,true);
INSERT INTO item (code,name,unit,type,qty_on_hand) VALUES ('MR-200','Machine frame MR-200','pcs','PRODUCT',0),('SC-M8','Hex screw M8x30 – Müller ü ß 日本','pcs','MATERIAL',25),('PR-40','Aluminium profile 40x40','m','MATERIAL',50.5);
INSERT INTO item (code,name,unit,type,qty_on_hand) SELECT 'SYN-'||g, md5(g::text)||' synthetic material', 'pcs', 'MATERIAL', g % 97 FROM generate_series(1,15000) g;
INSERT INTO bom_line (parent_item_id,child_item_id,qty_per) VALUES (1,2,4),(1,3,3.5);
INSERT INTO production_order (order_no,product_id,quantity,due_date,status) VALUES ('FA-00001',1,10,'2026-10-25','WAITING_MATERIAL'),('FA-00002',1,1.5,'2026-11-03','DONE');
INSERT INTO purchase_request (item_id,quantity,status,order_no,note) VALUES (2,15,'OPEN','FA-00001','multi-line'||E'\n'||'note with "quotes", commas and ''apostrophes''');
SELECT setval('item_id_seq', 20000);
SQL
cat >"$T/kc.sql" <<'SQL'
CREATE TABLE realm (id varchar(36) PRIMARY KEY, name varchar(255) UNIQUE, enabled boolean NOT NULL DEFAULT true);
CREATE TABLE client (id varchar(36) PRIMARY KEY, realm_id varchar(36) NOT NULL REFERENCES realm(id), client_id varchar(255) NOT NULL, public_client boolean NOT NULL DEFAULT false);
CREATE TABLE keycloak_role (id varchar(36) PRIMARY KEY, realm_id varchar(36) NOT NULL REFERENCES realm(id), name varchar(255) NOT NULL);
CREATE TABLE user_entity (id varchar(36) PRIMARY KEY, realm_id varchar(36) NOT NULL REFERENCES realm(id), username varchar(255) NOT NULL);
CREATE TABLE credential (id varchar(36) PRIMARY KEY, user_id varchar(36) NOT NULL REFERENCES user_entity(id), type varchar(255), secret_data text);
CREATE TABLE component (id varchar(36) PRIMARY KEY, name varchar(255), realm_id varchar(36));
CREATE TABLE realm_attribute (realm_id varchar(36) NOT NULL, name varchar(255) NOT NULL, value text, PRIMARY KEY (realm_id, name));
CREATE TABLE user_session (id varchar(36) PRIMARY KEY, realm_id varchar(36), last_session_refresh int);
INSERT INTO realm VALUES ('r1','prodflow',true),('m1','master',true);
INSERT INTO client SELECT 'c-'||x, 'r1', x, x='prodflow-web' FROM unnest(ARRAY['prodflow-web','prodflow-api','prodflow-swagger']) x;
INSERT INTO keycloak_role SELECT 'k-'||x, 'r1', x FROM unnest(ARRAY['ADMIN','PLANNER','PURCHASER']) x;
INSERT INTO user_entity SELECT 'u-'||x, 'r1', x FROM unnest(ARRAY['planner','purchaser','admin']) x;
INSERT INTO credential SELECT 'cr-'||x, 'u-'||x, 'password', '{"value":"SYNTHETIC-NOT-A-REAL-HASH-'||x||'"}' FROM unnest(ARRAY['planner','purchaser','admin']) x;
INSERT INTO component VALUES ('co1','rsa-generated','r1'),('co2','hmac-generated','r1');
INSERT INTO realm_attribute VALUES ('r1','accessTokenLifespan','300'),('r1','displayName','ProdFlow synthetic');
INSERT INTO user_session SELECT 's-'||g, 'r1', g FROM generate_series(1,400) g;
SQL
psql_in "$APP" prodflow -q <"$T/app.sql" >/dev/null && psql_in "$KC" keycloak -q <"$T/kc.sql" >/dev/null || { echo "could not load the synthetic data"; exit 1; }
src_count() { psql_in "$1" "$2" -c "select count(*) from public.\"$3\""; }
echo "synthetic data: app item=$(src_count "$APP" prodflow item) rows, keycloak user_session=$(src_count "$KC" keycloak user_session) rows, source sizes: $(psql_in "$APP" prodflow -c 'select pg_size_pretty(pg_database_size(current_database()))') / $(psql_in "$KC" keycloak -c 'select pg_size_pretty(pg_database_size(current_database()))')"
PLAIN_APP=$(docker exec "$APP" pg_dump -U prodflow -d prodflow -Fc -Z 6 | wc -c | tr -d ' ')   # size only; the stream is discarded, nothing is written

cat >"$T/backup.conf" <<EOF
BACKUP_DIR=$T/server
GNUPGHOME_BACKUP=$T/gpg-pub
RECIPIENT_FPR=$FPR
COMPOSE_PROJECT=$PROJECT
KEEP_SETS=5
MIN_FREE_MB=1
DUMP_TIMEOUT_S=120
EOF
run_backup() { ( export BACKUP_CONF="$T/backup.conf" BACKUP_TEST_UID=0 GNUPGHOME="$T/gpg-pub"; bash "$B/backup-db.sh" "$@" ) >"$T/backup.log" 2>&1; echo $?; }
last_set() { ls -1d "$T/server"/set-* 2>/dev/null | sort | tail -1; }

echo "== 1. backup-db.sh --check against the real containers"
rc=$(run_backup --check); check $([ "$rc" = 0 ] && [ -z "$(ls -A "$T/server")" ] && echo 0 || echo 1) '--check passes against real containers and creates nothing' "exit $rc: $(tail -3 "$T/backup.log" | tr '\n' ' ')"

echo "== 2. real backup (pg_dump -Fc | gpg)"
t0=$(date +%s); rc=$(run_backup --label roundtrip); t1=$(date +%s); S=$(last_set)
check $([ "$rc" = 0 ] && [ -f "$S/SET_OK" ] && echo 0 || echo 1) 'complete set written' "exit $rc: $(tail -4 "$T/backup.log" | tr '\n' ' ')"
APP_ENC=$(stat -c %s "$S/app.dump.gpg" 2>/dev/null); KC_ENC=$(stat -c %s "$S/keycloak.dump.gpg" 2>/dev/null)
check $([ -n "$APP_ENC" ] && [ "$APP_ENC" -gt 1024 ] && [ -n "$KC_ENC" ] && [ "$KC_ENC" -gt 1024 ] && echo 0 || echo 1) 'both encrypted dumps are non-trivial' "app $APP_ENC, keycloak $KC_ENC bytes"
check $(( cd "$S" && sha256sum -c --quiet SHA256SUMS ) >/dev/null 2>&1 && echo 0 || echo 1) 'SHA256SUMS verifies'
check $(grep -q '^count.item=15003$' "$S/app.manifest" && grep -q '^count.user_session=400$' "$S/keycloak.manifest" && grep -q '^flyway_latest=100$' "$S/app.manifest" && echo 0 || echo 1) 'manifests carry the exact table counts and the Flyway version'
check $(head -c 5 "$S/app.dump.gpg" | grep -q PGDMP && echo 1 || echo 0) 'the file on disk is not a plaintext PostgreSQL archive'
cp -r "$S" "$T/laptop/$(basename "$S")"   # stands in for fetch-backups.sh (needs ssh, covered by the fake-ssh unit tests)
LS="$T/laptop/$(basename "$S")"

restore() { ( export GNUPGHOME="${KEYHOME:-$T/gpg-priv}"; bash "$B/restore-test.sh" --set "$1" "${@:2}" ) >"$T/restore.log" 2>&1; echo $?; }

echo "== 3. real restore through restore-test.sh (gpg --decrypt | docker exec -i pg_restore)"
t2=$(date +%s); rc=$(restore "$LS" --keep); t3=$(date +%s)
check $([ "$rc" = 0 ] && grep -q 'RESULT: all checks passed' "$T/restore.log" && echo 0 || echo 1) 'restore-test.sh passes for both databases with the real input method' "exit $rc: $(grep -E 'FAIL|REFUSED' "$T/restore.log" | head -3 | tr '\n' ' ')"
RUN=$(sed -n 's/.*network \(pfrestore-[0-9A-Za-z-]*\) and containers.*/\1/p' "$T/restore.log" | head -1)
RAPP=$(docker ps -aq --filter "label=pfrestore=$RUN" --filter "name=$RUN-app" | head -1); RKC=$(docker ps -aq --filter "label=pfrestore=$RUN" --filter "name=$RUN-keycloak" | head -1)
check $([ -n "$RUN" ] && [ -n "$RAPP" ] && [ -n "$RKC" ] && echo 0 || echo 1) 'the restored containers are available for comparison' "run '$RUN'"
RESTORE_S=$(sed -n 's/.*app: restore took \([0-9.]*\) s.*/\1/p' "$T/restore.log" | head -1); RESTORE_KC_S=$(sed -n 's/.*keycloak: restore took \([0-9.]*\) s.*/\1/p' "$T/restore.log" | head -1)
rq() { docker exec -i "$1" psql -U postgres -d restore_check -X -At -v ON_ERROR_STOP=1 -c "$2"; }
sq() { docker exec -i "$1" psql -U "$2" -d "$2" -X -At -v ON_ERROR_STOP=1 -c "$3"; }
tables() { sq "$1" "$2" "select table_name from information_schema.tables where table_schema='public' and table_type='BASE TABLE' order by 1"; }
hash_sql() { echo "select md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from public.\"$1\" x"; }

echo "== 4. restored data equals the source"
for spec in "$APP prodflow $RAPP" "$KC keycloak $RKC"; do set -- $spec
  tabs=$(tables "$1" "$2"); same=1
  [ "$tabs" = "$(rq "$3" "select table_name from information_schema.tables where table_schema='public' and table_type='BASE TABLE' order by 1")" ] || same=0
  check $([ "$same" = 1 ] && echo 0 || echo 1) "$2: the same set of tables exists after the restore"
  allok=1; for t in $tabs; do a=$(sq "$1" "$2" "$(hash_sql "$t")"); b=$(rq "$3" "$(hash_sql "$t")"); [ "$a" = "$b" ] || { allok=0; bad "$2: table $t differs (content hash)"; }; done
  check $([ "$allok" = 1 ] && echo 0 || echo 1) "$2: every table has identical content (md5 over all rows) in source and restore: $(echo $tabs | wc -w | tr -d ' ') tables"
  docker exec "$1" pg_dump -U "$2" -d "$2" -s --no-owner --no-privileges | grep -vE '^(--|[\\](un)?restrict )' >"$T/schema.src"; docker exec "$3" pg_dump -U postgres -d restore_check -s --no-owner --no-privileges | grep -vE '^(--|[\\](un)?restrict )' >"$T/schema.res"
  s1=$(md5sum <"$T/schema.src" | cut -c1-12); s2=$(md5sum <"$T/schema.res" | cut -c1-12)
  [ "$s1" = "$s2" ] || { echo "   schema diff ($2, first lines):"; diff "$T/schema.src" "$T/schema.res" | head -8 | sed 's/^/     /'; }
  check $([ "$s1" = "$s2" ] && echo 0 || echo 1) "$2: the schema (tables, constraints, indexes, sequences) is identical" "$s1 vs $s2"
done
check $([ "$(sq "$APP" prodflow "select last_value from item_id_seq")" = "$(rq "$RAPP" "select last_value from item_id_seq")" ] && echo 0 || echo 1) 'sequence state (item_id_seq) is restored'
rec="select code||'|'||name||'|'||qty_on_hand from item where code in ('SC-M8','PR-40') order by code"
check $([ "$(sq "$APP" prodflow "$rec")" = "$(rq "$RAPP" "$rec")" ] && [ "$(rq "$RAPP" "select name from item where code='SC-M8'")" = "Hex screw M8x30 – Müller ü ß 日本" ] && echo 0 || echo 1) 'representative records incl. UTF-8, umlauts, CJK and numeric precision are intact'
check $([ "$(rq "$RAPP" "select note from purchase_request where id=1")" = "$(sq "$APP" prodflow "select note from purchase_request where id=1")" ] && echo 0 || echo 1) 'multi-line text with quotes and apostrophes is intact'
check $([ "$(rq "$RKC" "select count(*) from client where realm_id=(select id from realm where name='prodflow')")" = 3 ] && [ "$(rq "$RKC" "select secret_data from credential where user_id='u-planner'")" = "$(sq "$KC" keycloak "select secret_data from credential where user_id='u-planner'")" ] && echo 0 || echo 1) 'Keycloak-like realm, clients and credential records are intact'
check $(rq "$RAPP" "select count(*) from pg_roles where rolname='prodflow'" | grep -qx 0 && echo 0 || echo 1) '--no-owner: the production role name is not required in the restore target'
docker rm -f "$RAPP" "$RKC" >/dev/null 2>&1; docker network rm "$RUN" >/dev/null 2>&1

echo "== 5. failure scenarios against the real tools"
mkset() { local n=$1; rm -rf "$T/laptop/$n"; cp -r "$S" "$T/laptop/$n"; echo "$T/laptop/$n"; }
resum() { ( cd "$1" && sha256sum -- *.gpg *.manifest >SHA256SUMS ); }   # recompute sums so that a defect is NOT caught by the checksum guard
# a) checksum mismatch (tamper without updating SHA256SUMS)
D=$(mkset set-20260101T000001Z); printf 'X' >>"$D/app.dump.gpg"; rc=$(restore "$D")
check $([ "$rc" = 2 ] && grep -q 'SHA256SUMS' "$T/restore.log" && echo 0 || echo 1) 'checksum mismatch: refused before anything is created (exit 2)' "exit $rc"
# b) corrupted archive that passes the checksum: flip bytes in the middle of the ciphertext, then recompute the sums
D=$(mkset set-20260101T000002Z); sz=$(stat -c %s "$D/app.dump.gpg"); printf 'CORRUPTED!' | dd of="$D/app.dump.gpg" bs=1 seek=$((sz / 2)) conv=notrunc 2>/dev/null; resum "$D"; rc=$(restore "$D" --only app)
check $([ "$rc" = 1 ] && grep -q 'decrypt or restore failed' "$T/restore.log" && echo 0 || echo 1) 'corrupted ciphertext (valid checksum): gpg integrity check fails the restore (exit 1)' "exit $rc"
# c) wrong key
D=$(mkset set-20260101T000003Z); rc=$(KEYHOME="$T/gpg-wrong" restore "$D" --only app)
check $([ "$rc" = 1 ] && grep -q 'decrypt or restore failed' "$T/restore.log" && echo 0 || echo 1) 'a different private key cannot decrypt (exit 1)' "exit $rc"
# d) incomplete set: no SET_OK
D=$(mkset set-20260101T000004Z); rm -f "$D/SET_OK"; rc=$(restore "$D")
check $([ "$rc" = 2 ] && grep -q 'incomplete' "$T/restore.log" && echo 0 || echo 1) 'incomplete set (no SET_OK): refused (exit 2)' "exit $rc"
# e) truncated plaintext, validly re-encrypted: pg_restore itself must fail
D=$(mkset set-20260101T000005Z); GNUPGHOME="$T/gpg-priv" gpg --batch --quiet --decrypt "$D/app.dump.gpg" 2>/dev/null | head -c $((PLAIN_APP / 2)) | GNUPGHOME="$T/gpg-pub" gpg --batch --quiet --yes --trust-model always --recipient "$FPR" --encrypt --output "$D/app.dump.gpg.new" && mv "$D/app.dump.gpg.new" "$D/app.dump.gpg"
sed -i "s/^encrypted_sha256=.*/encrypted_sha256=$(sha256sum "$D/app.dump.gpg" | awk '{print $1}')/" "$D/app.manifest"; resum "$D"; rc=$(restore "$D" --only app)
check $([ "$rc" = 1 ] && grep -qE 'decrypt or restore failed' "$T/restore.log" && echo 0 || echo 1) 'truncated archive (valid encryption and checksums): pg_restore fails the test (exit 1)' "exit $rc: $(grep -E 'pg_restore|error' "$T/restore.log" | head -2 | tr '\n' ' ')"
# f) restored data that differs from the manifest is detected by the count check
D=$(mkset set-20260101T000006Z); sed -i 's/^count.item=.*/count.item=15004/' "$D/app.manifest"; resum "$D"; rc=$(restore "$D" --only app)
check $([ "$rc" = 1 ] && grep -q 'table item has 15003 rows, manifest says 15004' "$T/restore.log" && echo 0 || echo 1) 'a manifest/data count difference is detected (exit 1)' "exit $rc"
# g) backup side: one source database stopped -> app is still backed up, set marked failed
docker stop "$KC" >/dev/null 2>&1; rc=$(run_backup --label stopped-db); S2=$(last_set)
check $([ "$rc" = 1 ] && [ -f "$S2/SET_FAILED" ] && [ ! -f "$S2/SET_OK" ] && [ -f "$S2/app.dump.gpg" ] && [ ! -f "$S2/keycloak.dump.gpg" ] && echo 0 || echo 1) 'stopped Keycloak database: exit 1, set marked SET_FAILED, application database still backed up' "exit $rc"
docker start "$KC" >/dev/null 2>&1
for _ in $(seq 1 60); do docker exec "$KC" pg_isready -h 127.0.0.1 -U keycloak -d keycloak >/dev/null 2>&1 && break; sleep 1; done
D="$S2"; rc=$(restore "$D"); check $([ "$rc" = 2 ] && echo 0 || echo 1) 'a SET_FAILED set can never be restored (exit 2)' "exit $rc"
# h) the restore containers of the failed runs are gone
check $([ "$(docker ps -aq --filter 'name=pfrestore-' | sort | comm -13 <(printf '%s\n' "$PF_BEFORE") - | wc -l | tr -d ' ')" = 0 ] && echo 0 || echo 1) 'no restore container is left behind by the failed runs'

echo "== 6. no plaintext backup anywhere on disk"
magic=$(grep -rlaE 'PGDMP' "$T" 2>/dev/null | head -3 | tr '\n' ' ')
check $([ -z "$magic" ] && echo 0 || echo 1) 'no file in the test directory (server dir, laptop dir, logs) contains a PostgreSQL archive signature' "$magic"
check $(find "$T" \( -name '*.part' -o -name '*.tmp' -o -name '*.partial' -o -name '*.dump' -o -name '*.sql.gz' \) | grep -q . && echo 1 || echo 0) 'no temporary or plaintext dump files remain'
check $(grep -rl 'SYNTHETIC-NOT-A-REAL-HASH\|Müller' "$T/server" "$T/laptop" 2>/dev/null | grep -q . && echo 1 || echo 0) 'no synthetic record content is readable in any backup file or manifest'

echo "== 7. measurements"
echo "   source database sizes: app $(psql_in "$APP" prodflow -c 'select pg_database_size(current_database())') bytes, keycloak $(psql_in "$KC" keycloak -c 'select pg_database_size(current_database())') bytes"
echo "   pg_dump -Fc (plain, size only): app $PLAIN_APP bytes; encrypted: app $APP_ENC bytes, keycloak $KC_ENC bytes"
echo "   backup wall time (both databases, incl. checks): $((t1 - t0)) s; manifest dump seconds: app $(sed -n 's/^dump_seconds=//p' "$S/app.manifest"), keycloak $(sed -n 's/^dump_seconds=//p' "$S/keycloak.manifest")"
echo "   restore (decrypt+pg_restore): app ${RESTORE_S:-?} s, keycloak ${RESTORE_KC_S:-?} s; whole restore-test run incl. container start and checks: $((t3 - t2)) s"

echo "== 8. isolation and cleanup"
cleanup; trap - EXIT
AFTER=$(docker ps -a --format '{{.ID}} {{.Names}}' | sort)
check $([ "$BEFORE" = "$AFTER" ] && echo 0 || echo 1) 'the list of containers is identical to the state before the test (nothing pre-existing touched or left behind)'
check $([ "$NETS_BEFORE" = "$(docker network ls --format '{{.ID}}' | sort)" ] && [ "$VOLS_BEFORE" = "$(docker volume ls -q | sort)" ] && echo 0 || echo 1) 'networks and volumes are identical to the state before the test'
echo "test-backup-roundtrip result: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
