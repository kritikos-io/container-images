#!/bin/sh
# Watch for acme.sh reload signals and invoke the TrueNAS deploy.
#
# The acme service (see compose.yaml) touches /certs/.deploy-signal after
# every successful --issue / --renew via --reloadcmd. This script waits for
# the signal file to change and re-runs the deploy.
set -eu

SIGNAL_DIR="/certs"
SIGNAL_FILE=".deploy-signal"
DEBOUNCE_SECONDS="${DEPLOY_DEBOUNCE_SECONDS:-3}"

log() { printf '[%s] %s\n' "$(date -Iseconds)" "$*"; }

# Prime: run once at startup so an initial deploy happens after a fresh
# --issue (or after the sidecar itself is recreated).
log "startup deploy"
python3 /usr/local/bin/deploy.py || log "startup deploy returned non-zero"

log "watching $SIGNAL_DIR/$SIGNAL_FILE"
# --include filters the parent-directory events to just our signal file.
# NB: anchored regex (`^...$`) does not fire reliably in inotifywait; the
# file name is unique in the watched directory so a substring match is safe.
inotifywait -m -q \
    -e close_write -e create -e attrib -e moved_to \
    --include "${SIGNAL_FILE}" \
    "$SIGNAL_DIR" |
while read -r _ _ _; do
    # Debounce: coalesce bursts (acme issues + renews may touch several times).
    sleep "$DEBOUNCE_SECONDS"
    log "signal received, deploying"
    python3 /usr/local/bin/deploy.py || log "deploy returned non-zero"
done
