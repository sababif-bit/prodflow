#!/usr/bin/env bash
# DRAFT (S10B design, 2026-10-20): NOT installed anywhere, NEVER run against production. Server-side logical backup of both ProdFlow databases.
#
#   backup-db.sh [--check] [--label <text>]
#
# What it does (details and reasoning: docs/backup-recovery-konzept.md):
#   - pg_dump -Fc of the application database (container <project>-db-1) and the Keycloak database (<project>-keycloak-db-1),
#     run INSIDE the containers over their local socket (no database password is ever handled or printed);
#   - encrypts the stream with a PUBLIC key while it flows (gpg, public-key only keyring): the plaintext dump never touches the disk,
#     and the private key must NOT exist on this machine (the script aborts if a secret key is present);
#   - writes one directory per run, "set-<UTC timestamp>", mode 700 under BACKUP_DIR (root only), files mode 600: <name>.dump.gpg,
#     <name>.manifest (plain key=value: versions, sizes, sha256, exact table counts; no secrets), SHA256SUMS, and SET_OK or SET_FAILED;
#   - prunes old complete sets (KEEP_SETS), never the newest one.
# It only READS the databases (the psql sessions are forced read-only). It never stops, restarts or reconfigures a service.
#
#   --check   run every precondition and print what would happen; creates nothing, dumps nothing
#   --label   short tag stored in the manifest (for example pre-reset, pre-deploy); [A-Za-z0-9_-], up to 32 characters
#
# Exit: 0 = complete set written, 1 = a database could not be backed up (set marked SET_FAILED), 2 = precondition failed (nothing done),
#       3 = another backup is running.
# Configuration: /etc/prodflow-backup/backup.conf (root-owned, mode 600, no secrets; template: scripts/backup/backup.conf.example).
set -u -o pipefail
export LC_ALL=C
SCRIPT_VERSION=1
CONF=${BACKUP_CONF:-/etc/prodflow-backup/backup.conf}
CHECK_ONLY=0
LABEL=''

usage() { echo "usage: $0 [--check] [--label <text>]" >&2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK_ONLY=1; shift ;;
    --label) LABEL=${2:-}; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done

# permission checks are skipped only when the test hook BACKUP_TEST_UID is set (file modes are not reliable on a Windows file system)
private_mode() { [ -n "${BACKUP_TEST_UID:-}" ] && return 0; [ $(( 0$(stat -c %a "$1" | tail -c 4) & 077 )) -eq 0 ]; }
log() { local m; m="$(date -u +%FT%TZ) backup: $*"; echo "$m"; command -v logger >/dev/null 2>&1 && logger -t prodflow-backup -- "$*" 2>/dev/null; return 0; }
die() { log "ABORT: $*"; exit 2; }

