#!/usr/bin/env bash
#
# Attach and mount an EBS volume inside a Batch container.
# Discovers the host instance via IMDSv2, attaches the volume,
# formats if needed, and mounts to the specified path.
#
# Usage: mount-ebs.sh <volume-id> <mount-path>
# Requires: privileged container, Batch job role with EC2 permissions
#
set -euo pipefail

VOLUME_ID="${1:?Usage: mount-ebs.sh <volume-id> <mount-path>}"
MOUNT_PATH="${2:-/mnt/osrm}"
DEVICE="${EBS_DEVICE:-/dev/xvdf}"
REGION="${AWS_REGION:-us-east-1}"

log() { echo "[mount-ebs][$(date -u +%FT%TZ)] $*" >&2; }

# ─── Get instance ID via IMDSv2 ──────────────────────────────────
log "Discovering instance ID via IMDSv2..."
TOKEN=$(curl -sf -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
INSTANCE_ID=$(curl -sf "http://169.254.169.254/latest/meta-data/instance-id" \
  -H "X-aws-ec2-metadata-token: $TOKEN")
log "Running on instance ${INSTANCE_ID}"

# ─── Check if volume is already attached to this instance ────────
CURRENT_STATE=$(aws ec2 describe-volumes \
  --volume-ids "$VOLUME_ID" \
  --region "$REGION" \
  --query 'Volumes[0].Attachments[?InstanceId==`'"$INSTANCE_ID"'`].State' \
  --output text 2>/dev/null || echo "")

if [[ "$CURRENT_STATE" == "attached" ]]; then
  log "Volume already attached to this instance"
else
  # Wait for volume to be available (may still be detaching from previous job)
  log "Waiting for volume ${VOLUME_ID} to be available..."
  for i in $(seq 1 60); do
    STATE=$(aws ec2 describe-volumes \
      --volume-ids "$VOLUME_ID" \
      --region "$REGION" \
      --query 'Volumes[0].State' \
      --output text)
    if [[ "$STATE" == "available" ]]; then
      break
    fi
    if [[ $i -eq 60 ]]; then
      log "ERROR: Volume not available after 5 minutes (state: ${STATE})"
      exit 1
    fi
    sleep 5
  done

  # ─── Attach volume ───────────────────────────────────────────
  log "Attaching volume ${VOLUME_ID} to ${INSTANCE_ID} as ${DEVICE}..."
  aws ec2 attach-volume \
    --volume-id "$VOLUME_ID" \
    --instance-id "$INSTANCE_ID" \
    --device "$DEVICE" \
    --region "$REGION"

  # Wait for attachment
  log "Waiting for attachment..."
  for i in $(seq 1 30); do
    ATTACH_STATE=$(aws ec2 describe-volumes \
      --volume-ids "$VOLUME_ID" \
      --region "$REGION" \
      --query 'Volumes[0].Attachments[0].State' \
      --output text)
    if [[ "$ATTACH_STATE" == "attached" ]]; then
      break
    fi
    if [[ $i -eq 30 ]]; then
      log "ERROR: Volume attachment timed out (state: ${ATTACH_STATE})"
      exit 1
    fi
    sleep 2
  done
  log "Volume attached"

  # Wait for device to appear
  REAL_DEVICE="$DEVICE"
  # AWS may map xvdf to nvme* on nitro instances
  for i in $(seq 1 15); do
    if [[ -b "$DEVICE" ]]; then
      REAL_DEVICE="$DEVICE"
      break
    fi
    # Check for NVMe mapping
    NVME_DEV=$(lsblk -o NAME,SERIAL -dpn 2>/dev/null | grep "${VOLUME_ID//-/}" | awk '{print $1}' || true)
    if [[ -n "$NVME_DEV" && -b "$NVME_DEV" ]]; then
      REAL_DEVICE="$NVME_DEV"
      break
    fi
    if [[ $i -eq 15 ]]; then
      log "ERROR: Block device not found after attachment"
      lsblk >&2
      exit 1
    fi
    sleep 2
  done
  log "Block device: ${REAL_DEVICE}"
fi

# ─── Determine actual device path ────────────────────────────────
if [[ -z "${REAL_DEVICE:-}" ]]; then
  if [[ -b "$DEVICE" ]]; then
    REAL_DEVICE="$DEVICE"
  else
    NVME_DEV=$(lsblk -o NAME,SERIAL -dpn 2>/dev/null | grep "${VOLUME_ID//-/}" | awk '{print $1}' || true)
    REAL_DEVICE="${NVME_DEV:-$DEVICE}"
  fi
fi

# ─── Format if no filesystem ─────────────────────────────────────
if ! blkid "$REAL_DEVICE" >/dev/null 2>&1; then
  log "No filesystem detected — formatting as ext4..."
  mkfs.ext4 -q "$REAL_DEVICE"
  log "Format complete"
else
  log "Existing filesystem detected: $(blkid -s TYPE -o value "$REAL_DEVICE")"
fi

# ─── Mount ───────────────────────────────────────────────────────
mkdir -p "$MOUNT_PATH"
if mountpoint -q "$MOUNT_PATH" 2>/dev/null; then
  log "Already mounted at ${MOUNT_PATH}"
else
  mount "$REAL_DEVICE" "$MOUNT_PATH"
  log "Mounted ${REAL_DEVICE} at ${MOUNT_PATH}"
fi

log "EBS volume ${VOLUME_ID} ready at ${MOUNT_PATH}"
df -h "$MOUNT_PATH" >&2
