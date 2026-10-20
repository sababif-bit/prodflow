#!/usr/bin/env bash
# DRAFT (S10B design, 2026-10-20): NOT used yet. Isolated restore test of a fetched backup set on THIS computer (the laptop), in disposable Docker containers.
#
#   restore-test.sh --set <directory of a fetched set, e.g. ~/prodflow-backups-enc/set-20261021T031500Z> [--only app|keycloak] [--keep]
#
# It proves that a backup can really be restored and that the restored data matches what the manifest recorded at backup time:
#   1. refuses to run anywhere near production (see the guards below) and verifies SHA256SUMS of the set;
#   2. creates its OWN network (--internal: no route out, nothing can reach it) and ONE container per database from postgres:<major>-alpine,
#      data on tmpfs (nothing persists), random password, no published ports, all labelled pfrestore=<run id>;
#   3. decrypts with the private key from the local gpg keyring (a passphrase prompt may appear) and streams the plaintext straight into
#      pg_restore --exit-on-error: the plaintext dump never touches the disk;
#   4. compares the restored data with the manifest (exact table counts, Flyway version; for Keycloak the realm, the three clients and the three roles)
#      and checks the structure (no NOT VALID constraint, no invalid index, sequences within their bounds; constraint/index/sequence counts against
#      the struct.* lines of a script-v2 manifest). All catalog queries are read-only and show no table values;
#   5. removes exactly the containers and the network it created (unless --keep).
# THERE IS NO PARAMETER THAT SELECTS A TARGET: the only restore target this script can ever write to is the throw-away container it creates itself.
# Restoring into production is deliberately NOT part of this script (see docs/backup-recovery-konzept.md, section "Echte Wiederherstellung").
# Exit: 0 = all checks passed, 1 = a check failed, 2 = precondition/guard failed (nothing created), 3 = Docker problem.
set -u -o pipefail
export LC_ALL=C MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
SETDIR=''; ONLY=''; KEEP=0
usage() { echo "usage: $0 --set <fetched set directory> [--only app|keycloak] [--keep]" >&2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --set) SETDIR=${2:-}; shift 2 ;;
    --only) ONLY=${2:-}; shift 2 ;;
    --keep) KEEP=1; shift ;;
    *) usage; exit 2 ;;
  esac
done
say() { echo "restore-test: $*"; }
refuse() { echo "restore-test: REFUSED: $*" >&2; exit 2; }

# ---------------------------------------------------------------- guards: never next to production, never against a remote Docker daemon
[ -d "$SETDIR" ] || { usage; refuse "--set must be an existing directory"; }
[[ $(basename "$SETDIR") =~ ^set-[0-9]{8}T[0-9]{6}Z$ ]] || refuse "the directory name must be set-<timestamp> (a set written by backup-db.sh)"
[ -z "$ONLY" ] || [ "$ONLY" = app ] || [ "$ONLY" = keycloak ] || refuse "--only must be app or keycloak"
for t in docker gpg sha256sum openssl sed awk; do command -v "$t" >/dev/null 2>&1 || refuse "missing tool: $t"; done
[ -z "${DOCKER_HOST:-}" ] || refuse "DOCKER_HOST is set: this script only talks to the local Docker engine"
case "$(docker context show 2>/dev/null || echo unknown)" in default|desktop-linux|desktop-windows|colima) ;; *) refuse "the Docker context is not a known local one" ;; esac
for h in "$(hostname 2>/dev/null)" "$(docker info --format '{{.Name}}' 2>/dev/null)"; do
  [[ $h =~ ^ip-[0-9]+-[0-9]+-[0-9]+-[0-9]+$ ]] && refuse "this looks like an AWS instance ($h); run the restore test on the laptop"
