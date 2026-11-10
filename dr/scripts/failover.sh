#!/usr/bin/env bash
# Usage: sudo /opt/dr/scripts/failover.sh

set -Eeuo pipefail

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

mkdir -p /var/log/dr

LOG="/var/log/dr/drill-$(date -u +%Y%m%dT%H%M%SZ)-$$.log"
exec > >(tee -a "$LOG") 2>&1

log() {
    echo "[$(date -u +%FT%TZ)] $*"
}

fail() {
    log "FAILED: $*"
    exit 1
}

# Measure both execution time and VM boot-to-ready time.
RECOVERY_START=$(date +%s)
BOOT_EPOCH=$(date -d "$(uptime -s)" +%s)

log "DR failover started"
log "waiting for platform prerequisites"

# --------------------------------------------------
# 1. Preflight
# --------------------------------------------------

PREFLIGHT_OK=false

for i in $(seq 1 60); do
    if /opt/dr/scripts/preflight.sh; then
        PREFLIGHT_OK=true
        break
    fi

    log "preflight attempt $i failed; retrying in 10 seconds"
    sleep 10
done

[ "$PREFLIGHT_OK" = true ] || fail "preflight never passed"

PREFLIGHT_READY=$(date +%s)
log "preflight passed"

# --------------------------------------------------
# 2. Database restore
# --------------------------------------------------

DB_START=$(date +%s)

timeout 1800 /opt/dr/scripts/restore-db.sh \
    || fail "database restore"

DB_READY=$(date +%s)
log "database restore completed"

# --------------------------------------------------
# 3. Start application
# --------------------------------------------------

APP_START=$(date +%s)

/opt/dr/scripts/start-n8n.sh \
    || fail "n8n startup"

# --------------------------------------------------
# 4. Final application verification
# --------------------------------------------------

log "performing final ingress health check"

INGRESS_OK=false

for i in $(seq 1 30); do
    if curl -fsS \
        -H "Host: n8n.lab.local" \
        http://127.0.0.1/healthz >/dev/null 2>&1; then

        INGRESS_OK=true
        break
    fi

    sleep 2
done

[ "$INGRESS_OK" = true ] || fail "final ingress verification failed"

APP_READY=$(date +%s)

log "n8n application is ready"

# --------------------------------------------------
# 5. Recovery measurements
# --------------------------------------------------

log "========== DR RECOVERY SUMMARY =========="

log "preflight: $((PREFLIGHT_READY-RECOVERY_START)) seconds"
log "database restore: $((DB_READY-DB_START)) seconds"
log "application startup and verification: $((APP_READY-APP_START)) seconds"

log "recovery execution time: $((APP_READY-RECOVERY_START)) seconds"
log "VM boot-to-ready time: $((APP_READY-BOOT_EPOCH)) seconds"

log "========================================="
log "DR failover completed successfully"
log "log saved to $LOG"
