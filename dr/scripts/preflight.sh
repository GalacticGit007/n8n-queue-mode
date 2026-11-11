#!/usr/bin/env bash
fail=0; ok(){ echo "OK   $*"; }; bad(){ echo "FAIL $*"; fail=1; }
K="k3s kubectl"
timedatectl show -p NTPSynchronized --value | grep -q yes && ok "clock synced" || bad "clock not synced"
aws sts get-caller-identity --profile dr-restore >/dev/null 2>&1 && ok "AWS identity" || bad "AWS credentials (root needs ~/.aws)"
aws s3 ls s3://n8n-dr-backups-20261023-8f039112/n8n-db-logical/ --profile dr-restore >/dev/null 2>&1 && ok "S3 prefix readable" || bad "S3 read"
$K get nodes --no-headers | grep -q ' Ready' && ok "node Ready" || bad "node"
for ns in cert-manager cnpg-system; do
  $K wait --for=condition=Available deploy --all -n "$ns" --timeout=60s >/dev/null 2>&1 && ok "$ns ready" || bad "$ns"
done
[ -f /root/.config/sops/age/keys.txt ] && ok "age key present" || bad "age key"
[ "$(df --output=avail -BG /var/lib/rancher | tail -1 | tr -dc 0-9)" -gt 15 ] && ok "disk >15G free" || bad "disk"
exit $fail
