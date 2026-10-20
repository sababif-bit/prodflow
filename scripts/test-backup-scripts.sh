#!/usr/bin/env bash
# DRAFT (S10B). Tests of the backup drafts WITHOUT any real database: a fake `docker`, `flock`, `logger`, `hostname` and `ssh` stand in for the
# environment, real gpg encrypts and decrypts with throw-away keys. pg_dump is NOT run (the fake docker emits fixed bytes), nothing touches
# production, no network, no containers. Verifies: set layout, encryption (plaintext never on disk, decryptable only with the private key),
# manifests/checksums, guards, failure handling, retention, lock, check mode, fetch verification and the restore-test guards and checks.
# Run: scripts/test-backup-scripts.sh      Exit: 0 = all passed, 1 = a check failed
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
B="$HERE/backup"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL  $1${2:+  ($2)}"; }
check() { if [ "$1" = 0 ]; then ok "$2"; else bad "$2" "${3:-}"; fi; }
command -v gpg >/dev/null || { echo "gpg is required for this test"; exit 1; }

# ---------------------------------------------------------------- throw-away keys: private key in one keyring, PUBLIC key only in the "server" keyring
mkdir -p "$T/gpg-priv" "$T/gpg-pub" "$T/bin" "$T/backups"; chmod 700 "$T/gpg-priv" "$T/gpg-pub" 2>/dev/null
export GNUPGHOME="$T/gpg-priv"
gpg --batch --quiet --pinentry-mode loopback --passphrase '' --quick-generate-key "backup-test <test@example.invalid>" default default never >/dev/null 2>&1
FPR=$(gpg --batch --with-colons --list-keys test@example.invalid 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}')
[ -n "$FPR" ] || { echo "could not create a test key"; exit 1; }
gpg --batch --export "$FPR" >"$T/pub.gpg"
GNUPGHOME="$T/gpg-pub" gpg --batch --quiet --import "$T/pub.gpg" >/dev/null 2>&1

# ---------------------------------------------------------------- fakes
cat >"$T/bin/docker" <<'EOF'
#!/usr/bin/env bash
T=$(dirname "$(dirname "$0")"); echo "docker $*" >>"$T/docker.log"
sub=$1; shift
cname() { while [ $# -gt 0 ]; do case "$1" in -e) shift 2 ;; -i|-t) shift ;; *) echo "$1"; return ;; esac; done; }
case "$sub" in
  inspect) c=${@: -1}
    case "$c" in prodflow-prod-db-1) svc=db ;; prodflow-prod-keycloak-db-1) svc=keycloak-db ;; *) exit 1 ;; esac
    proj=prodflow-prod; [ -e "$T/wrong_project" ] && proj=other
    run=true; [ -e "$T/stopped_$c" ] && run=false
    echo "$run|$proj|$svc|sha256:fakeimage" ;;
  exec) c=$(cname "$@"); shift_args=("$@")
    case "$*" in
      *printenv\ POSTGRES_USER*) case "$c" in prodflow-prod-db-1) echo prodflow ;; *) echo keycloak ;; esac ;;
      *printenv\ POSTGRES_DB*) case "$c" in prodflow-prod-db-1) echo prodflow ;; *) echo keycloak ;; esac ;;
      *pg_dump*) [ -e "$T/fail_$c" ] && exit 1; [ -e "$T/empty_$c" ] && exit 0; printf 'PGDMP-FAKE-%s-' "$c"; head -c 4000 /dev/zero | tr '\0' 'x' ;;
      *"show server_version_num"*) if [ -e "$T/old_pg" ]; then echo 150004; else echo 160015; fi ;;
      *"show server_version"*) echo 16.15 ;;
      *query_to_xml*) case "$c" in prodflow-prod-db-1) printf 'bom_line=4\nitem=6\nproduction_order=3\n' ;; *) printf 'client=7\nrealm=1\nuser_entity=3\nuser_session=2\n' ;; esac ;;
      *flyway_schema_history*) case "$c" in prodflow-prod-db-1|*-app) echo 100 ;; *) echo '' ;; esac ;;
      *pg_database_size*) echo 8123456 ;;
      *pg_isready*) exit 0 ;;
      *pg_restore*) cat >"$T/restored_${c##*-}.in"; sha256sum <"$T/restored_${c##*-}.in" | cut -c1-16 >"$T/restored_${c##*-}.sha"; [ -e "$T/restore_fail" ] && exit 1; exit 0 ;;
      *'select count(*) from public."'*) all="$*"; t=${all#*public.\"}; t=${t%%\"*}; f="$T/restore_counts_${c##*-}"; if [ -f "$f" ]; then grep "^$t=" "$f" | cut -d= -f2; else echo 0; fi ;;
      *"from client where"*) echo prodflow-api,prodflow-swagger,prodflow-web ;;
      *"from keycloak_role where"*) echo ADMIN,PLANNER,PURCHASER ;;
      *"from realm where name='prodflow'"*) echo 1 ;;
      *) echo "unexpected exec: $*" >&2; exit 9 ;;
    esac ;;
  ps) [ -e "$T/prod_containers_present" ] && echo prodflow-prod-backend-1; [ "${1:-}" = -aq ] && cat "$T/run_ids" 2>/dev/null; exit 0 ;;
  context) echo default ;;
  info) echo docker-desktop ;;
  version) exit 0 ;;
  network) exit 0 ;;
  run) n=""; while [ $# -gt 0 ]; do [ "$1" = --name ] && n=$2; shift; done; echo "$n" >>"$T/run_ids"; echo "id-$n" ;;
  rm) exit 0 ;;
  *) echo "unexpected docker $sub" >&2; exit 9 ;;
