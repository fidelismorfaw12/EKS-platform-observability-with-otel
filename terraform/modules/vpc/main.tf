/**
 * VPC module
 * ----------
 * Uses the well-maintained terraform-aws-modules/vpc/aws module under the hood.
 *
 * Topology:
 *   - 3 AZs (or 2 if region only has 2)
 *   - Public subnets  (ALB, NAT GW)
 *   - Private subnets (EKS worker nodes)
 *   - Intra subnets   (EKS control plane ENIs — no NAT egress bill)
 *
 * Flow logs are enabled and shipped to CloudWatch Logs in their own log group.
 */

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6.0"
    }
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  az_count = min(3, length(data.aws_availability_zones.available.names))
  azs      = slice(data.aws_availability_zones.available.names, 0, local.az_count)

  name_prefix = "${var.project_name}-${var.environment}"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.8.0"

  name = "${local.name_prefix}-vpc"
  cidr = var.vpc_cidr

  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 8, k + 48)]
  intra_subnets   = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 8, k + 52)]

  enable_dns_support   = true
  enable_dns_hostnames = true

  # Single NAT GW for dev to save cost. Set to false in prod to get one per AZ.
  single_nat_gateway = var.environment == "prod" ? false : true
  enable_nat_gateway = true
  create_igw         = true

  # Flow logs -> CloudWatch
  enable_flow_log                       = true
  create_flow_log_cloudwatch_log_group  = true
  create_flow_log_cloudwatch_iam_role   = true
  create_flow_log_cloudwatch_iam_policy = true

  # Tag subnets for the EKS ALB controller so k8s Services with
  # `LoadBalancerClass: service.k8s.aws/nlb` know which subnets to use.
  public_subnet_tags = {
    "kubernetes.io/role/elb"                                      = "1"
    "kubernetes.io/cluster/${var.project_name}-${var.environment}-cluster" = "shared"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"                             = "1"
    "kubernetes.io/cluster/${var.project_name}-${var.environment}-cluster" = "shared"
  }

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}
