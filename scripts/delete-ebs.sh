#!/usr/bin/env bash
#
# Delete an EBS volume. Safety check: only deletes volumes
# tagged with project=pike-reachability.
# Usage: delete-ebs.sh <volume-id>
#
set -euo pipefail

VOLUME_ID="${1:?Usage: delete-ebs.sh <volume-id>}"
REGION="${AWS_REGION:-us-east-1}"

echo "[$(date -u +%FT%TZ)] Checking volume ${VOLUME_ID}..."

# Check if the volume exists
VOLUME_INFO=$(aws ec2 describe-volumes \
  --volume-ids "$VOLUME_ID" \
  --region "$REGION" \
  --output json 2>&1) || {
  if echo "$VOLUME_INFO" | grep -q "InvalidVolume.NotFound"; then
    echo "[$(date -u +%FT%TZ)] Volume ${VOLUME_ID} not found (already deleted). OK."
    exit 0
  fi
  echo "[$(date -u +%FT%TZ)] ERROR: Failed to describe volume: ${VOLUME_INFO}" >&2
  exit 1
}

# Safety check: verify project tag
PROJECT_TAG=$(echo "$VOLUME_INFO" | jq -r \
  '.Volumes[0].Tags[]? | select(.Key == "project") | .Value // empty')

if [[ "$PROJECT_TAG" != "pike-reachability" ]]; then
  echo "[$(date -u +%FT%TZ)] ERROR: Volume ${VOLUME_ID} is not tagged project=pike-reachability (got '${PROJECT_TAG}'). Refusing to delete." >&2
  exit 1
fi

# Check volume state — if attached, wait for detach
VOLUME_STATE=$(echo "$VOLUME_INFO" | jq -r '.Volumes[0].State')
if [[ "$VOLUME_STATE" == "in-use" ]]; then
  echo "[$(date -u +%FT%TZ)] Volume is in-use. Waiting for detachment..."
  aws ec2 wait volume-available \
    --volume-ids "$VOLUME_ID" \
    --region "$REGION" || true
fi

echo "[$(date -u +%FT%TZ)] Deleting volume ${VOLUME_ID}..."
aws ec2 delete-volume \
  --volume-id "$VOLUME_ID" \
  --region "$REGION"

echo "[$(date -u +%FT%TZ)] Volume ${VOLUME_ID} deleted."
