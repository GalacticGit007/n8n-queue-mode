#!/usr/bin/env bash
# Logical PostgreSQL restore from S3 into a fresh CNPG cluster.
# Run as root. The target Cluster and PVC must not already exist.

set -Eeuo pipefail

NS="default"
CL="n8n-db-restore"
POD="${CL}-1"

BUCKET="n8n-dr-backups-20261023-8f039112"
PREFIX="n8n-db-logical/"
REGION="ap-south-1"
PROFILE="dr-restore"

SECRET_BUNDLE="/opt/dr/secrets/n8n-secrets.json"
AGE_KEY="/root/.config/sops/age/keys.txt"
MANIFEST="/opt/dr/manifests/10-db/logical-restore-cluster.yaml"

K=(k3s kubectl)
T0=$(date +%s)
DUMP=""
POD_READY=false

log() {
    echo "[$(date -u +%FT%TZ)] $*"
}

fail() {
    log "FAILED: $*"
    exit 1
}

cleanup() {
    if [[ -n "$DUMP" ]]; then
        rm -f "$DUMP"
    fi

    if [[ "$POD_READY" == true ]]; then
        "${K[@]}" exec -n "$NS" "$POD" -c postgres -- \
            rm -f /dev/shm/n8n-db.dump >/dev/null 2>&1 || true
    fi
}

trap cleanup EXIT

# --------------------------------------------------
# 1. Prerequisites
# --------------------------------------------------

[[ "$EUID" -eq 0 ]] || fail "run as root"

for cmd in aws sops date stat mktemp; do
    command -v "$cmd" >/dev/null 2>&1 || fail "missing command: $cmd"
done

[[ -f "$AGE_KEY" ]] || fail "AGE key missing"
[[ -f "$SECRET_BUNDLE" ]] || fail "n8n secret bundle missing"
[[ -f "$MANIFEST" ]] || fail "logical CNPG manifest missing"

aws sts get-caller-identity \
    --profile "$PROFILE" >/dev/null \
    || fail "AWS authentication failed"

"${K[@]}" get node >/dev/null \
    || fail "Kubernetes API unavailable"

log "prerequisites verified"

# --------------------------------------------------
# 2. Protect existing database resources
# --------------------------------------------------

if "${K[@]}" get cluster "$CL" -n "$NS" >/dev/null 2>&1; then
    fail "Cluster $CL already exists; refusing to overwrite it"
fi

if "${K[@]}" get pvc "${CL}-1" -n "$NS" >/dev/null 2>&1; then
    fail "PVC ${CL}-1 already exists; inspect it before proceeding"
fi

log "no existing target Cluster or PVC found"

# --------------------------------------------------
# 3. Select latest logical backup
# --------------------------------------------------

LATEST_KEY=$(
    aws s3api list-objects-v2 \
        --bucket "$BUCKET" \
        --prefix "$PREFIX" \
        --profile "$PROFILE" \
        --region "$REGION" \
        --query "sort_by(Contents[?ends_with(Key, '.dump')], &LastModified)[-1].Key" \
        --output text
)

[[ -n "$LATEST_KEY" && "$LATEST_KEY" != "None" ]] \
    || fail "no logical dump found in S3"

OBJECT_INFO=$(
    aws s3api head-object \
        --bucket "$BUCKET" \
        --key "$LATEST_KEY" \
        --profile "$PROFILE" \
        --region "$REGION" \
        --query '[ContentLength,LastModified]' \
        --output text
)

read -r EXPECTED_SIZE LAST_MODIFIED <<< "$OBJECT_INFO"

[[ "$EXPECTED_SIZE" =~ ^[0-9]+$ ]] \
    || fail "invalid S3 object size"

log "selected backup: $LATEST_KEY"
log "S3 LastModified: $LAST_MODIFIED"
log "expected size: $EXPECTED_SIZE bytes"

# --------------------------------------------------
# 4. Download and validate file size
# --------------------------------------------------

DUMP=$(mktemp /var/tmp/n8n-db-restore-XXXXXX.dump)

aws s3 cp \
    "s3://${BUCKET}/${LATEST_KEY}" \
    "$DUMP" \
    --profile "$PROFILE" \
    --region "$REGION" \
    || fail "S3 download failed"

ACTUAL_SIZE=$(stat -c '%s' "$DUMP")

[[ "$ACTUAL_SIZE" -eq "$EXPECTED_SIZE" ]] \
    || fail "download size mismatch"

log "download verified: $ACTUAL_SIZE bytes"

# --------------------------------------------------
# 5. Apply credentials
# --------------------------------------------------

log "applying encrypted Kubernetes secrets"

export SOPS_AGE_KEY_FILE="$AGE_KEY"

sops -d "$SECRET_BUNDLE" | "${K[@]}" apply -f - \
    || fail "secret application failed"

