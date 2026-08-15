#!/usr/bin/env bash
set -euo pipefail

# Runs once on first cluster init (empty datadir), the analogue of
# init_pgpool_user.sql. Creates the infrastructure accounts (MaxScale monitor +
# service, and the replication user) on the backend. All use native password
# auth (NOT pam) — they are service accounts, not human AD logins. Passwords
# come from the environment so nothing secret is committed to a .sql file, and
# the root password goes via MYSQL_PWD (read by the client) rather than -p so it
# never appears in the process list.

: "${MARIADB_ROOT_PASSWORD:?}"
: "${MAXSCALE_MONITOR_PASSWORD:?}"
: "${MAXSCALE_SERVICE_PASSWORD:?}"
: "${MARIADB_REPL_PASSWORD:?}"

MYSQL_PWD="${MARIADB_ROOT_PASSWORD}" mariadb --protocol=socket -uroot <<SQL
-- Monitor account: mariadbmon health checks, replication state, and failover.
CREATE USER IF NOT EXISTS 'maxscale_monitor'@'%' IDENTIFIED BY '${MAXSCALE_MONITOR_PASSWORD}';
GRANT BINLOG MONITOR, SLAVE MONITOR, REPLICATION SLAVE, REPLICATION MASTER ADMIN,
      REPLICATION SLAVE ADMIN, READ_ONLY ADMIN, RELOAD, PROCESS,
      SHOW DATABASES, EVENT
  ON *.* TO 'maxscale_monitor'@'%';

-- Service account: reads the user tables so MaxScale can authenticate clients
-- and route them (pass-through auth defers the real check to the backend PAM).
CREATE USER IF NOT EXISTS 'maxscale_service'@'%' IDENTIFIED BY '${MAXSCALE_SERVICE_PASSWORD}';
GRANT SELECT ON mysql.* TO 'maxscale_service'@'%';
GRANT SHOW DATABASES ON *.* TO 'maxscale_service'@'%';

-- Replication account: the replica's IO thread uses this to stream the binlog.
CREATE USER IF NOT EXISTS 'repl'@'%' IDENTIFIED BY '${MARIADB_REPL_PASSWORD}';
GRANT REPLICATION SLAVE ON *.* TO 'repl'@'%';
SQL
