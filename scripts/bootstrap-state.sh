#!/usr/bin/env bash
#
# Bootstrap the remote state backend (S3 bucket + DynamoDB lock table).
# Run this ONCE per AWS account. After it completes, the `terraform init`
# backend block in backend.tf will succeed.
#
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
BUCKET="${TF_STATE_BUCKET:-obs-stack-tfstate}"
TABLE="${TF_STATE_TABLE:-obs-stack-tfstate-locks}"

echo "==> Region: $REGION"
echo "==> State bucket: $BUCKET"
echo "==> Lock table: $TABLE"
echo

if ! aws s3api head-bucket --bucket "$BUCKET" --region "$REGION" 2>/dev/null; then
  echo "Creating S3 bucket $BUCKET..."
  if [[ "$REGION" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION"
  else
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION"
  fi

  aws s3api put-bucket-versioning --bucket "$BUCKET" --region "$REGION" \
    --versioning-configuration Status=Enabled

  aws s3api put-bucket-encryption --bucket "$BUCKET" --region "$REGION" \
    --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

  aws s3api put-public-access-block --bucket "$BUCKET" --region "$REGION" \
    --public-access-block-configuration \
    '{"BlockPublicAcls":true,"IgnorePublicAcls":true,"BlockPublicPolicy":true,"RestrictPublicBuckets":true}'
else
  echo "S3 bucket already exists."
fi

if ! aws dynamodb describe-table --table-name "$TABLE" --region "$REGION" 2>/dev/null; then
  echo "Creating DynamoDB table $TABLE..."
  aws dynamodb create-table \
    --table-name "$TABLE" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "$REGION"
else
  echo "DynamoDB table already exists."
fi

echo
echo "Done. Update backend.tf with your bucket name if you changed it."
