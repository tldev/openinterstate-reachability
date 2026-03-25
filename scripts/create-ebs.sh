#!/usr/bin/env bash
#
# Create an ephemeral EBS volume for the pipeline run.
# Usage: create-ebs.sh <availability-zone> <pipeline-run-id>
# Outputs the volume ID to stdout.
#
set -euo pipefail

AZ="${1:?Usage: create-ebs.sh <availability-zone> <pipeline-run-id>}"
PIPELINE_RUN_ID="${2:?Usage: create-ebs.sh <availability-zone> <pipeline-run-id>}"
VOLUME_SIZE="${EBS_VOLUME_SIZE:-300}"
VOLUME_TYPE="${EBS_VOLUME_TYPE:-gp3}"
REGION="${AWS_REGION:-us-east-1}"

echo "[$(date -u +%FT%TZ)] Creating ${VOLUME_SIZE}GB ${VOLUME_TYPE} EBS volume in ${AZ}..."

VOLUME_ID=$(aws ec2 create-volume \
  --availability-zone "$AZ" \
  --size "$VOLUME_SIZE" \
  --volume-type "$VOLUME_TYPE" \
  --tag-specifications "ResourceType=volume,Tags=[
    {Key=pipeline-run,Value=${PIPELINE_RUN_ID}},
    {Key=ttl,Value=24h},
    {Key=project,Value=pike-reachability},
    {Key=Name,Value=pike-reachability-${PIPELINE_RUN_ID}}
  ]" \
  --region "$REGION" \
  --output text \
  --query 'VolumeId')

echo "[$(date -u +%FT%TZ)] Created volume ${VOLUME_ID}"

# Wait for volume to become available
echo "[$(date -u +%FT%TZ)] Waiting for volume to become available..."
aws ec2 wait volume-available \
  --volume-ids "$VOLUME_ID" \
  --region "$REGION"

echo "[$(date -u +%FT%TZ)] Volume ${VOLUME_ID} is available"
echo "$VOLUME_ID"
