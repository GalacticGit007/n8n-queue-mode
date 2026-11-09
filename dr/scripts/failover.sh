#!/usr/bin/env bash
# Usage: sudo /opt/dr/scripts/failover.sh
set -uo pipefail
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
mkdir -p /var/log/dr
LOG=/var/log/dr/drill-$(date -u +%Y%m%dT%H%M%SZ).log
exec > >(tee -a "$LOG") 2>&1
log(){ echo "[$(date -u +%FT%TZ)] $*"; }
fail(){ log "FAILED: $*"; exit 1; }
BOOT=$(date -d "$(uptime -s)" +%s)

log "waiting for platform to be ready (preflight)"
for i in $(seq 1 60); do
  /opt/dr/scripts/preflight.sh >/dev/null 2>&1 && break
  sleep 10
  [ "$i" -eq 60 ] && { /opt/dr/scripts/preflight.sh; fail "preflight never passed"; }
done
T1=$(date +%s)

timeout 1800 /opt/dr/scripts/restore-db.sh || fail "database restore"
T2=$(date +%s)

/opt/dr/scripts/start-n8n.sh || fail "n8n start"
T3=$(date +%s)

log "SUMMARY boot->platform: $((T1-BOOT))s | db restore: $((T2-T1))s | n8n start: $((T3-T2))s | boot->n8n ready: $((T3-BOOT))s"
log "log saved to $LOG"
