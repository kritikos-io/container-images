#!/usr/bin/env bash
set -euo pipefail

: "${BOOTSTRAP_DB:?}"
: "${ADMIN_DB:?}"
: "${USERS_ROLE:?}"                # group whose members each get a personal DB
: "${READERS_ROLE:?}"
: "${WRITERS_ROLE:?}"
: "${DDL_ROLE:?}"
: "${HARDEN_DB_PUBLIC:?}"          # 1=yes: revoke PUBLIC connect on each user DB

psql_bootstrap() { psql -v ON_ERROR_STOP=1 -d "$BOOTSTRAP_DB" "$@"; }
psql_userdb()    { psql -v ON_ERROR_STOP=1 -d "$1" "${@:2}"; }

qi() {
  local s="$1"
  s="${s//\"/\"\"}"
  printf '"%s"' "$s"
}

# ── 1. Ensure the admin (ldap2pg) database exists ──────────────────────────
echo "[*] Ensuring admin database exists: ${ADMIN_DB}"
psql_bootstrap -Atc "SELECT 1 FROM pg_database WHERE datname='${ADMIN_DB}';" | grep -qx 1 || \
  psql_bootstrap -c "CREATE DATABASE $(qi "$ADMIN_DB") OWNER postgres;"

# ── 2. Discover LDAP-synced login roles ────────────────────────────────────
echo "[*] Discovering user roles from PG group: ${USERS_ROLE}"
users="$(psql_bootstrap -Atc "
  SELECT r.rolname
  FROM pg_roles r
  JOIN pg_auth_members m ON m.member = r.oid
  JOIN pg_roles p ON p.oid = m.roleid
  WHERE p.rolname = '${USERS_ROLE}'
    AND r.rolcanlogin
    AND r.rolname <> 'postgres'
    AND r.rolname !~ '^pg_'
  ORDER BY 1;
")"

if [[ -z "${users}" ]]; then
  echo "[*] No members in '${USERS_ROLE}'. Nothing to provision."
  exit 0
fi

