#!/usr/bin/env bash
#
# Unmount and detach an EBS volume from the current instance.
# Safe to call if volume is not mounted or not attached.
#
# Usage: unmount-ebs.sh <volume-id> <mount-path>
#
set -euo pipefail

VOLUME_ID="${1:?Usage: unmount-ebs.sh <volume-id> <mount-path>}"
MOUNT_PATH="${2:-/mnt/osrm}"
REGION="${AWS_REGION:-us-east-1}"

log() { echo "[unmount-ebs][$(date -u +%FT%TZ)] $*" >&2; }

# ─── Unmount ─────────────────────────────────────────────────────
if mountpoint -q "$MOUNT_PATH" 2>/dev/null; then
  log "Unmounting ${MOUNT_PATH}..."
  sync
  umount "$MOUNT_PATH"
  log "Unmounted"
else
  log "${MOUNT_PATH} is not mounted, skipping unmount"
fi

# ─── Get instance ID ─────────────────────────────────────────────
TOKEN=$(curl -sf -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null || true)
INSTANCE_ID=$(curl -sf "http://169.254.169.254/latest/meta-data/instance-id" \
  -H "X-aws-ec2-metadata-token: $TOKEN" 2>/dev/null || true)

if [[ -z "$INSTANCE_ID" ]]; then
  log "Could not determine instance ID, skipping detach"
  exit 0
fi

# ─── Detach volume ───────────────────────────────────────────────
ATTACH_STATE=$(aws ec2 describe-volumes \
  --volume-ids "$VOLUME_ID" \
  --region "$REGION" \
  --query 'Volumes[0].Attachments[?InstanceId==`'"$INSTANCE_ID"'`].State' \
  --output text 2>/dev/null || echo "")

if [[ "$ATTACH_STATE" == "attached" ]]; then
  log "Detaching volume ${VOLUME_ID} from ${INSTANCE_ID}..."
  aws ec2 detach-volume \
    --volume-id "$VOLUME_ID" \
    --instance-id "$INSTANCE_ID" \
    --region "$REGION"

  # Wait for detachment
  for i in $(seq 1 30); do
    STATE=$(aws ec2 describe-volumes \
      --volume-ids "$VOLUME_ID" \
      --region "$REGION" \
      --query 'Volumes[0].State' \
      --output text 2>/dev/null || echo "")
    if [[ "$STATE" == "available" ]]; then
      log "Volume detached"
      break
    fi
    sleep 2
  done
else
  log "Volume not attached to this instance (state: ${ATTACH_STATE:-none}), skipping detach"
fi

log "EBS cleanup complete for ${VOLUME_ID}"
