#!/usr/bin/env bash
# Guarded reset of the application's DEMO data to the known MR-200 baseline (Issue #9). Local and on the server (Bash, Docker, Compose).
#
#   scripts/reset-demo-data.sh --project <compose-project> --env-file <file> [--dry-run | --yes]
#
# What it does: in ONE transaction it empties item, bom_line, production_order and purchase_request (identities restart at 1) and loads
# backend/src/main/resources/db/demo/V100__demo_data.sql (the same file Flyway loads in the demo profile = single source of truth), then
# verifies the baseline inside the transaction (rolls back if anything differs): MR-200 0, SC-M8 25, PL-ST3 30, PR-40 50, BR-L60 100,
# four BOM lines, no orders, no purchase requests, first order number FA-00001.
#
# Guards (any failure aborts BEFORE anything is changed; exit 2):
#   - the environment file contains the explicit marker  PRODFLOW_DEMO_RESET=allowed   (a Spring profile is not enough)
#   - the target service is exactly "db" (the application database); "keycloak-db" and anything else are refused
#   - the database name is exactly "prodflow" (checked on the command line, in the container and via current_database())
#   - exactly one running container of that Compose project/service
#   - schema fingerprint: item, bom_line, production_order, purchase_request, flyway_schema_history exist; Flyway versions 1 and 100
#     applied; NO Keycloak tables (realm, user_entity, ...) in the database
# Without --yes nothing is executed (exit 3); --dry-run shows the verified target and the plan (exit 0).
# No secrets are read or printed: SQL runs inside the container over its local socket. Keycloak's database is never contacted.
set -u
PROJECT=''; ENV_FILE=''; SERVICE=db; DATABASE=prodflow; DRY=0; YES=0
HERE=$(cd "$(dirname "$0")" && pwd)
SEED="$HERE/../backend/src/main/resources/db/demo/V100__demo_data.sql"
while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT=$2; shift 2 ;;
    --env-file) ENV_FILE=$2; shift 2 ;;
    --service) SERVICE=$2; shift 2 ;;
    --database) DATABASE=$2; shift 2 ;;
    --seed-file) SEED=$2; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --yes) YES=1; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
refuse() { echo "reset-demo-data: REFUSED - $1" >&2; exit 2; }
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'

[ -n "$PROJECT" ] || refuse "--project <compose project> is required (no default, so nothing is targeted by accident)"
[ -n "$ENV_FILE" ] && [ -r "$ENV_FILE" ] || refuse "--env-file <file with the demo marker> is required and must be readable"
grep -qxE 'PRODFLOW_DEMO_RESET=allowed[[:space:]]*' <(tr -d '\r' <"$ENV_FILE") || refuse "marker PRODFLOW_DEMO_RESET=allowed is missing in the environment file (this is not a demo environment)"
[ "$SERVICE" = db ] || refuse "service must be exactly 'db' (the application database), got '$SERVICE'"
[ "$DATABASE" = prodflow ] || refuse "database must be exactly 'prodflow', got '$DATABASE'"
[ -r "$SEED" ] || refuse "seed file not readable: $SEED"
command -v docker >/dev/null 2>&1 || refuse "docker not available"

ids=$(docker ps -q --filter "label=com.docker.compose.project=$PROJECT" --filter "label=com.docker.compose.service=$SERVICE" 2>/dev/null)
[ -n "$ids" ] || refuse "no running container for project '$PROJECT', service '$SERVICE'"
[ "$(printf '%s\n' "$ids" | wc -l | tr -d ' ')" = 1 ] || refuse "more than one container matches project '$PROJECT', service '$SERVICE'"
C=$ids
name=$(docker inspect --format '{{.Name}}' "$C" | sed 's#^/##')
envdb=$(docker exec "$C" printenv POSTGRES_DB 2>/dev/null | tr -d '\r')
[ "$envdb" = "$DATABASE" ] || refuse "the container's POSTGRES_DB is not '$DATABASE'"

sql() { docker exec -i "$C" sh -c 'exec psql -X -At -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' "$@"; }
cur=$(printf '%s\n' "SELECT current_database()" | sql | tr -d '\r') || refuse "cannot query the database"
[ "$cur" = "$DATABASE" ] || refuse "connected database is '$cur', expected '$DATABASE'"

