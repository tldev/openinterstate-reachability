#!/usr/bin/env bash
#
# Delete an EBS volume. Safety check: only deletes volumes
# tagged with project=openinterstate-reachability.
# Usage: delete-ebs.sh <volume-id>
#
set -euo pipefail

VOLUME_ID="${1:?Usage: delete-ebs.sh <volume-id>}"
REGION="${AWS_REGION:-us-east-1}"
MAX_WAIT_ATTEMPTS="${EBS_WAIT_ATTEMPTS:-80}"

log() { echo "[delete-ebs][$(date -u +%FT%TZ)] $*" >&2; }

log "Checking volume ${VOLUME_ID}..."

# Check if the volume exists
VOLUME_INFO=$(aws ec2 describe-volumes \
  --volume-ids "$VOLUME_ID" \
  --region "$REGION" \
  --output json 2>&1) || {
  if echo "$VOLUME_INFO" | grep -q "InvalidVolume.NotFound"; then
    log "Volume ${VOLUME_ID} not found (already deleted). OK."
    exit 0
  fi
  log "ERROR: Failed to describe volume: ${VOLUME_INFO}"
  exit 1
}

# Safety check: verify project tag
PROJECT_TAG=$(echo "$VOLUME_INFO" | jq -r \
  '.Volumes[0].Tags[]? | select(.Key == "project") | .Value // empty')

if [[ "$PROJECT_TAG" != "openinterstate-reachability" ]]; then
  log "ERROR: Volume ${VOLUME_ID} is not tagged project=openinterstate-reachability (got '${PROJECT_TAG}'). Refusing to delete."
  exit 1
fi

# Check volume state — if attached, wait for detach
VOLUME_STATE=$(echo "$VOLUME_INFO" | jq -r '.Volumes[0].State')
if [[ "$VOLUME_STATE" == "in-use" ]]; then
  log "Volume is in-use. Waiting for detachment (max ${MAX_WAIT_ATTEMPTS} attempts)..."
  if ! aws ec2 wait volume-available \
    --volume-ids "$VOLUME_ID" \
    --region "$REGION" \
    --cli-read-timeout 30 2>/dev/null; then
    log "WARNING: Wait timed out. Attempting force-detach..."
    ATTACHMENT_ID=$(echo "$VOLUME_INFO" | jq -r '.Volumes[0].Attachments[0].InstanceId // empty')
    if [[ -n "$ATTACHMENT_ID" ]]; then
      aws ec2 detach-volume \
        --volume-id "$VOLUME_ID" \
        --force \
        --region "$REGION" || true
      log "Force-detach issued. Waiting for volume to become available..."
      aws ec2 wait volume-available \
        --volume-ids "$VOLUME_ID" \
        --region "$REGION" || {
        log "ERROR: Volume ${VOLUME_ID} still not available after force-detach."
        exit 1
      }
    fi
  fi
fi

log "Deleting volume ${VOLUME_ID}..."
aws ec2 delete-volume \
  --volume-id "$VOLUME_ID" \
  --region "$REGION"

log "Volume ${VOLUME_ID} deleted."