done
[ ! -e /opt/prodflow/repo/deploy/.env ] || refuse "a production deploy/.env exists on this machine"
if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qE '^prodflow-prod-'; then refuse "production containers (prodflow-prod-*) exist on this Docker engine"; fi
[ -f "$SETDIR/SET_OK" ] && [ -f "$SETDIR/SHA256SUMS" ] || refuse "the set is incomplete (SET_OK or SHA256SUMS missing)"
( cd "$SETDIR" && sha256sum -c --quiet SHA256SUMS >/dev/null 2>&1 ) || refuse "SHA256SUMS verification failed: the set is damaged"
docker version >/dev/null 2>&1 || { echo "restore-test: Docker is not available" >&2; exit 3; }

now_ms() { local n; n=$(date +%s%3N 2>/dev/null); [[ $n =~ ^[0-9]+$ ]] && echo "$n" || echo $((SECONDS * 1000)); }
RUN="pfrestore-$(date +%s)-$RANDOM"
mget() { sed -n "s/^$2=//p" "$1" | head -1; }
FAILS=0
ok() { say "PASS  $1"; }
bad() { say "FAIL  $1"; FAILS=$((FAILS + 1)); }
cleanup() {
  if [ "$KEEP" = 1 ]; then say "kept for inspection: network $RUN and containers labelled pfrestore=$RUN (remove with: docker rm -f \$(docker ps -aq --filter label=pfrestore=$RUN); docker network rm $RUN)"; return; fi
  local ids; ids=$(docker ps -aq --filter "label=pfrestore=$RUN" 2>/dev/null)
  [ -n "$ids" ] && docker rm -f $ids >/dev/null 2>&1
  docker network rm "$RUN" >/dev/null 2>&1
  return 0
}
trap cleanup EXIT
docker network create --internal --label "pfrestore=$RUN" "$RUN" >/dev/null || { echo "restore-test: cannot create the isolated network" >&2; exit 3; }