# ── 3. Per-user database provisioning ──────────────────────────────────────
while IFS= read -r u; do
  [[ -z "$u" ]] && continue
  echo
  echo "[*] Provisioning DB for user: ${u}"

  # ── 3a. Create the database if missing ───────────────────────────────────
  if ! psql_bootstrap -Atc "SELECT 1 FROM pg_database WHERE datname='${u}';" | grep -qx 1; then
    echo "    - creating database $(qi "$u") owned by $(qi "$u")"
    psql_bootstrap -c "CREATE DATABASE $(qi "$u") OWNER $(qi "$u");"
  else
    echo "    - database exists"
  fi

  # ── 3b. Fix ownership if needed ──────────────────────────────────────────
  current_owner="$(psql_bootstrap -Atc "
    SELECT pg_get_userbyid(datdba)
    FROM pg_database
    WHERE datname='${u}';
  ")"
  if [[ "${current_owner}" != "${u}" ]]; then
    echo "    - fixing db owner: ${current_owner} -> ${u}"
    psql_bootstrap -c "ALTER DATABASE $(qi "$u") OWNER TO $(qi "$u");"
  else
    echo "    - db owner OK"
  fi

  # ── 3c. Harden: revoke PUBLIC connect ────────────────────────────────────
  if [[ "${HARDEN_DB_PUBLIC}" == "1" ]]; then
    psql_bootstrap -c "REVOKE ALL ON DATABASE $(qi "$u") FROM PUBLIC;"
  fi

  # ── 3d. Owner DB-level grants ────────────────────────────────────────────
  psql_bootstrap -c "GRANT CONNECT, TEMPORARY, CREATE ON DATABASE $(qi "$u") TO $(qi "$u");"

  # ── 3e. Per-owner schema + public schema grants ──────────────────────────
  psql_userdb "$u" -c "GRANT USAGE, CREATE ON SCHEMA public TO $(qi "$u");"              >/dev/null

  # ── 3f. Fine-grained role grants (readers / writers / ddl) ───────────────
  #
  # DB-level CONNECT so the marker roles can reach the database at all.
  for role in "$READERS_ROLE" "$WRITERS_ROLE" "$DDL_ROLE"; do
    psql_bootstrap -c "GRANT CONNECT ON DATABASE $(qi "$u") TO $(qi "$role");" 2>/dev/null || true
  done

  # DB-level CREATE for the DDL role: required to install trusted extensions
  # (e.g. CREATE EXTENSION vector) and to create schemas.
  psql_bootstrap -c "GRANT CREATE ON DATABASE $(qi "$u") TO $(qi "$DDL_ROLE");" 2>/dev/null || true

  # Schema-level grants inside the user's database
  for schema in public; do
    # readers  → read-only
    psql_userdb "$u" -c "GRANT USAGE ON SCHEMA $(qi "$schema") TO $(qi "$READERS_ROLE");"                                >/dev/null
    psql_userdb "$u" -c "GRANT SELECT ON ALL TABLES IN SCHEMA $(qi "$schema") TO $(qi "$READERS_ROLE");"                  >/dev/null
    psql_userdb "$u" -c "GRANT SELECT ON ALL SEQUENCES IN SCHEMA $(qi "$schema") TO $(qi "$READERS_ROLE");"               >/dev/null

    # writers  → read + DML
    psql_userdb "$u" -c "GRANT USAGE ON SCHEMA $(qi "$schema") TO $(qi "$WRITERS_ROLE");"                                 >/dev/null
    psql_userdb "$u" -c "GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA $(qi "$schema") TO $(qi "$WRITERS_ROLE");"    >/dev/null
    psql_userdb "$u" -c "GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA $(qi "$schema") TO $(qi "$WRITERS_ROLE");"         >/dev/null

    # ddl      → full DDL (create/alter/drop via ownership proxy)
    psql_userdb "$u" -c "GRANT USAGE, CREATE ON SCHEMA $(qi "$schema") TO $(qi "$DDL_ROLE");"                             >/dev/null
    psql_userdb "$u" -c "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA $(qi "$schema") TO $(qi "$DDL_ROLE");"              >/dev/null
    psql_userdb "$u" -c "GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA $(qi "$schema") TO $(qi "$DDL_ROLE");"           >/dev/null
    psql_userdb "$u" -c "GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA $(qi "$schema") TO $(qi "$DDL_ROLE");"           >/dev/null

    # ── Default privileges: apply to objects created in the future ────────
    psql_userdb "$u" -c "ALTER DEFAULT PRIVILEGES IN SCHEMA $(qi "$schema") GRANT SELECT ON TABLES TO $(qi "$READERS_ROLE");"                        >/dev/null
    psql_userdb "$u" -c "ALTER DEFAULT PRIVILEGES IN SCHEMA $(qi "$schema") GRANT SELECT ON SEQUENCES TO $(qi "$READERS_ROLE");"                     >/dev/null

    psql_userdb "$u" -c "ALTER DEFAULT PRIVILEGES IN SCHEMA $(qi "$schema") GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO $(qi "$WRITERS_ROLE");"       >/dev/null
    psql_userdb "$u" -c "ALTER DEFAULT PRIVILEGES IN SCHEMA $(qi "$schema") GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO $(qi "$WRITERS_ROLE");"             >/dev/null

    psql_userdb "$u" -c "ALTER DEFAULT PRIVILEGES IN SCHEMA $(qi "$schema") GRANT ALL PRIVILEGES ON TABLES TO $(qi "$DDL_ROLE");"                    >/dev/null
    psql_userdb "$u" -c "ALTER DEFAULT PRIVILEGES IN SCHEMA $(qi "$schema") GRANT ALL PRIVILEGES ON SEQUENCES TO $(qi "$DDL_ROLE");"                 >/dev/null
    psql_userdb "$u" -c "ALTER DEFAULT PRIVILEGES IN SCHEMA $(qi "$schema") GRANT ALL PRIVILEGES ON FUNCTIONS TO $(qi "$DDL_ROLE");"                 >/dev/null
  done

  echo "    - DB + schema grants OK (owner, readers, writers, ddl)"
done <<< "${users}"

# ── 4. Per-database scoped role grants ─────────────────────────────────────
# Discover PG roles matching <dbname>_readers / <dbname>_writers / <dbname>_ddl
# and grant them ONLY on the corresponding database.
echo
echo "[*] Applying per-database scoped grants …"

