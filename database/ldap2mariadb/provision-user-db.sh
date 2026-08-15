#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# provision-user-db.sh — MariaDB port of the postgres provisioner.
#
# For every PAM login account created by sync-roles.sh: create a personal
# database, make the user its de-facto owner, and grant the anchor roles
# (readers/writers/ddl) the right level of access on it. Then apply the same for
# per-database scoped roles (<db>_readers | <db>_writers | <db>_ddl).
#
# MariaDB makes this simpler than postgres:
#   * database == schema, and GRANT ... ON `db`.* already covers FUTURE tables,
#     so there is no ALTER DEFAULT PRIVILEGES loop to maintain.
#   * there is no PUBLIC pseudo-role and no per-database owner to fix, so the
#     "revoke PUBLIC" and "fix owner" steps simply disappear.
# ─────────────────────────────────────────────────────────────────────────────

: "${READERS_ROLE:?}"
: "${WRITERS_ROLE:?}"
: "${DDL_ROLE:?}"

: "${MYSQL_HOST:?}"; : "${MYSQL_PORT:?}"; : "${MYSQL_USER:?}"
MARIADB=(mariadb --host "${MYSQL_HOST}" --port "${MYSQL_PORT}"
                 --user "${MYSQL_USER}" --batch --skip-column-names)
sql() { "${MARIADB[@]}" -e "$1"; }
# Escaping is context-dependent: in a '...' literal a backslash escapes the next
# character (default sql_mode), while in a `...` identifier it is literal.
esc_str() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e "s/'/''/g"; }
esc_id()  { printf '%s' "$1" | sed 's/`/``/g'; }

grant_db_to_roles() {
  local db; db="$(esc_id "$1")"
  sql "GRANT SELECT ON \`${db}\`.* TO \`$(esc_id "$READERS_ROLE")\`;"
  sql "GRANT SELECT, INSERT, UPDATE, DELETE ON \`${db}\`.* TO \`$(esc_id "$WRITERS_ROLE")\`;"
  sql "GRANT ALL PRIVILEGES ON \`${db}\`.* TO \`$(esc_id "$DDL_ROLE")\`;"
}

# ── 1. Per-user personal databases ──────────────────────────────────────────
echo "[*] Discovering PAM login accounts"
users="$(sql "SELECT User FROM mysql.user WHERE plugin='pam' AND User <> '' ORDER BY User;")"

if [ -z "$users" ]; then
  echo "[*] No PAM users found; nothing to provision."
else
  while IFS= read -r u; do
    [ -z "$u" ] && continue
    edb="$(esc_id "$u")"; sdb="$(esc_str "$u")"
    echo "[*] Provisioning DB for ${u}"
    sql "CREATE DATABASE IF NOT EXISTS \`${edb}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_uca1400_ai_ci;"
    # Owner-equivalent: full rights on their own DB, with grant option.
    sql "GRANT ALL PRIVILEGES ON \`${edb}\`.* TO '${sdb}'@'%' WITH GRANT OPTION;"
    grant_db_to_roles "$u"
  done <<< "$users"
fi

# ── 2. Per-database scoped roles (<db>_readers | _writers | _ddl) ────────────
echo "[*] Applying per-database scoped role grants"
perdb="$(sql "
  SELECT User FROM mysql.user
  WHERE is_role='Y' AND User REGEXP '_(readers|writers|ddl)\$'
  ORDER BY User;")"

while IFS= read -r role; do
  [ -z "$role" ] && continue
  db="${role%_*}"                 # strip the trailing _readers/_writers/_ddl
  kind="${role##*_}"              # readers | writers | ddl
  exists="$(sql "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$(esc_str "$db")';")"
  [ -z "$exists" ] && { echo "    - skip ${role} (no database '${db}')"; continue; }
  edb="$(esc_id "$db")"; erole="$(esc_id "$role")"
  echo "    - ${kind} on \`${db}\` -> ${role}"
  case "$kind" in
    readers) sql "GRANT SELECT ON \`${edb}\`.* TO \`${erole}\`;" ;;
    writers) sql "GRANT SELECT, INSERT, UPDATE, DELETE ON \`${edb}\`.* TO \`${erole}\`;" ;;
    ddl)     sql "GRANT ALL PRIVILEGES ON \`${edb}\`.* TO \`${erole}\`;" ;;
  esac
done <<< "$perdb"

echo "[*] Done."