# Structure of the restored database: constraints, indexes, sequences. Read-only catalog queries; no table values are shown or compared.
# Keep STRUCT_SQL identical to backup-db.sh (it produces the struct.* manifest lines; scripts/test-backup-roundtrip.sh proves they agree).
STRUCT_SQL="/* pf:structure */ select 'struct.constraint.'||c.contype::text||'='||count(*) from pg_constraint c join pg_namespace n on n.oid=c.connamespace where n.nspname not in ('pg_catalog','information_schema','pg_toast') group by c.contype union all select 'struct.indexes='||count(*) from pg_indexes where schemaname not in ('pg_catalog','information_schema','pg_toast') union all select 'struct.sequences='||count(*) from pg_sequences where schemaname not in ('pg_catalog','information_schema','pg_toast') order by 1"
check_structure() { # uses $name, $man and rq() of restore_one
  local n want have behind
  # always (also for sets written by script v1, whose manifest has no struct.* lines): nothing may be left invalid by the restore
  n=$(rq "/* pf:invalid-constraints */ select count(*) from pg_constraint c join pg_namespace s on s.oid=c.connamespace where not c.convalidated and s.nspname not in ('pg_catalog','information_schema','pg_toast')" 2>/dev/null) || n=error
  [ "$n" = 0 ] && ok "$name: every constraint is validated (no NOT VALID constraint)" || bad "$name: NOT VALID constraints after the restore: $n"
  n=$(rq "/* pf:invalid-indexes */ select count(*) from pg_index i join pg_class k on k.oid=i.indexrelid join pg_namespace s on s.oid=k.relnamespace where (not i.indisvalid or not i.indisready) and s.nspname not in ('pg_catalog','information_schema','pg_toast')" 2>/dev/null) || n=error
  [ "$n" = 0 ] && ok "$name: every index is valid and ready" || bad "$name: invalid or not-ready indexes after the restore: $n"
  n=$(rq "/* pf:sequence-bounds */ select count(*) from pg_sequences where schemaname not in ('pg_catalog','information_schema','pg_toast') and last_value is not null and (last_value < min_value or last_value > max_value)" 2>/dev/null) || n=error
  [ "$n" = 0 ] && ok "$name: every sequence value lies within its own bounds" || bad "$name: sequences outside their bounds after the restore: $n"
  # against the manifest (sets written by script v2 or later)
  have=$(rq "$STRUCT_SQL" 2>/dev/null | grep '^struct\.' | sort) || have=''
  want=$(grep '^struct\.' "$man" | sort)
  if [ -z "$want" ]; then
    say "INFO  $name: the manifest has no struct.* lines (written by script v1): constraint, index and sequence counts are not compared"
  elif [ -n "$have" ] && [ "$have" = "$want" ]; then
    ok "$name: constraint, index and sequence counts match the manifest ($(printf '%s\n' "$want" | tr '\n' ' ' | sed 's/struct\.//g; s/ $//'))"
  else
    bad "$name: structure differs from the manifest (manifest: $(printf '%s\n' "$want" | tr '\n' ' ' | sed 's/struct\.//g; s/ $//'); restored: $(printf '%s\n' "$have" | tr '\n' ' ' | sed 's/struct\.//g; s/ $//'))"
  fi
  # informational only: a sequence behind the maximum of the column it belongs to is legal (explicit-id inserts), so it never fails the test
  behind=$(rq "/* pf:sequence-owned */ with own as (select d.objid as seq, d.refobjid as tbl, a.attname as col from pg_depend d join pg_class s on s.oid=d.objid and s.relkind='S' join pg_attribute a on a.attrelid=d.refobjid and a.attnum=d.refobjsubid where d.classid='pg_class'::regclass and d.refclassid='pg_class'::regclass and d.deptype in ('a','i')) select count(*) from own o join pg_class sc on sc.oid=o.seq join pg_namespace sn on sn.oid=sc.relnamespace join pg_sequences q on q.schemaname=sn.nspname and q.sequencename=sc.relname where q.last_value is not null and ((xpath('/row/m/text()', query_to_xml(format('select max(%I) as m from %s', o.col, o.tbl::regclass), false, true, '')))[1]::text)::numeric > q.last_value" 2>/dev/null) || behind=unknown
  case "$behind" in
    0) ok "$name: sequences owned by a column are not behind that column's maximum" ;;
    unknown) say "INFO  $name: owned-sequence consistency could not be evaluated (informational)" ;;
    *) say "INFO  $name: $behind owned sequence(s) are behind their column's maximum (legal after explicit-id inserts; informational)" ;;
  esac
}

