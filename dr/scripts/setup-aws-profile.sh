#!/usr/bin/env bash
# Builds root's AWS profile "dr-restore" from the SOPS-encrypted S3 secret.
set -euo pipefail
export SOPS_AGE_KEY_FILE=/root/.config/sops/age/keys.txt
REGION="${1:?usage: setup-aws-profile.sh <region>}"
J=$(sops -d /opt/dr/secrets/s3-restore.json)
KID=$(jq -r '.data.ACCESS_KEY_ID' <<<"$J" | base64 -d)
SEC=$(jq -r '.data.ACCESS_SECRET_KEY' <<<"$J" | base64 -d)
mkdir -p /root/.aws && chmod 700 /root/.aws
printf '[dr-restore]\naws_access_key_id = %s\naws_secret_access_key = %s\n' "$KID" "$SEC" > /root/.aws/credentials
printf '[profile dr-restore]\nregion = %s\n' "$REGION" > /root/.aws/config
chmod 600 /root/.aws/credentials /root/.aws/config
echo "dr-restore profile written"
