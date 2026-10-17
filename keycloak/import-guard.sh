#!/bin/sh
# Fail-fast guard in front of the Keycloak realm import (Issue #8, D-1).
#
# keycloak/prodflow-realm.json imports the demo users with ${DEMO_*_PASSWORD} placeholders. Keycloak 26.4 does NOT fail
# on a bad value: an UNSET variable stores the literal placeholder text as a working password, an EMPTY one creates a
# broken, unusable credential. So the values are validated here, BEFORE Keycloak starts and imports anything.
#
#   - Realm "prodflow" already exists in the Keycloak database -> Keycloak skips the import, nothing to validate
#     (routine restarts need no demo passwords).
#   - Realm missing (fresh database)                           -> all three passwords must be valid, else exit 1.
#   - Anything uncertain (database unreachable, query fails)   -> exit 2 (fail closed).
#
# Notes: a realm row is taken as "imported" (Keycloak imports a realm in one transaction); length/distinct counts are per byte,
# so ASCII passwords are recommended; the check assumes Keycloak's default "public" schema (otherwise it validates, fail-safe).
# Output names variables and reasons only, never values. POSIX sh (busybox ash) + psql from the postgres image.
# Connection: standard PG* variables (PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD).
set -u
export PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-5}"

REALM="${GUARD_REALM:-prodflow}"
MIN_LENGTH=12
MIN_DISTINCT=6

fail() { echo "import-guard: REFUSED - $1" >&2; exit 1; }
uncertain() { echo "import-guard: REFUSED - $1" >&2; exit 2; }

# ---- 1. does the realm already exist? --------------------------------------------------------------------------------
# On the very first start of a fresh volume the postgres entrypoint runs a temporary server that only listens on the Unix
# socket, while this guard connects over TCP; retry briefly instead of failing the first `docker compose up`.
table=''
attempt=0
while [ "$attempt" -lt 15 ]; do
  table=$(psql -X -At -v ON_ERROR_STOP=1 -c "SELECT to_regclass('public.realm') IS NOT NULL" 2>/dev/null) && break
  table=''; attempt=$((attempt + 1)); sleep 2
done
[ -n "$table" ] ||
  uncertain "cannot query the Keycloak database (connection or credentials); not starting Keycloak"
case "$table" in
  t) count=$(printf '%s\n' "SELECT count(*) FROM realm WHERE name = :'realm'" |
       psql -X -At -v ON_ERROR_STOP=1 -v realm="$REALM") ||
       uncertain "realm lookup failed; not starting Keycloak"
     case "$count" in
       ''|*[!0-9]*) uncertain "unexpected realm lookup result; not starting Keycloak" ;;
     esac
     if [ "$count" -gt 0 ]; then
       echo "import-guard: realm '$REALM' already exists - import will be skipped, demo passwords not validated"
       exit 0
     fi ;;
  f) : ;; # fresh database: Keycloak has not created its schema yet, so the realm will be imported
  *) uncertain "unexpected schema lookup result; not starting Keycloak" ;;
esac

# ---- 2. fresh import: validate every demo password -------------------------------------------------------------------
echo "import-guard: realm '$REALM' not found - validating demo passwords before the first import"

check() { # $1 = variable name
  name=$1
  eval "set_=\${$name+x}; value=\${$name:-}"
  [ -n "$set_" ] || fail "$name is not set"
  [ -n "$value" ] || fail "$name is empty"
  case "$value" in
    *'${'*) fail "$name still contains an unresolved placeholder (\${...})" ;;
  esac
  # $(...) strips trailing newlines, so line breaks are detected by counting them instead of matching a pattern
  [ "$(printf '%s' "$value" | wc -l | tr -d ' ')" -eq 0 ] || fail "$name contains a line break"
  case "$value" in
    *[[:cntrl:]]*) fail "$name contains a control character" ;;
    ' '*|*' ') fail "$name has leading or trailing spaces" ;;
  esac
  lower=$(printf '%s' "$value" | tr 'A-Z' 'a-z')
  case "$lower" in
    *change_me*|*changeme*|*change-me*|*replace_me*|*replaceme*|*your_password*|*yourpassword*|*password*)
      fail "$name looks like a placeholder or an obvious password" ;;
  esac
  [ "${#value}" -ge "$MIN_LENGTH" ] || fail "$name is shorter than $MIN_LENGTH characters"
  distinct=$(printf '%s' "$value" | fold -w1 | sort -u | wc -l | tr -d ' ')
  [ "$distinct" -ge "$MIN_DISTINCT" ] || fail "$name has fewer than $MIN_DISTINCT distinct characters"
}

for v in DEMO_PLANNER_PASSWORD DEMO_PURCHASER_PASSWORD DEMO_ADMIN_PASSWORD; do check "$v"; done

# usernames must not be used as passwords, and the three accounts must not share a password
for pair in "planner:${DEMO_PLANNER_PASSWORD:-}" "purchaser:${DEMO_PURCHASER_PASSWORD:-}" "admin:${DEMO_ADMIN_PASSWORD:-}"; do
  user=${pair%%:*}; pw=$(printf '%s' "${pair#*:}" | tr 'A-Z' 'a-z')
  case "$pw" in *"$user"*) fail "the $user demo password contains the username" ;; esac
done
[ "$DEMO_PLANNER_PASSWORD" != "$DEMO_PURCHASER_PASSWORD" ] || fail "DEMO_PLANNER_PASSWORD and DEMO_PURCHASER_PASSWORD are identical"
[ "$DEMO_PLANNER_PASSWORD" != "$DEMO_ADMIN_PASSWORD" ] || fail "DEMO_PLANNER_PASSWORD and DEMO_ADMIN_PASSWORD are identical"
[ "$DEMO_PURCHASER_PASSWORD" != "$DEMO_ADMIN_PASSWORD" ] || fail "DEMO_PURCHASER_PASSWORD and DEMO_ADMIN_PASSWORD are identical"

echo "import-guard: demo passwords accepted (length >= $MIN_LENGTH, >= $MIN_DISTINCT distinct characters, distinct per user)"
exit 0
