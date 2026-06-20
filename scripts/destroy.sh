#!/usr/bin/env bash
# Tear down everything created by deploy.sh in reverse order.
#
# Steps:
#   1. terraform destroy             -> all aws resources + helm releases
#   2. (optional) remove S3 buckets  -> set FORCE_DELETE_BUCKETS=1
#
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

AWS_REGION="${AWS_REGION:-us-east-1}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
FORCE_DELETE_BUCKETS="${FORCE_DELETE_BUCKETS:-0}"

export AWS_REGION
export TF_VAR_region="$AWS_REGION"
export TF_VAR_environment="$ENVIRONMENT"

log() { printf "\n\033[1;36m==>\033[0m %s\n" "$*"; }

log "Terraform destroy (this may take 15-30 minutes)"
cd "$ROOT/terraform"
terraform destroy -auto-approve

if [[ "$FORCE_DELETE_BUCKETS" == "1" ]]; then
  log "Force-deleting S3 buckets"
  for bucket in obs-stack-${ENVIRONMENT}-loki obs-stack-${ENVIRONMENT}-jaeger obs-stack-${ENVIRONMENT}-prometheus; do
    if aws s3api head-bucket --bucket "$bucket" --region "$AWS_REGION" 2>/dev/null; then
      aws s3 rm "s3://$bucket" --recursive --region "$AWS_REGION" || true
      aws s3api delete-bucket --bucket "$bucket" --region "$AWS_REGION" || true
    fi
  done
fi

log "Destroy complete."
