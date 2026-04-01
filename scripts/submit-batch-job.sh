#!/usr/bin/env bash
#
# Submit an AWS Batch job with the EBS volume ID passed as an
# environment variable. The container runs privileged and uses
# mount-ebs.sh to self-attach the volume via IMDSv2 at startup,
# then unmount-ebs.sh detaches it on exit.
#
# Usage: submit-batch-job.sh <job-definition> <job-queue> <volume-id> <pipeline-run-id>
# Outputs the job ID to stdout (logs go to stderr).
#
set -euo pipefail

JOB_DEFINITION="${1:?Usage: submit-batch-job.sh <job-definition> <job-queue> <volume-id> <pipeline-run-id>}"
JOB_QUEUE="${2:?Usage: submit-batch-job.sh <job-definition> <job-queue> <volume-id> <pipeline-run-id>}"
VOLUME_ID="${3:?Usage: submit-batch-job.sh <job-definition> <job-queue> <volume-id> <pipeline-run-id>}"
PIPELINE_RUN_ID="${4:?Usage: submit-batch-job.sh <job-definition> <job-queue> <volume-id> <pipeline-run-id>}"
REGION="${AWS_REGION:-us-east-1}"
S3_BUCKET="${S3_BUCKET:-}"
OI_RELEASE_TAG="${OI_RELEASE_TAG:-}"

log() { echo "[submit-batch-job][$(date -u +%FT%TZ)] $*" >&2; }

# Extract short name from job definition for the job name
JOB_NAME="${JOB_DEFINITION##*/}"
JOB_NAME="${JOB_NAME%%:*}-${PIPELINE_RUN_ID}"

log "Submitting Batch job..."
log "  Job definition: ${JOB_DEFINITION}"
log "  Job queue:      ${JOB_QUEUE}"
log "  Volume ID:      ${VOLUME_ID}"
log "  Pipeline run:   ${PIPELINE_RUN_ID}"

# Build environment overrides — include VOLUME_ID so the container
# (or its launch template user data) can attach the correct EBS volume
ENV_OVERRIDES=$(jq -n \
  --arg pipeline_run_id "$PIPELINE_RUN_ID" \
  --arg volume_id "$VOLUME_ID" \
  --arg s3_bucket "$S3_BUCKET" \
  --arg oi_release_tag "$OI_RELEASE_TAG" \
  '[
    {name: "PIPELINE_RUN_ID", value: $pipeline_run_id},
    {name: "EBS_VOLUME_ID", value: $volume_id}
  ]
  + (if $s3_bucket != "" then [{name: "S3_BUCKET", value: $s3_bucket}] else [] end)
  + (if $oi_release_tag != "" then [{name: "OI_RELEASE_TAG", value: $oi_release_tag}] else [] end)')

JOB_ID=$(aws batch submit-job \
  --job-name "$JOB_NAME" \
  --job-definition "$JOB_DEFINITION" \
  --job-queue "$JOB_QUEUE" \
  --container-overrides "{\"environment\": ${ENV_OVERRIDES}}" \
  --retry-strategy '{"attempts": 3}' \
  --region "$REGION" \
  --output text \
  --query 'jobId')

log "Submitted job ${JOB_ID}"
echo "$JOB_ID"