"${K[@]}" get secret n8n-db-credentials -n "$NS" \
    -o jsonpath='{.data.username}' | grep -q . \
    || fail "database username Secret key missing"

"${K[@]}" get secret n8n-db-credentials -n "$NS" \
    -o jsonpath='{.data.password}' | grep -q . \
    || fail "database password Secret key missing"

log "database credentials verified"

# --------------------------------------------------
# 6. Create fresh CNPG cluster
# --------------------------------------------------

log "creating fresh CNPG cluster"

"${K[@]}" apply -f "$MANIFEST" \
    || fail "CNPG manifest application failed"

"${K[@]}" wait \
    --for=condition=Ready \
    "cluster/$CL" \
    -n "$NS" \
    --timeout=900s \
    || fail "CNPG Cluster did not become Ready"

"${K[@]}" wait \
    --for=condition=Ready \
    "pod/$POD" \
    -n "$NS" \
    --timeout=300s \
    || fail "PostgreSQL pod did not become Ready"

POD_READY=true

"${K[@]}" exec -n "$NS" "$POD" -c postgres -- \
    pg_isready -U postgres -d n8n \
    || fail "PostgreSQL is not accepting connections"

log "fresh PostgreSQL cluster is ready"

# --------------------------------------------------
# 7. Ensure target database is empty
# --------------------------------------------------

TABLE_COUNT=$(
    "${K[@]}" exec -n "$NS" "$POD" -c postgres -- \
        psql -U postgres -d n8n -Atc \
        "SELECT count(*) FROM information_schema.tables
         WHERE table_schema='public' AND table_type='BASE TABLE';"
)

[[ "$TABLE_COUNT" == "0" ]] \
    || fail "target database is not empty ($TABLE_COUNT tables)"

log "target database confirmed empty"

# --------------------------------------------------
# 8. Transfer and validate archive
# --------------------------------------------------

log "copying backup into PostgreSQL pod"

"${K[@]}" exec -i -n "$NS" "$POD" -c postgres -- \
    sh -c 'cat > /dev/shm/n8n-db.dump' < "$DUMP" \
    || fail "backup transfer failed"

log "validating PostgreSQL archive"

"${K[@]}" exec -n "$NS" "$POD" -c postgres -- \
    pg_restore --list /dev/shm/n8n-db.dump >/dev/null \
    || fail "pg_restore archive validation failed"

log "archive validation passed"

# --------------------------------------------------
# 9. Restore database transactionally
# --------------------------------------------------

log "starting logical PostgreSQL restore"

"${K[@]}" exec -n "$NS" "$POD" -c postgres -- \
    pg_restore \
        --exit-on-error \
        --single-transaction \
        --no-owner \
        --role=n8n \
        -U postgres \
        -d n8n \
        /dev/shm/n8n-db.dump \
    || fail "pg_restore failed"

log "logical restore command completed"

# --------------------------------------------------
# 10. Verify restored database
# --------------------------------------------------

RESULT=$(
    "${K[@]}" exec -n "$NS" "$POD" -c postgres -- \
        psql -U postgres -d n8n -AtF '|' -c "
        SELECT
            pg_is_in_recovery(),
            (SELECT count(*) FROM workflow_entity),
            (SELECT count(*) FROM credentials_entity),
            (SELECT count(*) FROM execution_entity),
            (SELECT count(*) FROM \"user\"),
            (SELECT count(*) FROM pg_tables
             WHERE schemaname='public' AND tableowner <> 'n8n'),
            (SELECT count(*) FROM pg_index WHERE NOT indisvalid);
        "
) || fail "database verification query failed"

IFS='|' read -r IN_RECOVERY WORKFLOWS CREDENTIALS EXECUTIONS USERS WRONG_OWNERS INVALID_INDEXES <<< "$RESULT"

[[ "$IN_RECOVERY" == "f" ]] \
    || fail "database unexpectedly in recovery mode"

[[ "$WORKFLOWS" =~ ^[0-9]+$ && "$WORKFLOWS" -gt 0 ]] \
    || fail "no workflows found after restore"

[[ "$WRONG_OWNERS" == "0" ]] \
    || fail "$WRONG_OWNERS tables have unexpected owners"

[[ "$INVALID_INDEXES" == "0" ]] \
    || fail "$INVALID_INDEXES invalid indexes found"

log "database verification passed"
log "workflows: $WORKFLOWS"
log "credentials: $CREDENTIALS"
log "executions: $EXECUTIONS"
log "users: $USERS"
log "unexpected table owners: $WRONG_OWNERS"
log "invalid indexes: $INVALID_INDEXES"

log "Cluster status:"
"${K[@]}" get cluster "$CL" -n "$NS"

log "DB restore completed in $(( $(date +%s) - T0 )) seconds"
