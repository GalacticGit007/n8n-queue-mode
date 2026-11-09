#!/usr/bin/env bash
# Run as root: sudo /opt/dr/scripts/restore-db.sh
set -euo pipefail

NS=default
CL=n8n-db-restore
JOB=${CL}-1-full-recovery
K="k3s kubectl"
APP=container.apparmor.security.beta.kubernetes.io
export SOPS_AGE_KEY_FILE=/root/.config/sops/age/keys.txt

T0=$(date +%s)
log(){ echo "[$(date -u +%FT%TZ)] $*"; }
fail(){ log "FAILED: $*"; exit 1; }

/opt/dr/scripts/preflight.sh || fail "preflight"

log "applying S3 restore credentials"
sops -d /opt/dr/secrets/s3-restore.json | $K apply -f -
$K get secret n8n-db-restore-s3 -n "$NS" >/dev/null || fail "S3 restore Secret was not created"

log "applying ObjectStore + Cluster (phase 1: recovery Job unconfined)"
$K apply -f /opt/dr/manifests/10-db/objectstore.yaml
$K apply -f /opt/dr/manifests/10-db/cluster.yaml

log "waiting for recovery Job (max 30 min, fails fast if it keeps failing)"
DEADLINE=$(( $(date +%s) + 1800 )); LAST=""
until [ "$($K get job $JOB -n $NS -o jsonpath='{.status.succeeded}' 2>/dev/null || true)" = "1" ]; do
  F=$($K get job $JOB -n $NS -o jsonpath='{.status.failed}' 2>/dev/null || true)
  if [ "${F:-0}" -ge 2 ]; then
    $K logs job/$JOB -n $NS --all-containers --tail=30 || true
    fail "recovery Job failed ${F} times"
  fi
  [ "$(date +%s)" -gt "$DEADLINE" ] && fail "recovery Job timed out"
  S=$($K get pods -n $NS -l job-name=$JOB --no-headers 2>/dev/null | awk '{print $3}' | paste -sd, - || true)
  if [ "$S" != "$LAST" ]; then log "job pod status: ${S:-<not created yet>}"; LAST=$S; fi
  sleep 10
done

log "phase 2: swap AppArmor annotation to the postgres container"
$K annotate cluster $CL -n $NS ${APP}/full-recovery- ${APP}/postgres=unconfined --overwrite

for i in $(seq 1 20); do
  if $K get pod ${CL}-1 -n $NS >/dev/null 2>&1; then
    if ! $K get pod ${CL}-1 -n $NS -o jsonpath='{.metadata.annotations}' | grep -q "${APP}/postgres"; then
      log "instance pod was created without the AppArmor annotation; recreating it"
      $K delete pod ${CL}-1 -n $NS --wait=true
    fi
    break
  fi
  sleep 3
done

log "waiting for Cluster Ready"
$K wait --for=condition=Ready cluster/$CL -n $NS --timeout=900s || fail "cluster not ready"

log "verifying"
$K exec -n $NS ${CL}-1 -c postgres -- psql -U postgres -d n8n -Atc \
  "select 'in_recovery='||pg_is_in_recovery(), 'workflows='||(select count(*) from workflow_entity)"

log "DB restore complete in $(( $(date +%s) - T0 ))s"