restore_one() { # name
  local name=$1 man="$SETDIR/$1.manifest" file major c pw t want have start dur flyway_want flyway_have
  [ -f "$man" ] || { bad "$name: manifest missing"; return; }
  file="$SETDIR/$(mget "$man" encrypted_file)"; major=$(mget "$man" pg_major)
  [[ $major =~ ^[0-9]+$ ]] || { bad "$name: pg_major missing in the manifest"; return; }
  [ -f "$file" ] || { bad "$name: dump file missing"; return; }
  c="$RUN-$name"; pw=$(openssl rand -hex 16)
  say "$name: starting disposable postgres:$major-alpine ($c, no ports, tmpfs data, isolated network)"
  docker run -d --name "$c" --network "$RUN" --label "pfrestore=$RUN" --memory 512m --tmpfs /var/lib/postgresql/data:rw,size=1g \
    -e POSTGRES_PASSWORD="$pw" -e POSTGRES_DB=restore_check "postgres:$major-alpine" >/dev/null 2>&1 || { bad "$name: cannot start the test database"; return; }
  for _ in $(seq 1 90); do docker exec "$c" pg_isready -h 127.0.0.1 -U postgres -d restore_check >/dev/null 2>&1 && break; sleep 1; done
  docker exec "$c" pg_isready -h 127.0.0.1 -U postgres -d restore_check >/dev/null 2>&1 || { bad "$name: the test database did not become ready"; return; }
  rq() { docker exec "$c" psql -U postgres -d restore_check -X -At -v ON_ERROR_STOP=1 -c "$1"; }

  start=$(now_ms)
  # --batch --pinentry-mode ask: the passphrase is asked by the agent's pinentry window (pinentry-w32 on Windows Git Bash); a plain
  # "gpg --decrypt" fails with "cannot open 'no tty'" whenever the script has no terminal. The passphrase never passes through this script.
  gpg --batch --pinentry-mode ask --quiet --decrypt "$file" | docker exec -i "$c" pg_restore -U postgres -d restore_check --exit-on-error --no-owner --no-privileges
  local st=("${PIPESTATUS[@]}")
  dur_ms=$(( $(now_ms) - start )); dur=$(awk -v ms="$dur_ms" 'BEGIN{printf "%.1f", ms/1000}')
  if [ "${st[0]}" -ne 0 ] || [ "${st[1]}" -ne 0 ]; then bad "$name: decrypt or restore failed (gpg ${st[0]}, pg_restore ${st[1]})"; return; fi
  ok "$name: decrypted and restored in $dur s"

  # tables recorded in the manifest must all exist, with identical exact counts (Keycloak: only the stable configuration tables are strict)
  local strict=' '
  [ "$name" = keycloak ] && strict=" ${STRICT_KEYCLOAK_TABLES:-realm client user_entity keycloak_role credential component realm_attribute} "
  while IFS='=' read -r key want; do
    t=${key#count.}; [[ $t =~ ^[a-z_0-9]+$ ]] || continue
    have=$(rq "select count(*) from public.\"$t\"" 2>/dev/null) || have=missing
    if [ "$have" = "$want" ]; then ok "$name: table $t has $want rows"
    elif [ "$name" = keycloak ] && [[ $strict != *" $t "* ]]; then say "INFO  $name: table $t has $have rows, manifest said $want (volatile table, not compared)"
    else bad "$name: table $t has $have rows, manifest says $want"; fi
  done < <(grep '^count\.' "$man")

  flyway_want=$(mget "$man" flyway_latest)
  if [ -n "$flyway_want" ]; then
    flyway_have=$(rq "select version from flyway_schema_history where success order by installed_rank desc limit 1" 2>/dev/null)
    [ "$flyway_have" = "$flyway_want" ] && ok "$name: Flyway schema version $flyway_have" || bad "$name: Flyway version is '$flyway_have', manifest says '$flyway_want'"
  fi
  check_structure
  if [ "$name" = keycloak ]; then
    [ "$(rq "select count(*) from realm where name='prodflow'" 2>/dev/null)" = 1 ] && ok "keycloak: realm prodflow exists" || bad "keycloak: realm prodflow missing"
    have=$(rq "select string_agg(client_id, ',' order by client_id) from client where realm_id=(select id from realm where name='prodflow') and client_id in ('prodflow-api','prodflow-swagger','prodflow-web')" 2>/dev/null)
    [ "$have" = "prodflow-api,prodflow-swagger,prodflow-web" ] && ok "keycloak: clients prodflow-api, prodflow-swagger, prodflow-web exist" || bad "keycloak: clients found: '$have'"
    have=$(rq "select string_agg(name, ',' order by name) from keycloak_role where realm_id=(select id from realm where name='prodflow') and name in ('ADMIN','PLANNER','PURCHASER')" 2>/dev/null)
    [ "$have" = "ADMIN,PLANNER,PURCHASER" ] && ok "keycloak: realm roles ADMIN, PLANNER, PURCHASER exist" || bad "keycloak: roles found: '$have'"
  fi
  say "$name: restore took $dur s (input for the RTO estimate)"
}

for n in app keycloak; do [ -z "$ONLY" ] || [ "$ONLY" = "$n" ] || continue; restore_one "$n"; done
[ "$FAILS" -eq 0 ] && { say "RESULT: all checks passed"; exit 0; }
say "RESULT: $FAILS check(s) FAILED"; exit 1
