#!/usr/bin/env bash
set -euo pipefail
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
K="k3s kubectl"; export SOPS_AGE_KEY_FILE=/root/.config/sops/age/keys.txt
SRC=/opt/dr/src/n8n-queue-mode
DBHOST=${DB_HOST:-n8n-db-restore-rw}
T0=$(date +%s); log(){ echo "[$(date -u +%FT%TZ)] $*"; }
H="helm upgrade --install n8n-platform $SRC/Charts/n8n-platform -n default --set n8n.database.host=$DBHOST"

log "secrets"; for f in /opt/dr/secrets/*.json; do sops -d "$f" | $K apply -f -; done
log "redis";   $K apply -k $SRC/Infrastructure/redis; $K rollout status deploy/n8n-redis -n default --timeout=180s
log "main";    $H --set worker.replicaCount=0; $K rollout status deploy/n8n-platform-main -n default --timeout=300s
log "worker";  $H --set worker.replicaCount=1; $K rollout status deploy/n8n-platform-worker -n default --timeout=300s
$K get pods -n default
log "checking ingress"
for i in $(seq 1 30); do curl -fsS -H "Host: n8n.lab.local" http://127.0.0.1/healthz >/dev/null 2>&1 && { log "ingress OK"; break; }; sleep 2; done
log "n8n up in $(( $(date +%s) - T0 ))s"
