/**
 * IAM module — IRSA roles for the observability stack
 * ----------------------------------------------------
 * Creates one role per component so each can be scoped to exactly the S3
 * bucket / DynamoDB table it needs. ServiceAccount annotations in the Helm
 * values reference these ARNs.
 *
 * Components:
 *   - loki       -> read/write to loki S3 bucket
 *   - jaeger     -> read/write to jaeger S3 bucket
 *   - prometheus -> write to prometheus S3 bucket (LTSS / remote-write)
 */

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 5.40.0" }
  }
}

locals {
  name_prefix = "${var.project_name}-${var.environment}"
}

# --------------------------------------------------------------------------- #
# Helper: produce an assume-role policy for a single service account          #
# --------------------------------------------------------------------------- #
data "aws_iam_policy_document" "irsa_assume" {
  for_each = toset(["loki", "jaeger", "prometheus"])

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:observability:${each.value}"]
    }
  }
}

# --------------------------------------------------------------------------- #
# Loki                                                                        #
# --------------------------------------------------------------------------- #
resource "aws_iam_role" "loki" {
  name               = "${local.name_prefix}-loki"
  assume_role_policy = data.aws_iam_policy_document.irsa_assume["loki"].json
}

resource "aws_iam_policy" "loki" {
  name = "${local.name_prefix}-loki"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject",
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts",
        ]
        Resource = [
          "arn:aws:s3:::${var.loki_s3_bucket}",
          "arn:aws:s3:::${var.loki_s3_bucket}/*",
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "loki" {
  role       = aws_iam_role.loki.name
  policy_arn = aws_iam_policy.loki.arn
}

# --------------------------------------------------------------------------- #
# Jaeger                                                                      #
# --------------------------------------------------------------------------- #
resource "aws_iam_role" "jaeger" {
  name               = "${local.name_prefix}-jaeger"
  assume_role_policy = data.aws_iam_policy_document.irsa_assume["jaeger"].json
}

resource "aws_iam_policy" "jaeger" {
  name = "${local.name_prefix}-jaeger"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject",
        ]
        Resource = [
          "arn:aws:s3:::${var.jaeger_s3_bucket}",
          "arn:aws:s3:::${var.jaeger_s3_bucket}/*",
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "jaeger" {
  role       = aws_iam_role.jaeger.name
  policy_arn = aws_iam_policy.jaeger.arn
}

# --------------------------------------------------------------------------- #
# Prometheus (remote write / LTSS)                                            #
# --------------------------------------------------------------------------- #
resource "aws_iam_role" "prometheus" {
  name               = "${local.name_prefix}-prometheus"
  assume_role_policy = data.aws_iam_policy_document.irsa_assume["prometheus"].json
}

resource "aws_iam_policy" "prometheus" {
  name = "${local.name_prefix}-prometheus"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:PutObject",
          "s3:GetObject",
        ]
        Resource = [
          "arn:aws:s3:::${var.prometheus_s3_bucket}",
          "arn:aws:s3:::${var.prometheus_s3_bucket}/*",
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "prometheus" {
  role       = aws_iam_role.prometheus.name
  policy_arn = aws_iam_policy.prometheus.arn
}