esac
EOF
printf '#!/usr/bin/env bash\n[ -e "$(dirname "$(dirname "$0")")/flock_busy" ] && exit 1\nexit 0\n' >"$T/bin/flock"
printf '#!/usr/bin/env bash\nexit 0\n' >"$T/bin/logger"
printf '#!/usr/bin/env bash\ncat "$(dirname "$(dirname "$0")")/hostname" 2>/dev/null || echo laptop\n' >"$T/bin/hostname"
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH"
cat >"$T/backup.conf" <<EOF
BACKUP_DIR=$T/backups
GNUPGHOME_BACKUP=$T/gpg-pub
RECIPIENT_FPR=$FPR
COMPOSE_PROJECT=prodflow-prod
KEEP_SETS=3
MIN_FREE_MB=1
DUMP_TIMEOUT_S=30
EOF
run_backup() { ( export BACKUP_CONF="$T/backup.conf" BACKUP_TEST_UID=0 GNUPGHOME="$T/gpg-pub"; bash "$B/backup-db.sh" "$@" ) >"$T/out.log" 2>&1; echo $?; }
sets() { ls -1d "$T/backups"/set-* 2>/dev/null | wc -l | tr -d ' '; }
last_set() { ls -1d "$T/backups"/set-* 2>/dev/null | sort | tail -1; }
reset_state() { rm -rf "$T/backups"/* "$T"/wrong_* "$T"/fail_* "$T"/empty_* "$T"/old_pg "$T"/flock_busy "$T"/stopped_* "$T/docker.log" 2>/dev/null; mkdir -p "$T/backups"; }

echo "== backup-db.sh: successful run"
reset_state; rc=$(run_backup --label pre-test)
S=$(last_set)
check $([ "$rc" = 0 ] && [ "$(sets)" = 1 ] && [ -f "$S/SET_OK" ] && [ ! -f "$S/SET_FAILED" ] && echo 0 || echo 1) 'one complete set with SET_OK' "exit $rc: $(tail -2 "$T/out.log" | tr '\n' ' ')"
check $([ -f "$S/app.dump.gpg" ] && [ -f "$S/keycloak.dump.gpg" ] && [ -f "$S/app.manifest" ] && [ -f "$S/keycloak.manifest" ] && [ -f "$S/SHA256SUMS" ] && echo 0 || echo 1) 'both encrypted dumps, both manifests and SHA256SUMS exist'
check $(( cd "$S" && sha256sum -c --quiet SHA256SUMS ) >/dev/null 2>&1 && echo 0 || echo 1) 'SHA256SUMS verifies'
check $(grep -rl 'PGDMP-FAKE' "$T/backups" >/dev/null 2>&1 && echo 1 || echo 0) 'the plaintext dump is NOT on the disk (encrypted while streaming)'
check $(find "$T/backups" -name '*.part' -o -name '*.tmp' -o -name '*.partial' | grep -q . && echo 1 || echo 0) 'no partial or temporary files are left behind'
dec=$(GNUPGHOME="$T/gpg-priv" gpg --batch --quiet --decrypt "$S/app.dump.gpg" 2>/dev/null | head -c 16)
check $([ "$dec" = "PGDMP-FAKE-prodf" ] && echo 0 || echo 1) 'the private key decrypts the dump' "$dec"
check $(GNUPGHOME="$T/gpg-pub" gpg --batch --quiet --decrypt "$S/app.dump.gpg" >/dev/null 2>&1 && echo 1 || echo 0) 'the server keyring (public key only) can NOT decrypt'
m="$S/app.manifest"
check $(grep -q '^database=prodflow$' "$m" && grep -q '^pg_major=16$' "$m" && grep -q '^label=pre-test$' "$m" && grep -q '^count.item=6$' "$m" && grep -q '^flyway_latest=100$' "$m" && grep -q "^recipient_fpr=$FPR$" "$m" && echo 0 || echo 1) 'manifest: database, PostgreSQL major, label, exact table counts, Flyway version, key fingerprint'
want=$(sed -n 's/^encrypted_sha256=//p' "$m"); have=$(sha256sum "$S/app.dump.gpg" | awk '{print $1}')
check $([ "$want" = "$have" ] && echo 0 || echo 1) 'manifest sha256 equals the file'
check $(grep -qiE 'password|secret|token|BEGIN' "$S"/*.manifest && echo 1 || echo 0) 'manifests contain no secret-looking content'
check $(grep -q 'PGOPTIONS=-c default_transaction_read_only=on' "$T/docker.log" && echo 0 || echo 1) 'database sessions are forced read-only'
check $(grep -E 'docker exec( -i)? [a-z-]+ (pg_dump)' "$T/docker.log" | grep -qE '(^| )-t( |$)' && echo 1 || echo 0) 'docker exec is never run with a TTY (binary-safe stream)'

echo "== backup-db.sh: guards (nothing may be written)"
reset_state; GNUPGHOME="$T/gpg-priv" gpg --batch --export-secret-keys "$FPR" 2>/dev/null | GNUPGHOME="$T/gpg-pub" gpg --batch --quiet --import >/dev/null 2>&1
rc=$(run_backup); check $([ "$rc" = 2 ] && grep -q 'PRIVATE key is present' "$T/out.log" && [ "$(sets)" = 0 ] && echo 0 || echo 1) 'a private key in the server keyring aborts the backup' "exit $rc"
rm -rf "$T/gpg-pub"; mkdir -p "$T/gpg-pub"; GNUPGHOME="$T/gpg-pub" gpg --batch --quiet --import "$T/pub.gpg" >/dev/null 2>&1
reset_state; touch "$T/wrong_project"; rc=$(run_backup)
check $([ "$rc" = 1 ] && grep -q 'does not belong to Compose project' "$T/out.log" && [ -f "$(last_set)/SET_FAILED" ] && echo 0 || echo 1) 'a container of another Compose project is refused' "exit $rc"
reset_state; touch "$T/old_pg"; rc=$(run_backup)
check $([ "$rc" = 1 ] && grep -q 'major version is 15' "$T/out.log" && echo 0 || echo 1) 'an unexpected PostgreSQL major version is refused' "exit $rc"
reset_state; touch "$T/stopped_prodflow-prod-db-1"; rc=$(run_backup)
check $([ "$rc" = 1 ] && grep -q 'is not running' "$T/out.log" && echo 0 || echo 1) 'a stopped container is refused' "exit $rc"
reset_state; sed -i 's/^MIN_FREE_MB=.*/MIN_FREE_MB=99999999/' "$T/backup.conf"; rc=$(run_backup)
check $([ "$rc" = 2 ] && grep -q 'less than' "$T/out.log" && [ "$(sets)" = 0 ] && echo 0 || echo 1) 'too little free disk space aborts before anything is written' "exit $rc"; sed -i 's/^MIN_FREE_MB=.*/MIN_FREE_MB=1/' "$T/backup.conf"
reset_state; rc=$(run_backup --label 'bad label;rm')
check $([ "$rc" = 2 ] && grep -q 'label' "$T/out.log" && echo 0 || echo 1) 'an unsafe --label is rejected' "exit $rc"
cp "$T/backup.conf" "$T/backup.conf.keep"; sed -i 's/^RECIPIENT_FPR=.*/RECIPIENT_FPR=1234/' "$T/backup.conf"; rc=$(run_backup)
check $([ "$rc" = 2 ] && grep -q 'RECIPIENT_FPR' "$T/out.log" && echo 0 || echo 1) 'a malformed key fingerprint is rejected' "exit $rc"; cp "$T/backup.conf.keep" "$T/backup.conf"
sed -i 's#^BACKUP_DIR=.*#BACKUP_DIR=/var/lib/docker/volumes/x#' "$T/backup.conf"; ( export BACKUP_CONF="$T/backup.conf" GNUPGHOME="$T/gpg-pub"; bash "$B/backup-db.sh" ) >"$T/out.log" 2>&1; rc=$?
check $([ "$rc" = 2 ] && echo 0 || echo 1) 'refuses to run unprivileged and a BACKUP_DIR inside Docker volumes' "exit $rc"; cp "$T/backup.conf.keep" "$T/backup.conf"

echo "== backup-db.sh: failure handling"
reset_state; touch "$T/fail_prodflow-prod-keycloak-db-1"; rc=$(run_backup); S=$(last_set)
check $([ "$rc" = 1 ] && [ -f "$S/SET_FAILED" ] && [ ! -f "$S/SET_OK" ] && [ -f "$S/app.dump.gpg" ] && [ ! -f "$S/keycloak.dump.gpg" ] && echo 0 || echo 1) 'one failing dump: exit 1, set marked SET_FAILED, the other database is still backed up, no half file' "exit $rc"
check $(find "$T/backups" -name '*.part' | grep -q . && echo 1 || echo 0) 'a failed dump leaves no .part file'
reset_state; touch "$T/empty_prodflow-prod-db-1"; rc=$(run_backup)
check $([ "$rc" = 1 ] && grep -q 'bytes' "$T/out.log" && echo 0 || echo 1) 'an empty dump is detected and rejected' "exit $rc"
reset_state; touch "$T/flock_busy"; rc=$(run_backup)
check $([ "$rc" = 3 ] && [ "$(sets)" = 0 ] && echo 0 || echo 1) 'a second backup while one is running exits 3 and writes nothing' "exit $rc"

echo "== backup-db.sh: --check creates nothing"
reset_state; rm -rf "$T/backups"; rc=$(run_backup --check)
check $([ "$rc" = 0 ] && [ ! -e "$T/backups" ] && ! grep -q pg_dump "$T/docker.log" && echo 0 || echo 1) '--check passes, creates no directory and never calls pg_dump' "exit $rc"; mkdir -p "$T/backups"

echo "== backup-db.sh: retention (KEEP_SETS=3)"
reset_state
for i in 1 2 3 4 5; do mkdir -p "$T/backups/set-2026100${i}T030000Z"; echo x >"$T/backups/set-2026100${i}T030000Z/SET_OK"; done
mkdir -p "$T/backups/set-20261009T030000Z"; echo failed >"$T/backups/set-20261009T030000Z/SET_FAILED"; mkdir -p "$T/backups/not-a-set"
rc=$(run_backup)
check $([ "$rc" = 0 ] && [ "$(ls -1d "$T"/backups/set-* | wc -l | tr -d ' ')" = 4 ] && [ ! -d "$T/backups/set-20261001T030000Z" ] && [ ! -d "$T/backups/set-20261002T030000Z" ] && [ ! -d "$T/backups/set-20261003T030000Z" ] && [ -d "$T/backups/set-20261005T030000Z" ] && echo 0 || echo 1) 'only the oldest complete sets beyond KEEP_SETS are pruned (3 newest complete sets stay, incl. the new one)' "$(ls "$T/backups" | tr '\n' ' ')"
check $([ -d "$T/backups/not-a-set" ] && [ -d "$T/backups/set-20261009T030000Z" ] && echo 0 || echo 1) 'unrelated directories and recent failed sets are never touched by the pruning'

echo "== fetch-backups.sh (fake ssh, local tar stands in for the server)"
reset_state; rc=$(run_backup); S=$(last_set); SNAME=$(basename "$S")
cat >"$T/bin/ssh" <<'EOF'
#!/usr/bin/env bash
T=$(dirname "$(dirname "$0")"); cmd=${*: -1}; echo "ssh $cmd" >>"$T/ssh.log"
case "$cmd" in
  *"for d in set-*"*) for d in "$T"/backups/set-*; do [ -f "$d/SET_OK" ] && basename "$d"; done ;;
  *"tar -C"*) set=${cmd##* }; [ -e "$T/ssh_fail" ] && exit 1; tar -C "$T/backups" -cf - "$set" ;;
  *) echo "unexpected ssh: $cmd" >&2; exit 9 ;;
