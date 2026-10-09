#!/usr/bin/env bash
set -euo pipefail
set -f

: "${LDAPURI:?LDAPURI is required (e.g. ldaps://hecate.ad.kritikos.io)}"
: "${LDAP_BASE:?LDAP_BASE is required (e.g. DC=ad,DC=kritikos,DC=io)}"
: "${LDAPBINDDN:?LDAPBINDDN is required (AD service/bind account)}"
: "${LDAPPASSWORD:?LDAPPASSWORD is required}"
: "${LDAP_LOGIN_ATTR:?LDAP_LOGIN_ATTR is required (e.g. sAMAccountName)}"
: "${LDAP_TLS_REQCERT:?LDAP_TLS_REQCERT is required (demand or hard)}"
: "${CERTS_GID:?CERTS_GID is required (GID owning the host TLS key)}"

fail() {
  printf 'ldap-entrypoint: %s\n' "$1" >&2
  exit 1
}

for setting in LDAPURI LDAP_BASE LDAPBINDDN LDAPPASSWORD LDAP_LOGIN_ATTR LDAP_TLS_REQCERT CERTS_GID; do
  [[ ${!setting} != *$'\n'* && ${!setting} != *$'\r'* ]] \
    || fail "$setting must be a single line"
done

case "${LDAP_TLS_REQCERT,,}" in
  demand|hard) ;;
  *) fail "LDAP_TLS_REQCERT must be demand or hard; LDAP certificate verification cannot be disabled" ;;
esac

[[ $LDAP_LOGIN_ATTR =~ ^[A-Za-z][A-Za-z0-9-]*$ ]] \
  || fail "LDAP_LOGIN_ATTR must be an LDAP attribute name"
[[ $CERTS_GID =~ ^[0-9]+$ ]] || fail "CERTS_GID must be numeric"

tls_mode=''
for uri in $LDAPURI; do
  case "$uri" in
    ldaps://*) mode=on ;;
    ldap://*) mode=start_tls ;;
    *) fail "LDAPURI must use ldaps:// or ldap:// with StartTLS" ;;
  esac
  [[ -z $tls_mode || $tls_mode == "$mode" ]] \
    || fail "LDAPURI cannot mix LDAPS and StartTLS endpoints"
  tls_mode=$mode
done
[[ -n $tls_mode ]] || fail "LDAPURI must contain an endpoint"

module=/usr/local/lib/security/pam_ldap_direct.so
helper=/usr/lib/mysql/plugin/auth_pam_tool_dir/auth_pam_tool
ca_file=/etc/ssl/certs/ca-certificates.crt
[[ -r $module ]] || fail "direct LDAP PAM module is missing: $module"
[[ -x $helper && -u $helper ]] || fail "MariaDB's setuid PAM helper is unavailable"
[[ -r $ca_file ]] || fail "system CA bundle is missing: $ca_file"
privileges=$(LC_ALL=C setpriv --dump) \
  || fail "cannot inspect the PAM helper privilege constraints"
no_new_privs=$(printf '%s\n' "$privileges" | sed -n 's/^no_new_privs:[[:space:]]*//p')
case "$no_new_privs" in
  0) ;;
  1) fail "no-new-privileges prevents MariaDB's PAM helper from reading its root-only configuration" ;;
  *) fail "cannot determine the PAM helper privilege constraints" ;;
esac

umask 077
cat > /etc/pam_ldap.conf <<EOF
uri ${LDAPURI}
base ${LDAP_BASE}
binddn ${LDAPBINDDN}
bindpw ${LDAPPASSWORD}
scope sub
referrals no
pam_login_attribute ${LDAP_LOGIN_ATTR}
pam_filter objectclass=User
ssl ${tls_mode}
tls_cacertfile ${ca_file}
tls_checkpeer yes
EOF
chmod 600 /etc/pam_ldap.conf

if [ "$(id -u)" = '0' ]; then
  if getent group "${CERTS_GID}" >/dev/null; then
    certgroup="$(getent group "${CERTS_GID}" | cut -d: -f1)"
  else
    groupadd -g "${CERTS_GID}" hostcerts
    certgroup=hostcerts
  fi
  usermod -aG "$certgroup" mysql
else
  echo "ldap-entrypoint: not root (uid $(id -u)); left group membership unchanged (CERTS_GID=${CERTS_GID})" >&2
fi

exec docker-entrypoint.sh "$@"