present=$(printf '%s\n' "SELECT string_agg(table_name, ',' ORDER BY table_name) FROM information_schema.tables WHERE table_schema='public'" | sql | tr -d '\r') || refuse "schema lookup failed"
for t in item bom_line production_order purchase_request flyway_schema_history; do
  case ",$present," in *",$t,"*) ;; *) refuse "expected application table '$t' is missing (wrong database?)" ;; esac
done
for t in realm user_entity client keycloak_role migration_model; do
  case ",$present," in *",$t,"*) refuse "Keycloak table '$t' found - this is not the application database" ;; esac
done
versions=$(printf '%s\n' "SELECT string_agg(version, ',' ORDER BY installed_rank) FROM flyway_schema_history WHERE success" | sql | tr -d '\r') || refuse "Flyway history lookup failed"
for v in 1 100; do
  case ",$versions," in *",$v,"*) ;; *) refuse "Flyway versions 1 and 100 (schema + demo data) are not both applied: '$versions'" ;; esac
done

orders=$(printf '%s\n' "SELECT count(*) FROM production_order" | sql | tr -d '\r')
requests=$(printf '%s\n' "SELECT count(*) FROM purchase_request" | sql | tr -d '\r')
echo "verified target: project=$PROJECT service=$SERVICE container=$name database=$DATABASE flyway=$versions"
echo "current content: $orders production order(s), $requests purchase request(s)"
echo "plan: TRUNCATE item, bom_line, production_order, purchase_request RESTART IDENTITY; load $(basename "$SEED"); verify baseline; all in one transaction. Keycloak is not touched."
if [ "$DRY" = 1 ]; then echo "dry run: nothing changed."; exit 0; fi
if [ "$YES" != 1 ]; then echo "not confirmed: pass --yes to execute (nothing changed)." >&2; exit 3; fi

{
  printf '%s\n' "TRUNCATE purchase_request, production_order, bom_line, item RESTART IDENTITY;"
  cat "$SEED"
  cat <<'VERIFY'
DO $$
DECLARE bad int;
BEGIN
  SELECT count(*) INTO bad FROM (VALUES ('MR-200', 0), ('SC-M8', 25), ('PL-ST3', 30), ('PR-40', 50), ('BR-L60', 100)) AS b(code, qty)
    LEFT JOIN item i ON i.code = b.code AND i.qty_on_hand = b.qty WHERE i.id IS NULL;
  IF bad <> 0 OR (SELECT count(*) FROM item) <> 5 THEN RAISE EXCEPTION 'baseline items differ'; END IF;
  IF (SELECT count(*) FROM bom_line) <> 4 THEN RAISE EXCEPTION 'baseline BOM differs'; END IF;
  IF (SELECT count(*) FROM production_order) <> 0 OR (SELECT count(*) FROM purchase_request) <> 0 THEN RAISE EXCEPTION 'orders/requests remain'; END IF;
END $$;
VERIFY
} | docker exec -i "$C" sh -c 'exec psql -X -q -v ON_ERROR_STOP=1 --single-transaction -U "$POSTGRES_USER" -d "$POSTGRES_DB"' >/dev/null 2>"${TMPDIR:-/tmp}/reset-demo.err"
rc=$?
if [ $rc -ne 0 ]; then echo "reset-demo-data: FAILED - transaction rolled back, nothing changed" >&2; sed -n '1,5p' "${TMPDIR:-/tmp}/reset-demo.err" >&2; rm -f "${TMPDIR:-/tmp}/reset-demo.err"; exit 1; fi
rm -f "${TMPDIR:-/tmp}/reset-demo.err"
echo "baseline restored:"
printf '%s\n' "SELECT '  ' || code || ' ' || qty_on_hand::int FROM item ORDER BY id" | sql
echo "  production orders: $(printf '%s\n' 'SELECT count(*) FROM production_order' | sql | tr -d '\r'), purchase requests: $(printf '%s\n' 'SELECT count(*) FROM purchase_request' | sql | tr -d '\r'), next order number: FA-00001"
