/**
 * Root composition.
 * Wires VPC -> EKS -> IAM (IRSA) -> Storage (S3 + DynamoDB for Loki/Jaeger)
 *     -> Helm releases (Prometheus, Loki, Promtail, Jaeger, OTel Collector)
 *
 * The Helm releases and Kubernetes resources are gated behind a `depends_on`
 * against the EKS cluster so that `terraform apply` from scratch works in one
 * shot.
 */

# --------------------------------------------------------------------------- #
# Networking                                                                  #
# --------------------------------------------------------------------------- #
module "vpc" {
  source = "./modules/vpc"

  project_name = var.project_name
  environment  = var.environment
  region       = var.region
  vpc_cidr     = var.vpc_cidr
}

# --------------------------------------------------------------------------- #
# EKS cluster + managed node groups                                           #
# --------------------------------------------------------------------------- #
module "eks" {
  source = "./modules/eks"

  project_name             = var.project_name
  environment              = var.environment
  cluster_name             = var.cluster_name
  cluster_version          = var.cluster_version
  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnet_ids
  control_plane_subnet_ids = module.vpc.intra_subnet_ids

  system_node_group          = var.system_node_group
  workload_node_group        = var.workload_node_group
  observability_node_group   = var.observability_node_group
  enable_karpenter           = var.enable_karpenter
}

# --------------------------------------------------------------------------- #
# IAM roles for service accounts (IRSA) — each observability component gets   #
# its own role scoped to the S3 bucket / DynamoDB table it needs.             #
# --------------------------------------------------------------------------- #
module "iam" {
  source = "./modules/iam"

  project_name        = var.project_name
  environment         = var.environment
  oidc_provider_arn   = module.eks.oidc_provider_arn
  oidc_provider_url   = module.eks.oidc_provider_url
  loki_s3_bucket      = module.storage.loki_s3_bucket
  jaeger_s3_bucket    = module.storage.jaeger_s3_bucket
  prometheus_s3_bucket = module.storage.prometheus_s3_bucket
}

# --------------------------------------------------------------------------- #
# S3 buckets + DynamoDB tables for Loki, Jaeger, Prometheus LTSS             #
# --------------------------------------------------------------------------- #
module "storage" {
  source = "./modules/storage"

  project_name = var.project_name
  environment  = var.environment
  region       = var.region
}

# --------------------------------------------------------------------------- #
# Helm releases                                                               #
# Installed via the umbrella chart under ../helm. We pass cluster-specific    #
# values (IRSA role ARNs, bucket names, endpoint) at deploy time.             #
# --------------------------------------------------------------------------- #
resource "helm_release" "observability_umbrella" {
  name       = "observability-stack"
  repository = "../../helm"
  chart      = "../../helm"
  namespace  = "observability"
  create_namespace = true
  timeout    = 900
  wait       = false # wait=false: don't block on all pods being Ready; some CRDs need a reconcile cycle

  values = [
    yamlencode({
      global = {
        clusterName  = var.cluster_name
        environment  = var.environment
        region       = var.region
        awsAccountId = data.aws_caller_identity.current.account_id
      }

      kubePrometheusStack = {
        enabled      = true
        chartVersion = var.kube_prometheus_stack_version
        grafana = {
          adminPassword = var.grafana_admin_password
        }
      }

      loki = {
        enabled      = true
        chartVersion = var.loki_chart_version
        s3 = {
          bucket     = module.storage.loki_s3_bucket
          roleArn    = module.iam.loki_role_arn
          endpoint   = "https://s3.${var.region}.amazonaws.com"
          region     = var.region
        }
      }

      promtail = {
        enabled      = true
        chartVersion = var.promtail_chart_version
      }

      jaeger = {
        enabled      = true
        chartVersion = var.jaeger_chart_version
        s3 = {
          bucket  = module.storage.jaeger_s3_bucket
          roleArn = module.iam.jaeger_role_arn
          region  = var.region
        }
      }

      otelCollector = {
        enabled      = true
        chartVersion = var.otel_collector_chart_version
        clusterName  = var.cluster_name
      }
    })
  ]

  depends_on = [
    module.eks,
    module.iam,
    module.storage,
  ]
}

# --------------------------------------------------------------------------- #
# Sample observability demo apps (frontend + 3 backends)                       #
# --------------------------------------------------------------------------- #
resource "kubectl_manifest" "demo_apps" {
  for_each = fileset("${path.module}/../apps", "**/*.yaml")

  yaml_body = templatefile("${path.module}/../apps/${each.value}", {
    cluster_name = var.cluster_name
    region       = var.region
  })

  depends_on = [helm_release.observability_umbrella]
}

# --------------------------------------------------------------------------- #
# Grafana dashboards + Prometheus alert rules (loaded via ConfigMaps)         #
# --------------------------------------------------------------------------- #
resource "kubectl_manifest" "dashboards" {
  for_each = fileset("${path.module}/../dashboards", "*.yaml")
  yaml_body = file("${path.module}/../dashboards/${each.value}")

  depends_on = [helm_release.observability_umbrella]
}

resource "kubectl_manifest" "alert_rules" {
  for_each = fileset("${path.module}/../alerts", "*.yaml")
  yaml_body = file("${path.module}/../alerts/${each.value}")

  depends_on = [helm_release.observability_umbrella]
}
