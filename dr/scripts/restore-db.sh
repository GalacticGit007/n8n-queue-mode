#!/usr/bin/env bash
# Run as root: sudo /opt/dr/scripts/restore-db.sh
set -euo pipefail
NS=default; CL=n8n-db-restore; K="k3s kubectl"
APP=container.apparmor.security.beta.kubernetes.io
export SOPS_AGE_KEY_FILE=/root/.config/sops/age/keys.txt

T0=$(date +%s); log(){ echo "[$(date -u +%FT%TZ)] $*"; }

/opt/dr/scripts/preflight.sh

log "applying S3 restore credentials"
sops -d /opt/dr/secrets/s3-restore.json | $K apply -f -

$K get secret n8n-db-restore-s3 -n "$NS" >/dev/null \
  || fail "S3 restore Secret was not created"

log "applying ObjectStore + Cluster (phase 1: recovery Job unconfined)"
$K apply -f /opt/dr/manifests/10-db/objectstore.yaml
$K apply -f /opt/dr/manifests/10-db/cluster.yaml

log "waiting for recovery Job"
until $K get job ${CL}-1-full-recovery -n $NS >/dev/null 2>&1; do sleep 2; done
$K wait --for=condition=complete job/${CL}-1-full-recovery -n $NS --timeout=1800s

log "phase 2: swap AppArmor annotation to the postgres container"
$K annotate cluster $CL -n $NS ${APP}/full-recovery- ${APP}/postgres=unconfined --overwrite

log "waiting for Cluster Ready"
$K wait --for=condition=Ready cluster/$CL -n $NS --timeout=900s

log "verifying"
$K exec -n $NS ${CL}-1 -c postgres -- psql -U postgres -d n8n -Atc \
  "select 'in_recovery='||pg_is_in_recovery(), 'workflows='||(select count(*) from workflow_entity)"
log "DB restore complete in $(( $(date +%s) - T0 ))s"
