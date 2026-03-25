#!/usr/bin/env bash
#
# Attach and mount an EBS volume inside a Batch container.
# Discovers the host instance via IMDSv2, attaches the volume,
# formats if needed, and mounts to the specified path.
#
# Usage: mount-ebs.sh <volume-id> <mount-path>
# Requires: privileged container, Batch job role with EC2 permissions,
#           HttpPutResponseHopLimit >= 2 on the instance launch template.
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

# ─── Attach volume if not already attached to this instance ──────
CURRENT_STATE=$(aws ec2 describe-volumes \
  --volume-ids "$VOLUME_ID" \
  --region "$REGION" \
  --query 'Volumes[0].Attachments[?InstanceId==`'"$INSTANCE_ID"'`].State' \
  --output text 2>/dev/null || echo "")

FRESH_ATTACH=false

if [[ "$CURRENT_STATE" == "attached" ]]; then
  log "Volume already attached to this instance"
else
  FRESH_ATTACH=true
  LSBLK_BEFORE=$(lsblk -dpn -o NAME 2>/dev/null | sort || true)

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
fi

# ─── Discover block device ───────────────────────────────────────
# Nitro/NVMe instances expose /dev/xvdf as /dev/nvmeNn1 instead.
# Discovery order: direct path, lsblk diff (fresh attach), /dev/disk/by-id symlink.
log "Discovering block device..."
log "DEBUG: FRESH_ATTACH=${FRESH_ATTACH}"
log "DEBUG: LSBLK_BEFORE='${LSBLK_BEFORE:-}'"
log "DEBUG: /dev/fd exists=$(test -d /dev/fd && echo yes || echo no)"
log "DEBUG: /dev/disk/by-id exists=$(test -d /dev/disk/by-id && echo yes || echo no)"
if [[ -d /dev/disk/by-id ]]; then
  log "DEBUG: /dev/disk/by-id contents=$(ls /dev/disk/by-id/ 2>/dev/null || echo EMPTY)"
fi
REAL_DEVICE=""
for i in $(seq 1 15); do
  # Method 1: direct device path (non-NVMe instances)
  if [[ -b "$DEVICE" ]]; then
    REAL_DEVICE="$DEVICE"
    log "DEBUG: Method 1 found ${DEVICE}"
    break
  fi

  # Method 2: lsblk diff (NVMe instances, fresh attachment)
  if $FRESH_ATTACH; then
    LSBLK_AFTER=$(lsblk -dpn -o NAME 2>/dev/null | sort || true)
    if [[ $i -le 3 ]]; then
      log "DEBUG: Method 2 iter ${i}: AFTER='${LSBLK_AFTER}'"
    fi
    NEW_DEV=$(comm -13 <(echo "${LSBLK_BEFORE:-}") <(echo "$LSBLK_AFTER") | head -1) || true
    if [[ $i -le 3 ]]; then
      log "DEBUG: Method 2 iter ${i}: NEW_DEV='${NEW_DEV}' is_block=$(test -b "${NEW_DEV:-/nonexistent}" && echo yes || echo no)"
    fi
    if [[ -n "$NEW_DEV" && -b "$NEW_DEV" ]]; then
      REAL_DEVICE="$NEW_DEV"
      break
    fi
  fi

  # Method 3: /dev/disk/by-id symlink (already-attached or fallback)
  VOLID_NODASH="${VOLUME_ID//-/}"
  if [[ $i -le 3 ]]; then
    log "DEBUG: Method 3 iter ${i}: looking for /dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${VOLID_NODASH}*"
    log "DEBUG: Method 3 iter ${i}: glob result=$(ls -la /dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${VOLID_NODASH}* 2>&1 || echo NO_MATCH)"
  fi
  for link in /dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${VOLID_NODASH}*; do
    if [[ -e "$link" ]]; then
      CANDIDATE=$(readlink -f "$link")
      log "DEBUG: Method 3 found link=${link} -> ${CANDIDATE}"
      if [[ -b "$CANDIDATE" ]]; then
        REAL_DEVICE="$CANDIDATE"
        break 2
      fi
    fi
  done

  if [[ $i -eq 15 ]]; then
    log "ERROR: Block device not found after 30 seconds"
    log "DEBUG: Final lsblk -dpn -o NAME: $(lsblk -dpn -o NAME 2>/dev/null || echo FAILED)"
    log "DEBUG: Final lsblk full:"
    lsblk >&2
    exit 1
  fi
  sleep 2
done
log "Block device: ${REAL_DEVICE}"

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