esac
EOF
chmod +x "$T/bin/ssh"; : >"$T/key.pem"; DEST="$T/laptop"
fetch() { bash "$B/fetch-backups.sh" --host ubuntu@203.0.113.9 --key "$T/key.pem" --dest "$DEST" "$@" >"$T/fetch.log" 2>&1; echo $?; }
rc=$(fetch); check $([ "$rc" = 0 ] && [ -f "$DEST/$SNAME/FETCHED_OK" ] && [ -f "$DEST/$SNAME/app.dump.gpg" ] && echo 0 || echo 1) 'a complete set is pulled, verified and marked FETCHED_OK' "exit $rc: $(tail -2 "$T/fetch.log" | tr '\n' ' ')"
check $(grep -qE 'rm |delete' "$T/ssh.log" && echo 1 || echo 0) 'nothing is ever deleted or changed on the server'
rc=$(fetch); check $([ "$rc" = 0 ] && grep -q 'already present' "$T/fetch.log" && echo 0 || echo 1) 'a second run does not download again' "exit $rc"
rm -rf "$DEST"; echo tampered >>"$S/app.dump.gpg"; rc=$(fetch)
check $([ "$rc" = 1 ] && [ ! -d "$DEST/$SNAME" ] && grep -q 'verification failed' "$T/fetch.log" && echo 0 || echo 1) 'a set that does not match SHA256SUMS is rejected and removed' "exit $rc"
rm -rf "$DEST"; reset_state; run_backup >/dev/null; touch "$T/ssh_fail"; rc=$(fetch); rm -f "$T/ssh_fail"
check $([ "$rc" = 1 ] && [ ! -d "$DEST/$(basename "$(last_set)")" ] && echo 0 || echo 1) 'a failed transfer leaves no partial set and exits 1' "exit $rc"
rc=$(bash "$B/fetch-backups.sh" --host ubuntu@203.0.113.9 --key "$T/key.pem" --dest "$HERE/../frontend/zz-fetch-inside-repo" >"$T/fetch.log" 2>&1; echo $?)
check $([ "$rc" = 2 ] && grep -q 'Git work tree' "$T/fetch.log" && echo 0 || echo 1) 'a destination inside a Git repository is refused' "exit $rc"; rm -rf "$HERE/../frontend/zz-fetch-inside-repo"

