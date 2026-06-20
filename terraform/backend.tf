/**
 * Backend configuration.
 *
 * We use an S3 + DynamoDB remote state backend so the team shares one source
 * of truth. The bucket + table must be pre-created (see scripts/bootstrap-state.sh)
 * before running `terraform init` with backend enabled.
 *
 * To bootstrap a fresh environment WITHOUT a remote backend first, comment out
 * the `backend "s3"` block, run `terraform init`, create the bucket, then
 * re-enable the block and `terraform init -upgrade` to migrate state.
 */

terraform {
  backend "s3" {
    bucket         = "obs-stack-tfstate"   # override with -backend-config
    key            = "observability-stack/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "obs-stack-tfstate-locks"
    encrypt        = true
  }
}
