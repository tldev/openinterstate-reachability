#!/usr/bin/env bash
#
# Submit an AWS Batch job with EBS volume attachment override.
# Usage: submit-batch-job.sh <job-definition> <job-queue> <volume-id> <pipeline-run-id>
# Outputs the job ID to stdout.
#
set -euo pipefail

JOB_DEFINITION="${1:?Usage: submit-batch-job.sh <job-definition> <job-queue> <volume-id> <pipeline-run-id>}"
JOB_QUEUE="${2:?Usage: submit-batch-job.sh <job-definition> <job-queue> <volume-id> <pipeline-run-id>}"
VOLUME_ID="${3:?Usage: submit-batch-job.sh <job-definition> <job-queue> <volume-id> <pipeline-run-id>}"
PIPELINE_RUN_ID="${4:?Usage: submit-batch-job.sh <job-definition> <job-queue> <volume-id> <pipeline-run-id>}"
REGION="${AWS_REGION:-us-east-1}"
S3_BUCKET="${S3_BUCKET:-}"

# Extract short name from job definition for the job name
JOB_NAME="${JOB_DEFINITION##*/}"
JOB_NAME="${JOB_NAME%%:*}-${PIPELINE_RUN_ID}"

echo "[$(date -u +%FT%TZ)] Submitting Batch job..."
echo "  Job definition: ${JOB_DEFINITION}"
echo "  Job queue:      ${JOB_QUEUE}"
echo "  Volume ID:      ${VOLUME_ID}"
echo "  Pipeline run:   ${PIPELINE_RUN_ID}"

# Build environment overrides
ENV_OVERRIDES='[{"name":"PIPELINE_RUN_ID","value":"'"${PIPELINE_RUN_ID}"'"}'
if [[ -n "$S3_BUCKET" ]]; then
  ENV_OVERRIDES="${ENV_OVERRIDES}"',{"name":"S3_BUCKET","value":"'"${S3_BUCKET}"'"}'
fi
ENV_OVERRIDES="${ENV_OVERRIDES}]"

JOB_ID=$(aws batch submit-job \
  --job-name "$JOB_NAME" \
  --job-definition "$JOB_DEFINITION" \
  --job-queue "$JOB_QUEUE" \
  --container-overrides "{
    \"environment\": ${ENV_OVERRIDES}
  }" \
  --region "$REGION" \
  --output text \
  --query 'jobId')

echo "[$(date -u +%FT%TZ)] Submitted job ${JOB_ID}"
echo "$JOB_ID"
