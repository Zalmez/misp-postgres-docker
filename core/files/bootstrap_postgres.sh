#!/bin/bash
set -Eeuo pipefail

[[ "${DB_ENGINE:-}" == "postgres" ]] || { echo "bootstrap mode requires DB_ENGINE=postgres" >&2; exit 2; }
[[ "${POSTGRES_SCHEMA}" =~ ^[a-z_][a-z0-9_]*$ ]] || { echo "POSTGRES_SCHEMA must be a lowercase PostgreSQL identifier" >&2; exit 2; }

cleanup() {
    if [[ -n "${PG_LOCK_PID:-}" ]]; then
        printf 'SELECT pg_advisory_unlock(hashtextextended(%s, 0));\n\\q\n' "'$POSTGRES_DATABASE:misp-bootstrap'" >&"${PG_LOCK[1]}" 2>/dev/null || true
        wait "$PG_LOCK_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

echo "BOOTSTRAP | Validating PostgreSQL connectivity"
psql -XAtv ON_ERROR_STOP=1 -c 'SELECT 1' >/dev/null

coproc PG_LOCK { psql -XAtv ON_ERROR_STOP=1; }
PG_LOCK_PID=$!
printf "SELECT pg_advisory_lock(hashtextextended('%s', 0)); SELECT 'LOCKED';\n" "$POSTGRES_DATABASE:misp-bootstrap" >&"${PG_LOCK[1]}"
while IFS= read -r line <&"${PG_LOCK[0]}"; do
    [[ "$line" == "LOCKED" ]] && break
done
kill -0 "$PG_LOCK_PID" 2>/dev/null || { echo "BOOTSTRAP | Failed to acquire database lock" >&2; exit 1; }

table_count=$(psql -XAtqc "SELECT count(*) FROM pg_catalog.pg_tables WHERE schemaname = '$POSTGRES_SCHEMA'")
has_attributes=$(psql -XAtqc "SELECT to_regclass('$POSTGRES_SCHEMA.attributes') IS NOT NULL")

if [[ "$table_count" == "0" ]]; then
    echo "BOOTSTRAP | Importing PostgreSQL baseline"
    psql -X -v ON_ERROR_STOP=1 -f /var/www/MISP/INSTALL/POSTGRESQL.sql
    fresh_install=true
elif [[ "$has_attributes" == "t" ]]; then
    echo "BOOTSTRAP | Existing MISP schema detected"
    fresh_install=false
else
    echo "BOOTSTRAP | Refusing unexpected or partial schema (${table_count} tables, attributes missing)" >&2
    exit 1
fi

/init_misp.sh
echo "BOOTSTRAP | Running database migrations"
sudo -E -u www-data /var/www/MISP/app/Console/cake Admin runUpdates
if [[ "$fresh_install" == "true" ]]; then
    echo "BOOTSTRAP | Initializing first user"
    sudo -E -u www-data /var/www/MISP/app/Console/cake User init -q
    psql -Xv ON_ERROR_STOP=1 -v admin_email="$ADMIN_EMAIL" <<'SQL'
UPDATE users SET email = :'admin_email' WHERE id = 1;
UPDATE users SET change_pw = FALSE WHERE id = 1;
SQL
fi
echo "BOOTSTRAP | Applying MISP configuration"
/configure_misp.sh
sudo -E -u www-data /var/www/MISP/app/Console/cake Admin migrationStatus
echo "BOOTSTRAP | Complete"