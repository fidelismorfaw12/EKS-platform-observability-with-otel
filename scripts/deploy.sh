#!/usr/bin/env bash
# Full end-to-end deploy of the observability stack.
#
# Phases:
#   1. Bootstrap remote state (if needed)
#   2. terraform init / plan / apply   -> VPC, EKS, IAM, storage, helm releases
#   3. aws eks update-kubeconfig       -> local kubectl access
#   4. Wait for CRDs to establish
#   5. Build + push demo app images (optional)
#   6. Print access info (Grafana port-forward command, etc.)
#
set -euo pipefail
set -o pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

# ----------------------------- config ------------------------------------- #
AWS_REGION="${AWS_REGION:-us-east-1}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
CLUSTER_NAME="${CLUSTER_NAME:-obs-stack-dev}"
SKIP_BOOTSTRAP="${SKIP_BOOTSTRAP:-0}"
SKIP_TERRAFORM="${SKIP_TERRAFORM:-0}"
SKIP_APPS="${SKIP_APPS:-1}"     # default: don't build images
TF_STATE_BUCKET="${TF_STATE_BUCKET:-obs-stack-tfstate}"
TF_STATE_TABLE="${TF_STATE_TABLE:-obs-stack-tfstate-locks}"

export AWS_REGION
export TF_VAR_region="$AWS_REGION"
export TF_VAR_environment="$ENVIRONMENT"

log() { printf "\n\033[1;36m==>\033[0m %s\n" "$*"; }
err() { printf "\033[1;31mERROR:\033[0m %s\n" "$*" >&2; exit 1; }

# ----------------------------- preflight ---------------------------------- #
command -v aws >/dev/null || err "aws CLI not found"
command -v terraform >/dev/null || err "terraform not found"
command -v kubectl >/dev/null || err "kubectl not found"
command -v helm >/dev/null || err "helm not found"

aws sts get-caller-identity >/dev/null || err "AWS auth failed — run 'aws configure'"

# ----------------------------- 1. bootstrap ------------------------------- #
if [[ "$SKIP_BOOTSTRAP" != "1" ]]; then
  log "Bootstrapping remote state backend (S3 bucket + DynamoDB table)"
  TF_STATE_BUCKET="$TF_STATE_BUCKET" TF_STATE_TABLE="$TF_STATE_TABLE" \
    bash "$ROOT/scripts/bootstrap-state.sh" || true
fi

# ----------------------------- 2. terraform ------------------------------- #
if [[ "$SKIP_TERRAFORM" != "1" ]]; then
  log "Terraform init"
  ( cd "$ROOT/terraform" && terraform init -upgrade )

  log "Terraform plan"
  ( cd "$ROOT/terraform" && terraform plan -out=tfplan )

  log "Terraform apply"
  ( cd "$ROOT/terraform" && terraform apply -auto-approve tfplan )
fi

# ----------------------------- 3. kubeconfig ------------------------------ #
log "Updating local kubeconfig"
aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME" --alias "$CLUSTER_NAME" >/dev/null

# ----------------------------- 4. wait for CRDs --------------------------- #
log "Waiting for Prometheus CRDs to be established"
for crd in prometheuses.monitoring.coreos.com alertmanagers.monitoring.coreos.com servicemonitors.monitoring.coreos.com podmonitors.monitoring.coreos.com prometheusrules.monitoring.coreos.com; do
  kubectl wait --for=condition=established --timeout=60s crd/"crd" 2>/dev/null || true
done

log "Waiting for OpenTelemetry CRD"
kubectl wait --for=condition=established --timeout=120s crd/opentelemetrycollectors.opentelemetry.io 2>/dev/null || true

# ----------------------------- 5. apps ------------------------------------ #
if [[ "$SKIP_APPS" == "1" ]]; then
  log "Skipping demo app image build (set SKIP_APPS=0 to build & push)"
else
  log "Building + pushing demo app images (requires local registry or ECR)"
  for svc in frontend backend cart checkout; do
    ( cd "$ROOT/apps/$svc" && docker build -t "obs-demo/$svc:latest" . )
  done
  echo "Now load the images into your cluster (kind/minikube) or push to ECR."
  echo "Then run: kubectl -n demo-apps rollout restart deployment"
fi

# ----------------------------- 6. access info ----------------------------- #
log "Deploy done."
echo
echo "What to do next:"
echo "  1. Open Grafana:   kubectl -n observability port-forward svc/observability-stack-grafana 8080:80"
echo "     User: admin  Password: see 'terraform output grafana_admin_password'"
echo "  2. Open Jaeger:    kubectl -n observability port-forward svc/observability-stack-jaeger-query 16686:16686"
echo "  3. Send test load: kubectl -n demo-apps run loadgen --rm -it --image=curlimages/curl:8.7.1 --restart=Never -- /bin/sh -c 'while true; do curl -s http://frontend/api/items; curl -s http://frontend/slow; curl -s http://frontend/error; sleep 0.5; done'"
echo
