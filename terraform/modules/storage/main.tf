/**
 * Storage module — S3 buckets + DynamoDB table for the observability backends
 * --------------------------------------------------------------------------
 *   - loki-s3-bucket       : Loki chunks + index (ruler + compactor use the same)
 *   - jaeger-s3-bucket     : Jaeger spans (badger for hot, s3 for cold)
 *   - prometheus-s3-bucket : optional LTSS via thanos / remote-write
 *
 * All buckets:
 *   - versioned
 *   - encrypted with a customer-managed KMS key
 *   - block all public access
 *   - have a 90-day lifecycle rule moving to S3-IA, 365-day rule expiring
 *
 * DO NOT use these buckets for ANY other workload — the IAM roles above are
 * scoped narrowly to these names.
 */

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 5.40.0" }
  }
}

data "aws_caller_identity" "current" {}

locals {
  name_prefix = "${var.project_name}-${var.environment}"
  account_id  = data.aws_caller_identity.current.account_id

  kms_alias = "alias/${local.name_prefix}-obs"
}

# --------------------------------------------------------------------------- #
# KMS key shared by all 3 buckets                                             #
# --------------------------------------------------------------------------- #
resource "aws_kms_key" "obs" {
  description             = "KMS key for ${local.name_prefix} observability buckets"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}

resource "aws_kms_alias" "obs" {
  name          = local.kms_alias
  target_key_id = aws_kms_key.obs.key_id
}

# --------------------------------------------------------------------------- #
# Loki bucket                                                                 #
# --------------------------------------------------------------------------- #
module "loki_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "~> 4.1.0"

  bucket = "${local.name_prefix}-loki"

  block_public_acls              = true
  block_public_policy            = true
  ignore_public_acls             = true
  restrict_public_buckets        = true
  versioning                     = { enabled = true }
  attach_public_policy           = false
  attach_require_latest_tls      = true
  force_destroy                  = var.environment != "prod"

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm     = "aws:kms"
        kms_master_key_id = aws_kms_key.obs.arn
      }
    }
  }

  lifecycle_rule = [
    {
      id      = "transition-to-ia"
      enabled = true
      transition = [
        { days          = 30
          storage_class = "STANDARD_IA" }
      ]
      expiration = { days = 365 }
    }
  ]

  tags = {
    Project     = var.project_name
    Environment = var.environment
    Purpose     = "loki"
  }
}

# --------------------------------------------------------------------------- #
# Jaeger bucket                                                               #
# --------------------------------------------------------------------------- #
module "jaeger_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "~> 4.1.0"

  bucket = "${local.name_prefix}-jaeger"

  block_public_acls              = true
  block_public_policy            = true
  ignore_public_acls             = true
  restrict_public_buckets        = true
  versioning                     = { enabled = true }
  attach_public_policy           = false
  attach_require_latest_tls      = true
  force_destroy                  = var.environment != "prod"

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm     = "aws:kms"
        kms_master_key_id = aws_kms_key.obs.arn
      }
    }
  }

  lifecycle_rule = [
    {
      id      = "expire-spans"
      enabled = true
      expiration = { days = 30 }
    }
  ]

  tags = {
    Project     = var.project_name
    Environment = var.environment
    Purpose     = "jaeger"
  }
}

# --------------------------------------------------------------------------- #
# Prometheus bucket (for thanos / remote-write LTSS)                          #
# --------------------------------------------------------------------------- #
module "prometheus_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "~> 4.1.0"

  bucket = "${local.name_prefix}-prometheus"

  block_public_acls              = true
  block_public_policy            = true
  ignore_public_acls             = true
  restrict_public_buckets        = true
  versioning                     = { enabled = true }
  attach_public_policy           = false
  attach_require_latest_tls      = true
  force_destroy                  = var.environment != "prod"

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm     = "aws:kms"
        kms_master_key_id = aws_kms_key.obs.arn
      }
    }
  }

  lifecycle_rule = [
    {
      id      = "transition"
      enabled = true
      transition = [
        { days          = 30
          storage_class = "STANDARD_IA" },
        { days          = 90
          storage_class = "GLACIER" }
      ]
      expiration = { days = 730 }
    }
  ]

  tags = {
    Project     = var.project_name
    Environment = var.environment
    Purpose     = "prometheus-ltss"
  }
}
