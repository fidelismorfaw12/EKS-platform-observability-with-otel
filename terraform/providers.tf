/**
 * Provider wiring.
 *
 * AWS provider is configured first (no deps).
 *
 * The kubernetes / helm / kubectl providers are NOT instantiated at the root
 * scope with hardcoded credentials — instead they read from the EKS cluster
 * outputs via the `kubernetes` and `helm` provider `host / token / ca_certificate`
 * fields. That allows `terraform apply` from a clean laptop with only the AWS
 * CLI credentials available.
 */

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "observability-stack"
      Environment = var.environment
      ManagedBy   = "terraform"
      Repo        = "observability-stack"
    }
  }
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.this.token
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}

provider "kubectl" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.this.token
  load_config_file       = false
}

data "aws_eks_cluster_auth" "this" {
  name = module.eks.cluster_name
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
