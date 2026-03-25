#!/usr/bin/env bash
#
# Deploy the pike-reachability CloudFormation stack.
# One-time setup script. Prints created resource ARNs on completion.
#
# Usage: setup-aws.sh --email <alarm-email> --vpc <vpc-id> --subnets <subnet-id-1>,<subnet-id-2>
#        setup-aws.sh --email <alarm-email>   (auto-detects default VPC and subnets)
#
set -euo pipefail

STACK_NAME="pike-reachability"
REGION="${AWS_REGION:-us-east-1}"
TEMPLATE_FILE="$(cd "$(dirname "$0")/.." && pwd)/infra/cloudformation.yml"
CREATE_OIDC="true"

log() { echo "[$(date -u +%FT%TZ)] $*"; }

usage() {
  echo "Usage: $0 --email <alarm-email> [--vpc <vpc-id>] [--subnets <subnet-ids>] [--no-oidc]"
  echo ""
  echo "Options:"
  echo "  --email     Email for billing alarm notifications (required)"
  echo "  --vpc       VPC ID (auto-detected from default VPC if omitted)"
  echo "  --subnets   Comma-separated subnet IDs (auto-detected if omitted)"
  echo "  --no-oidc   Skip OIDC provider creation (if one already exists)"
  exit 1
}

# Parse arguments
EMAIL=""
VPC_ID=""
SUBNETS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --email)   EMAIL="$2"; shift 2 ;;
    --vpc)     VPC_ID="$2"; shift 2 ;;
    --subnets) SUBNETS="$2"; shift 2 ;;
    --no-oidc) CREATE_OIDC="false"; shift ;;
    *)         usage ;;
  esac
done

if [[ -z "$EMAIL" ]]; then
  echo "ERROR: --email is required" >&2
  usage
fi

if [[ ! -f "$TEMPLATE_FILE" ]]; then
  echo "ERROR: CloudFormation template not found at ${TEMPLATE_FILE}" >&2
  exit 1
fi

# ─── Auto-detect VPC and subnets ─────────────────────────────────
if [[ -z "$VPC_ID" ]]; then
  log "Auto-detecting default VPC..."
  VPC_ID=$(aws ec2 describe-vpcs \
    --filters "Name=is-default,Values=true" \
    --region "$REGION" \
    --output text \
    --query 'Vpcs[0].VpcId')

  if [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
    echo "ERROR: No default VPC found. Specify --vpc explicitly." >&2
    exit 1
  fi
  log "Using default VPC: ${VPC_ID}"
fi

if [[ -z "$SUBNETS" ]]; then
  log "Auto-detecting subnets for VPC ${VPC_ID}..."
  SUBNETS=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --region "$REGION" \
    --output text \
    --query 'Subnets[*].SubnetId' | tr '\t' ',')

  if [[ -z "$SUBNETS" ]]; then
    echo "ERROR: No subnets found for VPC ${VPC_ID}." >&2
    exit 1
  fi
  log "Using subnets: ${SUBNETS}"
fi

# ─── Deploy CloudFormation stack ──────────────────────────────────
log "Deploying CloudFormation stack '${STACK_NAME}'..."

aws cloudformation deploy \
  --stack-name "$STACK_NAME" \
  --template-file "$TEMPLATE_FILE" \
  --parameter-overrides \
    "AlarmEmail=${EMAIL}" \
    "VpcId=${VPC_ID}" \
    "Subnets=${SUBNETS}" \
    "CreateOIDCProvider=${CREATE_OIDC}" \
  --capabilities CAPABILITY_NAMED_IAM \
  --region "$REGION" \
  --tags project=pike-reachability

log "Stack deployment complete"

# ─── Print outputs ───────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════"
echo " Stack Outputs"
echo "═══════════════════════════════════════════════════════"

aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --query 'Stacks[0].Outputs[*].[OutputKey,OutputValue]' \
  --output table

echo ""
echo "═══════════════════════════════════════════════════════"
echo " Next Steps"
echo "═══════════════════════════════════════════════════════"
echo "1. Copy the GHAOIDCRoleArn value"
echo "2. Add it as a secret named AWS_ROLE_ARN in the GitHub repo:"
echo "   gh secret set AWS_ROLE_ARN --repo tldev/pike-reachability"
echo "3. Confirm the SNS subscription email"
echo "4. Push to main to trigger the docker-build workflow"
echo ""