# ---------------------------------------------------------------- preconditions on the machine and the configuration
# BACKUP_TEST_UID exists only so that tests can run unprivileged; on the server the real uid is used.
[ "${BACKUP_TEST_UID:-$(id -u)}" = 0 ] || die "must run as root (sudo): the backup directory is root-only"
for t in docker gpg sha256sum flock timeout df awk stat date; do command -v "$t" >/dev/null 2>&1 || die "missing tool: $t"; done
[ -f "$CONF" ] || die "configuration $CONF not found"
[ "$(stat -c %u "$CONF")" = "$(id -u)" ] || die "$CONF must be owned by the user running the backup (root)"
private_mode "$CONF" || die "$CONF must not be accessible to group/others (chmod 600)"
# shellcheck disable=SC1090
. "$CONF"
BACKUP_DIR=${BACKUP_DIR:-/var/backups/prodflow}
GNUPGHOME_BACKUP=${GNUPGHOME_BACKUP:-/etc/prodflow-backup/gnupg}
COMPOSE_PROJECT=${COMPOSE_PROJECT:-prodflow-prod}
KEEP_SETS=${KEEP_SETS:-7}
MIN_FREE_MB=${MIN_FREE_MB:-1024}
DUMP_TIMEOUT_S=${DUMP_TIMEOUT_S:-300}
EXPECT_PG_MAJOR=${EXPECT_PG_MAJOR:-16}
RECIPIENT_FPR=${RECIPIENT_FPR:-}
[[ $BACKUP_DIR =~ ^/[A-Za-z0-9._/-]+$ ]] || die "BACKUP_DIR must be an absolute path without special characters"
[[ $GNUPGHOME_BACKUP =~ ^/[A-Za-z0-9._/-]+$ ]] || die "GNUPGHOME_BACKUP must be an absolute path without special characters"
[[ $COMPOSE_PROJECT =~ ^[a-z0-9][a-z0-9_-]*$ ]] || die "COMPOSE_PROJECT is not a valid Compose project name"
[[ $RECIPIENT_FPR =~ ^[0-9A-F]{40}$ ]] || die "RECIPIENT_FPR must be the 40-character hexadecimal fingerprint of the PUBLIC key"
[[ $KEEP_SETS =~ ^[0-9]+$ ]] && [ "$KEEP_SETS" -ge 2 ] && [ "$KEEP_SETS" -le 60 ] || die "KEEP_SETS must be between 2 and 60"
[[ $MIN_FREE_MB =~ ^[0-9]+$ ]] && [[ $DUMP_TIMEOUT_S =~ ^[0-9]+$ ]] || die "MIN_FREE_MB and DUMP_TIMEOUT_S must be numbers"
case "$BACKUP_DIR" in /var/lib/docker*|/proc*|/sys*|/dev*|/tmp|/tmp/*) [ -n "${BACKUP_TEST_UID:-}" ] || die "BACKUP_DIR must not live under /var/lib/docker, /tmp or a pseudo filesystem" ;; esac
[[ -z $LABEL || $LABEL =~ ^[A-Za-z0-9_-]{1,32}$ ]] || die "--label must match [A-Za-z0-9_-]{1,32}"

# ---------------------------------------------------------------- the encryption key: public part only, private key must be absent
gpgq() { gpg --homedir "$GNUPGHOME_BACKUP" --batch --no-tty --no-autostart "$@"; }
[ -d "$GNUPGHOME_BACKUP" ] || die "keyring directory $GNUPGHOME_BACKUP not found"
private_mode "$GNUPGHOME_BACKUP" || die "$GNUPGHOME_BACKUP must be mode 700"
if [ -n "$(gpgq --list-secret-keys --with-colons 2>/dev/null | grep -E '^(sec|ssb):' || true)" ]; then
  die "a PRIVATE key is present in $GNUPGHOME_BACKUP: backups would be decryptable on this machine. Remove it; keep the private key on the laptop only"
fi
KEYINFO=$(gpgq --list-keys --with-colons "$RECIPIENT_FPR" 2>/dev/null | grep -E '^(pub|fpr):' || true)
[ -n "$KEYINFO" ] || die "public key $RECIPIENT_FPR not found in $GNUPGHOME_BACKUP"
if grep -qE '^pub:[er]:' <<<"$KEYINFO"; then die "the public key is expired or revoked"; fi

# ---------------------------------------------------------------- the databases (read-only checks only)
TARGETS=( "app:${COMPOSE_PROJECT}-db-1:db:prodflow" "keycloak:${COMPOSE_PROJECT}-keycloak-db-1:keycloak-db:keycloak" )
psqlq() { local c=$1 u=$2 d=$3; shift 3; docker exec -e PGOPTIONS='-c default_transaction_read_only=on' "$c" psql -U "$u" -d "$d" -X -At -v ON_ERROR_STOP=1 -P pager=off "$@"; }
check_target() { # name container service expected_db -> sets T_USER T_DB T_IMAGE T_PGVER ; returns 1 with a message when not acceptable
  local name=$1 c=$2 svc=$3 exp=$4 info running proj service num
  info=$(docker inspect -f '{{.State.Running}}|{{index .Config.Labels "com.docker.compose.project"}}|{{index .Config.Labels "com.docker.compose.service"}}|{{.Image}}' "$c" 2>/dev/null) || { log "$name: container $c not found"; return 1; }
  IFS='|' read -r running proj service T_IMAGE <<<"$info"
  [ "$running" = true ] || { log "$name: container $c is not running"; return 1; }
  [ "$proj" = "$COMPOSE_PROJECT" ] && [ "$service" = "$svc" ] || { log "$name: container $c does not belong to Compose project $COMPOSE_PROJECT / service $svc"; return 1; }
  T_USER=$(docker exec "$c" printenv POSTGRES_USER 2>/dev/null) || { log "$name: cannot read the database user"; return 1; }
  T_DB=$(docker exec "$c" printenv POSTGRES_DB 2>/dev/null) || { log "$name: cannot read the database name"; return 1; }
  [ "$T_DB" = "$exp" ] || { log "$name: database is '$T_DB', expected '$exp'"; return 1; }
  num=$(psqlq "$c" "$T_USER" "$T_DB" -c 'show server_version_num' 2>/dev/null) || { log "$name: database does not answer"; return 1; }
  [[ $num =~ ^[0-9]+$ ]] && [ $((num / 10000)) -eq "$EXPECT_PG_MAJOR" ] || { log "$name: PostgreSQL major version is $((num / 10000)), expected $EXPECT_PG_MAJOR"; return 1; }
  T_PGVER=$(psqlq "$c" "$T_USER" "$T_DB" -c 'show server_version' 2>/dev/null)
  return 0
}

free_mb() { df -Pm "$1" 2>/dev/null | awk 'NR==2{print $4}'; }
if [ "$CHECK_ONLY" = 1 ]; then
  rc=0
  for t in "${TARGETS[@]}"; do IFS=: read -r name c svc exp <<<"$t"; if check_target "$name" "$c" "$svc" "$exp"; then log "check ok: $name ($c, database $T_DB, PostgreSQL $T_PGVER)"; else rc=2; fi; done
  probe=$BACKUP_DIR; [ -d "$probe" ] || probe=$(dirname "$BACKUP_DIR")   # check mode creates nothing
  fm=$(free_mb "$probe"); [ -n "$fm" ] && [ "$fm" -ge "$MIN_FREE_MB" ] || { log "free space ${fm:-unknown} MB is below MIN_FREE_MB=$MIN_FREE_MB"; rc=2; }
  log "check finished (nothing was created or dumped): exit $rc"; exit $rc
fi

[ -d "$BACKUP_DIR" ] || mkdir -m 700 "$BACKUP_DIR" || die "cannot create $BACKUP_DIR"
{ [ -n "${BACKUP_TEST_UID:-}" ] || [ "$(stat -c %a "$BACKUP_DIR")" = 700 ]; } || die "$BACKUP_DIR must exist with mode 700"
[ "$(free_mb "$BACKUP_DIR")" -ge "$MIN_FREE_MB" ] 2>/dev/null || die "less than ${MIN_FREE_MB} MB free in $BACKUP_DIR"
exec 8>"$BACKUP_DIR/.lock"
flock -n 8 || { log "another backup is running"; exit 3; }
umask 077

TS=$(date -u +%Y%m%dT%H%M%SZ)
SET="set-$TS"
WORK="$BACKUP_DIR/$SET.partial"
cleanup_parts() { [ -d "$WORK" ] && rm -f "$WORK"/*.part "$WORK"/*.tmp 2>/dev/null; return 0; }
trap cleanup_parts EXIT
mkdir -m 700 "$WORK" || die "cannot create $WORK"
log "start set $SET (script v$SCRIPT_VERSION${LABEL:+, label $LABEL})"

FAILED=()
backup_one() { # name container service expected_db
  local name=$1 c=$2 svc=$3 exp=$4 out man start bytes sha counts flyway dbbytes rc packets
  check_target "$name" "$c" "$svc" "$exp" || return 1
  out="$WORK/$name.dump.gpg"; man="$WORK/$name.manifest"
  counts=$(psqlq "$c" "$T_USER" "$T_DB" -c "select table_name||'='||(xpath('/row/c/text()', query_to_xml(format('select count(*) as c from %I.%I', table_schema, table_name), false, true, '')))[1]::text from information_schema.tables where table_schema='public' and table_type='BASE TABLE' order by 1") || { log "$name: table counts failed"; return 1; }
  flyway=$(psqlq "$c" "$T_USER" "$T_DB" -c "select case when to_regclass('public.flyway_schema_history') is null then '' else coalesce((select version from flyway_schema_history where success order by installed_rank desc limit 1),'') end") || flyway=''
  dbbytes=$(psqlq "$c" "$T_USER" "$T_DB" -c 'select pg_database_size(current_database())') || dbbytes=''
  start=$SECONDS
  # the dump streams straight into gpg; pipefail makes a failure of either side fail the whole step
  timeout "$DUMP_TIMEOUT_S" docker exec "$c" pg_dump -U "$T_USER" -d "$T_DB" -Fc -Z 6 \
    | gpgq --yes --trust-model always --cipher-algo AES256 -z 0 --recipient "$RECIPIENT_FPR" --encrypt --output "$out.part"
  rc=$?
  if [ $rc -ne 0 ]; then log "$name: dump or encryption failed (exit $rc)"; rm -f "$out.part"; return 1; fi
  bytes=$(stat -c %s "$out.part")
  [ "$bytes" -ge 1024 ] || { log "$name: encrypted dump is only $bytes bytes (empty dump?)"; rm -f "$out.part"; return 1; }
  packets=$(gpgq --list-packets "$out.part" 2>/dev/null)   # captured first: 'grep -q' on a pipe would end gpg early and trip pipefail
  [[ $packets == *'pubkey enc packet'* ]] || { log "$name: result is not public-key encrypted"; rm -f "$out.part"; return 1; }
  mv "$out.part" "$out"
  sha=$(sha256sum "$out" | awk '{print $1}')
  {
    echo "manifest_version=1"
    echo "script_version=$SCRIPT_VERSION"
    echo "set=$SET"
    echo "name=$name"
    echo "created_utc=$TS"
    echo "label=$LABEL"
    echo "host=$(hostname)"
    echo "container=$c"
    echo "image_id=$T_IMAGE"
    echo "database=$T_DB"
    echo "pg_version=$T_PGVER"
    echo "pg_major=$EXPECT_PG_MAJOR"
    echo "db_bytes=$dbbytes"
    echo "flyway_latest=$flyway"
    echo "dump_format=custom;compress=6"
    echo "recipient_fpr=$RECIPIENT_FPR"
    echo "encrypted_file=$name.dump.gpg"
    echo "encrypted_bytes=$bytes"
    echo "encrypted_sha256=$sha"
    echo "dump_seconds=$((SECONDS - start))"
    printf '%s\n' "$counts" | sed 's/^/count./'
  } >"$man.tmp" && mv "$man.tmp" "$man"
  log "$name: ok ($bytes bytes encrypted, $((SECONDS - start)) s)"
  return 0
}

for t in "${TARGETS[@]}"; do
  IFS=: read -r name c svc exp <<<"$t"
  backup_one "$name" "$c" "$svc" "$exp" || FAILED+=("$name")
done

( cd "$WORK" && ls ./*.gpg ./*.manifest >/dev/null 2>&1 && sha256sum -- *.gpg *.manifest >SHA256SUMS )
FINAL="$BACKUP_DIR/$SET"
if [ ${#FAILED[@]} -eq 0 ]; then
  date -u +%FT%TZ >"$WORK/SET_OK"
  mv "$WORK" "$FINAL"
  log "set $SET complete"
else
  printf 'failed: %s\n' "${FAILED[*]}" >"$WORK/SET_FAILED"
  mv "$WORK" "$FINAL"
  log "set $SET INCOMPLETE, failed: ${FAILED[*]}"
fi
trap - EXIT

# ---------------------------------------------------------------- retention (only well-formed names inside BACKUP_DIR are ever deleted)
prune() {
  local d n=0 name
  while IFS= read -r d; do
    name=$(basename "$d")
    [[ $name =~ ^set-[0-9]{8}T[0-9]{6}Z$ ]] || continue
    if [ -f "$d/SET_OK" ]; then n=$((n + 1)); [ "$n" -gt "$KEEP_SETS" ] && { rm -rf -- "$d"; log "pruned old set $name"; }; fi
  done < <(ls -1d "$BACKUP_DIR"/set-* 2>/dev/null | sort -r)
  find "$BACKUP_DIR" -maxdepth 1 -type d -name 'set-*.partial' -mtime +1 -exec rm -rf -- {} + 2>/dev/null
  find "$BACKUP_DIR" -maxdepth 1 -type d -name 'set-*' -mtime +14 -exec sh -c 'for d; do [ -f "$d/SET_FAILED" ] && rm -rf -- "$d"; done' sh {} + 2>/dev/null
  return 0
}
prune
[ ${#FAILED[@]} -eq 0 ]
