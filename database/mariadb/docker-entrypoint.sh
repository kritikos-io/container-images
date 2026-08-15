#!/usr/bin/env bash
set -euo pipefail

# Render pam_ldap's config from the environment so the AD bind credentials are
# never baked into the image. pam_ldap performs a search+bind against AD: bind
# as the service account, find the user by ${LDAP_LOGIN_ATTR}, then re-bind as
# that DN with the supplied password to verify it — the same shape as pgpool's
# `ldap` method (see pool_hba.conf).
: "${LDAPURI:?LDAPURI is required (e.g. ldaps://hecate.ad.kritikos.io)}"
: "${LDAP_BASE:?LDAP_BASE is required (e.g. DC=ad,DC=kritikos,DC=io)}"
: "${LDAPBINDDN:?LDAPBINDDN is required (AD service/bind account)}"
: "${LDAPPASSWORD:?LDAPPASSWORD is required}"
: "${LDAP_LOGIN_ATTR:?LDAP_LOGIN_ATTR is required (e.g. sAMAccountName)}"
# demand = validate the AD cert against the trust store; relax to 'allow' only
# for testing, or add your internal CA to the image and keep 'demand'.
: "${LDAP_TLS_REQCERT:?LDAP_TLS_REQCERT is required (demand|allow|never)}"

umask 077
# pam_ldap.so on this image reads /etc/ldap.conf (the PADL default path), and
# libpam-ldap ships a placeholder there (base dc=example,dc=net) that otherwise
# shadows our config and makes every login fail. Render both paths.
for conf in /etc/ldap.conf /etc/pam_ldap.conf; do
  cat > "$conf" <<EOF
uri ${LDAPURI}
base ${LDAP_BASE}
binddn ${LDAPBINDDN}
bindpw ${LDAPPASSWORD}
scope sub
referrals no
pam_login_attribute ${LDAP_LOGIN_ATTR}
pam_filter objectclass=User
tls_cacertdir /etc/ssl/certs
tls_reqcert ${LDAP_TLS_REQCERT}
EOF
  chmod 600 "$conf"
done

# Grant mysql read access to the host TLS key (mode 0640, owned by GID
# ${CERTS_GID}). compose exposes that GID via `group_add`, but the stock
# entrypoint drops root -> mysql with gosu, which rebuilds mysql's groups from
# /etc/group and discards the compose-added GID — mysql then can't read ssl_key
# and MariaDB aborts with "Unable to get private key". While still root, put
# mysql in a group with that GID so it survives the privilege drop.
: "${CERTS_GID:?CERTS_GID is required (GID owning the host TLS key)}"
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