echo "== restore-test.sh (fake docker; real gpg decryption)"
reset_state; rc=$(run_backup); S=$(last_set); : >"$T/run_ids"; : >"$T/docker.log"   # the restore test is judged on its own docker calls only
printf 'bom_line=4\nitem=6\nproduction_order=3\n' >"$T/restore_counts_app"; printf 'client=7\nrealm=1\nuser_entity=3\nuser_session=9\n' >"$T/restore_counts_keycloak"
restore() { ( export GNUPGHOME="$T/gpg-priv"; bash "$B/restore-test.sh" --set "$S" "$@" ) >"$T/restore.log" 2>&1; echo $?; }
rc=$(restore)
check $([ "$rc" = 0 ] && grep -q 'RESULT: all checks passed' "$T/restore.log" && echo 0 || echo 1) 'restore + verification of both databases passes' "exit $rc: $(grep -E 'FAIL|REFUSED' "$T/restore.log" | head -3 | tr '\n' ' ')"
check $(head -c 16 "$T/restored_app.in" | grep -q 'PGDMP-FAKE-prodf' && echo 0 || echo 1) 'pg_restore receives exactly the decrypted dump'
check $(grep -q -- '--exit-on-error' "$T/docker.log" && grep -q -- '--no-owner' "$T/docker.log" && echo 0 || echo 1) 'pg_restore runs with --exit-on-error and --no-owner'
check $(grep -E '^docker run' "$T/docker.log" | grep -qE -- ' -p |--publish' && echo 1 || echo 0) 'the disposable containers publish no ports'
check $(grep -E '^docker run' "$T/docker.log" | grep -q -- '--tmpfs /var/lib/postgresql/data' && grep -q 'network create --internal' "$T/docker.log" && echo 0 || echo 1) 'data on tmpfs, isolated internal network'
check $(grep -E '^docker (run|exec|rm)' "$T/docker.log" | grep -E 'prodflow-prod' | grep -q . && echo 1 || echo 0) 'no command ever names a production container'
check $(grep -q '^docker rm -f' "$T/docker.log" && grep -q '^docker network rm' "$T/docker.log" && echo 0 || echo 1) 'only the containers and the network created by the run are removed afterwards'
printf 'bom_line=4\nitem=5\nproduction_order=3\n' >"$T/restore_counts_app"; rc=$(restore --only app)
check $([ "$rc" = 1 ] && grep -q 'table item has 5 rows, manifest says 6' "$T/restore.log" && echo 0 || echo 1) 'a row-count difference fails the test' "exit $rc"
printf 'bom_line=4\nitem=6\nproduction_order=3\n' >"$T/restore_counts_app"; touch "$T/restore_fail"; rc=$(restore --only app); rm -f "$T/restore_fail"
check $([ "$rc" = 1 ] && grep -q 'decrypt or restore failed' "$T/restore.log" && echo 0 || echo 1) 'a failing pg_restore fails the test' "exit $rc"
rc=$( ( export GNUPGHOME="$T/gpg-pub"; bash "$B/restore-test.sh" --set "$S" --only app ) >"$T/restore.log" 2>&1; echo $?)
check $([ "$rc" = 1 ] && grep -q 'decrypt or restore failed' "$T/restore.log" && echo 0 || echo 1) 'without the private key the restore cannot decrypt' "exit $rc"
echo "-- guards"
touch "$T/prod_containers_present"; rc=$(restore); check $([ "$rc" = 2 ] && grep -q 'production containers' "$T/restore.log" && echo 0 || echo 1) 'refuses when production containers exist on the Docker engine' "exit $rc"; rm -f "$T/prod_containers_present"
echo ip-172-31-39-74 >"$T/hostname"; rc=$(restore); check $([ "$rc" = 2 ] && grep -q 'AWS instance' "$T/restore.log" && echo 0 || echo 1) 'refuses on a host named like an AWS instance' "exit $rc"; rm -f "$T/hostname"
rc=$( ( export GNUPGHOME="$T/gpg-priv" DOCKER_HOST=tcp://203.0.113.9:2375; bash "$B/restore-test.sh" --set "$S" ) >"$T/restore.log" 2>&1; echo $?); check $([ "$rc" = 2 ] && grep -q 'DOCKER_HOST' "$T/restore.log" && echo 0 || echo 1) 'refuses a remote Docker daemon (DOCKER_HOST)' "exit $rc"
echo tampered >>"$S/keycloak.dump.gpg"; rc=$(restore); check $([ "$rc" = 2 ] && grep -q 'SHA256SUMS' "$T/restore.log" && echo 0 || echo 1) 'a damaged set is refused before anything is created' "exit $rc"
rc=$(bash "$B/restore-test.sh" --set "$T/not-a-set" >"$T/restore.log" 2>&1; echo $?); check $([ "$rc" = 2 ] && echo 0 || echo 1) 'a directory that is not a set is refused' "exit $rc"
check $(grep -nE -- '--target|--host|--db-host|HOST=|-h [0-9a-z]' "$B/restore-test.sh" | grep -vE 'pg_isready|DOCKER_HOST|hostname' | grep -q . && echo 1 || echo 0) 'the restore script has no option that selects a target host or database'

echo "test-backup-scripts result: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