apply_perdb_grants() {
  local db="$1" role="$2" kind="$3"

  # DB-level CONNECT
  psql_bootstrap -c "GRANT CONNECT ON DATABASE $(qi "$db") TO $(qi "$role");" 2>/dev/null || true

  # DDL roles also need DB-level CREATE to install trusted extensions
  # (e.g. CREATE EXTENSION vector) and to create schemas.
  if [[ "$kind" == "ddl" ]]; then
    psql_bootstrap -c "GRANT CREATE ON DATABASE $(qi "$db") TO $(qi "$role");" 2>/dev/null || true
  fi

  for schema in public "$db"; do
    case "$kind" in
      readers)
        psql_userdb "$db" -c "GRANT USAGE ON SCHEMA $(qi "$schema") TO $(qi "$role");"                                          >/dev/null
        psql_userdb "$db" -c "GRANT SELECT ON ALL TABLES IN SCHEMA $(qi "$schema") TO $(qi "$role");"                            >/dev/null
        psql_userdb "$db" -c "GRANT SELECT ON ALL SEQUENCES IN SCHEMA $(qi "$schema") TO $(qi "$role");"                         >/dev/null
        psql_userdb "$db" -c "ALTER DEFAULT PRIVILEGES IN SCHEMA $(qi "$schema") GRANT SELECT ON TABLES TO $(qi "$role");"       >/dev/null
        psql_userdb "$db" -c "ALTER DEFAULT PRIVILEGES IN SCHEMA $(qi "$schema") GRANT SELECT ON SEQUENCES TO $(qi "$role");"    >/dev/null
        ;;
      writers)
        psql_userdb "$db" -c "GRANT USAGE ON SCHEMA $(qi "$schema") TO $(qi "$role");"                                                                >/dev/null
        psql_userdb "$db" -c "GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA $(qi "$schema") TO $(qi "$role");"                          >/dev/null
        psql_userdb "$db" -c "GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA $(qi "$schema") TO $(qi "$role");"                                >/dev/null
        psql_userdb "$db" -c "ALTER DEFAULT PRIVILEGES IN SCHEMA $(qi "$schema") GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO $(qi "$role");"     >/dev/null
        psql_userdb "$db" -c "ALTER DEFAULT PRIVILEGES IN SCHEMA $(qi "$schema") GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO $(qi "$role");"           >/dev/null
        ;;
      ddl)
        psql_userdb "$db" -c "GRANT USAGE, CREATE ON SCHEMA $(qi "$schema") TO $(qi "$role");"                                   >/dev/null
        psql_userdb "$db" -c "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA $(qi "$schema") TO $(qi "$role");"                    >/dev/null
        psql_userdb "$db" -c "GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA $(qi "$schema") TO $(qi "$role");"                 >/dev/null
        psql_userdb "$db" -c "GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA $(qi "$schema") TO $(qi "$role");"                 >/dev/null
        psql_userdb "$db" -c "ALTER DEFAULT PRIVILEGES IN SCHEMA $(qi "$schema") GRANT ALL PRIVILEGES ON TABLES TO $(qi "$role");"    >/dev/null
        psql_userdb "$db" -c "ALTER DEFAULT PRIVILEGES IN SCHEMA $(qi "$schema") GRANT ALL PRIVILEGES ON SEQUENCES TO $(qi "$role");" >/dev/null
        psql_userdb "$db" -c "ALTER DEFAULT PRIVILEGES IN SCHEMA $(qi "$schema") GRANT ALL PRIVILEGES ON FUNCTIONS TO $(qi "$role");" >/dev/null
        ;;
    esac
  done
}

# Query PG for roles whose name matches <something>_readers|_writers|_ddl
# and where the <something> part matches an existing database.
perdb_roles="$(psql_bootstrap -Atc "
  SELECT r.rolname, d.datname,
         CASE
           WHEN r.rolname LIKE '%\_readers' THEN 'readers'
           WHEN r.rolname LIKE '%\_writers' THEN 'writers'
           WHEN r.rolname LIKE '%\_ddl'     THEN 'ddl'
         END AS kind
  FROM pg_roles r
  JOIN pg_auth_members m ON m.member = r.oid
  JOIN pg_roles p ON p.oid = m.roleid AND p.rolname = 'ldap_roles'
  JOIN pg_database d ON d.datname = regexp_replace(r.rolname, '_(readers|writers|ddl)$', '')
  WHERE r.rolname ~ '_(readers|writers|ddl)$'
    AND NOT r.rolcanlogin
  ORDER BY 1;
")" || true

if [[ -n "${perdb_roles}" ]]; then
  while IFS='|' read -r rolname dbname kind; do
    [[ -z "$rolname" ]] && continue
    echo "    - granting ${kind} on DB '${dbname}' to role '${rolname}'"
    apply_perdb_grants "$dbname" "$rolname" "$kind"
  done <<< "${perdb_roles}"
else
  echo "    - no per-database scoped roles found"
fi

echo
echo "[*] Done."
