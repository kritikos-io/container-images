#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# sync-roles.sh — the ldap2pg analogue for MariaDB.
#
# There is no ldap2pg for MariaDB, so this reproduces the parts of ldap2pg.yaml
# we rely on: read AD group membership and materialise it as MariaDB roles plus
# per-user login accounts. Human accounts authenticate via PAM -> AD (no
# password is stored in MariaDB); the anchor roles carry the actual privileges,
# which provision-user-db.sh grants per database.
#
# Model (mirrors ldap2pg.yaml):
#   Global groups  under OU=Global,OU=Database,OU=Groups:
#     owners | readers | writers | ddl        -> members get the matching role
#   Per-DB groups  under OU=Database,OU=Groups:
#     <db>_readers | <db>_writers | <db>_ddl  -> scoped roles
#
# Those groups are engine-agnostic: they say WHAT privileges a member gets, not
# on which server. ENGINE_GROUP_DN is the orthogonal gate — a member is only
# provisioned here if they are also in that group, which is what keeps the
# shared role groups from creating MariaDB accounts for Postgres-only users.
#
# Connection: MYSQL_HOST/PORT/USER + MYSQL_PWD (read from the environment by the
# mariadb client, so the password never appears on the command line). Point this
# at the backend directly, NOT MaxScale — same as ldap2pg talking to the PG
# primary rather than through pgpool.
# ─────────────────────────────────────────────────────────────────────────────

: "${LDAPURI:?}"; : "${LDAPBINDDN:?}"; : "${LDAPPASSWORD:?}"
: "${GLOBAL_BASE:?}"
: "${PERDB_BASE:?}"
# Set but allowed to be empty: empty disables the engine gate entirely.
: "${ENGINE_GROUP_DN?}"

# LDAP_MATCHING_RULE_IN_CHAIN: matches through nested groups, so the engine gate
# can hold org groups (Daemons, DBAs) instead of only individual users.
ENGINE_FILTER=""
if [ -n "$ENGINE_GROUP_DN" ]; then
  ENGINE_FILTER="(memberOf:1.2.840.113556.1.4.1941:=${ENGINE_GROUP_DN})"
fi

: "${MYSQL_HOST:?}"; : "${MYSQL_PORT:?}"; : "${MYSQL_USER:?}"
MARIADB=(mariadb --host "${MYSQL_HOST}" --port "${MYSQL_PORT}"
                 --user "${MYSQL_USER}" --batch --skip-column-names)
sql() { "${MARIADB[@]}" -e "$1"; }

# Escaping is context-dependent: in a '...' literal a backslash escapes the next
# character (default sql_mode), while in a `...` identifier it is literal.
esc_str() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e "s/'/''/g"; }
esc_id()  { printf '%s' "$1" | sed 's/`/``/g'; }

# Emit the sAMAccountName of every direct user member of the named AD group.
group_members() {
  local base="$1" group="$2" dns
  dns="$(ldapsearch -LLL -o ldif-wrap=no -H "$LDAPURI" \
           -D "$LDAPBINDDN" -w "$LDAPPASSWORD" \
           -b "$base" -s one "(&(objectClass=group)(cn=${group}))" member \
         | sed -n 's/^member: //p')"
  [ -z "$dns" ] && return 0
  while IFS= read -r dn; do
    [ -z "$dn" ] && continue
    ldapsearch -LLL -o ldif-wrap=no -H "$LDAPURI" -D "$LDAPBINDDN" -w "$LDAPPASSWORD" \
      -b "$dn" -s base \
      "(&(objectCategory=person)(objectClass=user)(!(objectClass=computer))${ENGINE_FILTER})" \
      sAMAccountName 2>/dev/null | sed -n 's/^sAMAccountName: //p'
  done <<< "$dns"
}

ensure_role() {
  local role; role="$(esc_id "$1")"
  sql "CREATE ROLE IF NOT EXISTS \`${role}\`;"
}

ensure_user_in_role() {
  local user role
  user="$(esc_str "$1")"; role="$(esc_id "$2")"
  # PAM login account: the password is verified against AD, nothing is stored.
  sql "CREATE USER IF NOT EXISTS '${user}'@'%' IDENTIFIED VIA pam USING 'mariadb';"
  sql "GRANT \`${role}\` TO '${user}'@'%';"
  # MariaDB roles are inactive until selected, and it allows only ONE default
  # role per user (no ALL, unlike MySQL) — make this role active at login.
  sql "SET DEFAULT ROLE \`${role}\` FOR '${user}'@'%';"
}

echo "[*] Ensuring anchor roles"
for r in owners readers writers ddl; do ensure_role "$r"; done

echo "[*] Syncing global AD groups -> roles"
for grp in owners readers writers ddl; do
  while IFS= read -r sam; do
    [ -z "$sam" ] && continue
    sam="$(printf '%s' "$sam" | tr '[:upper:]' '[:lower:]')"
    echo "    - ${sam} -> ${grp}"
    ensure_user_in_role "$sam" "$grp"
  done < <(group_members "$GLOBAL_BASE" "$grp")
done

echo "[*] Syncing per-database AD groups -> scoped roles"
perdb_groups="$(ldapsearch -LLL -o ldif-wrap=no -H "$LDAPURI" \
                  -D "$LDAPBINDDN" -w "$LDAPPASSWORD" \
                  -b "$PERDB_BASE" -s one \
                  '(&(objectClass=group)(|(cn=*_readers)(cn=*_writers)(cn=*_ddl)))' cn \
                | sed -n 's/^cn: //p')"
while IFS= read -r grp; do
  [ -z "$grp" ] && continue
  role="$(printf '%s' "$grp" | tr '[:upper:]' '[:lower:]')"
  ensure_role "$role"
  while IFS= read -r sam; do
    [ -z "$sam" ] && continue
    sam="$(printf '%s' "$sam" | tr '[:upper:]' '[:lower:]')"
    echo "    - ${sam} -> ${role}"
    ensure_user_in_role "$sam" "$role"
  done < <(group_members "$PERDB_BASE" "$grp")
done <<< "$perdb_groups"

echo "[*] Role sync complete."
