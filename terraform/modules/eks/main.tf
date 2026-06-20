/**
 * EKS module
 * ----------
 * Creates:
 *   - EKS control plane (managed)
 *   - 3 managed node groups: system, workload, observability
 *   - IAM roles for: cluster itself, each node group, IRSA for add-ons
 *   - Cluster add-ons: vpc-cni, kube-proxy, coredns, aws-ebs-csi-driver
 *   - Karpenter (optional) — installed via helm_release
 *
 * Taints & labels per node group:
 *   - system         taint=None           label=workload=system
 *   - workload       taint=None           label=workload=general
 *   - observability  taint=observability  label=workload=observability
 *
 *   The observability taint keeps user pods off the dedicated nodes so that
 *   a sudden app burst can't starve Prometheus/Loki of memory.
 */

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws     = { source = "hashicorp/aws", version = ">= 5.40.0" }
    helm    = { source = "hashicorp/helm", version = ">= 2.13.0" }
    kubectl = { source = "gavinbunney/kubectl", version = ">= 1.14.0" }
  }
}

data "aws_caller_identity" "current" {}

locals {
  name_prefix = "${var.project_name}-${var.environment}"

  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# --------------------------------------------------------------------------- #
# Cluster                                                                     #
# --------------------------------------------------------------------------- #
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.17.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  cluster_endpoint_public_access       = true
  cluster_endpoint_public_access_cidrs = ["0.0.0.0/0"]
  cluster_endpoint_private_access      = true

  vpc_id     = var.vpc_id
  subnet_ids = var.subnet_ids

  control_plane_subnet_ids = var.control_plane_subnet_ids

  enable_cluster_creator_admin_permissions = true

  cluster_encryption_config = {
    provider_key_arn = aws_kms_key.eks.arn
    resources        = ["secrets"]
  }

  cluster_enabled_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  cluster_tags = local.common_tags

  # ----------------------------------------------------------------------- #
  # Node groups                                                              #
  # ----------------------------------------------------------------------- #
  eks_managed_node_groups = {
    system = {
      name           = "${local.name_prefix}-system"
      instance_types = var.system_node_group.instance_types
      min_size       = var.system_node_group.min_size
      max_size       = var.system_node_group.max_size
      desired_size   = var.system_node_group.desired_size
      disk_size      = var.system_node_group.disk_size

      labels = {
        workload = "system"
      }

      iam_role_additional_policies = {
        ebs = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
      }
    }

    workload = {
      name           = "${local.name_prefix}-workload"
      instance_types = var.workload_node_group.instance_types
      min_size       = var.workload_node_group.min_size
      max_size       = var.workload_node_group.max_size
      desired_size   = var.workload_node_group.desired_size
      disk_size      = var.workload_node_group.disk_size

      labels = {
        workload = "general"
      }
    }

    observability = {
      name           = "${local.name_prefix}-obs"
      instance_types = var.observability_node_group.instance_types
      min_size       = var.observability_node_group.min_size
      max_size       = var.observability_node_group.max_size
      desired_size   = var.observability_node_group.desired_size
      disk_size      = var.observability_node_group.disk_size

      labels = {
        workload = "observability"
      }

      taints = [{
        key    = "observability"
        value  = "true"
        effect = "NO_SCHEDULE"
      }]
    }
  }

  tags = local.common_tags
}

# KMS key for EKS secrets encryption
resource "aws_kms_key" "eks" {
  description             = "${var.cluster_name} EKS secrets encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = local.common_tags
}

# --------------------------------------------------------------------------- #
# Cluster add-ons (managed)                                                   #
# --------------------------------------------------------------------------- #
module "eks_addons" {
  source  = "terraform-aws-modules/eks/aws//modules/aws-eks-managed-addon"
  version = "~> 20.17.0"

  for_each = toset([
    "vpc-cni",
    "kube-proxy",
    "coredns",
    "aws-ebs-csi-driver",
  ])

  cluster_name = module.eks.cluster_name
  addon_name   = each.value

  depends_on = [module.eks]
}

# IRSA for the EBS CSI driver
resource "aws_iam_role" "ebs_csi" {
  name = "${local.name_prefix}-ebs-csi"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = module.eks.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${module.eks.oidc_provider_url}:sub" = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
        }
      }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# --------------------------------------------------------------------------- #
# Karpenter (optional)                                                        #
# --------------------------------------------------------------------------- #
resource "aws_iam_role" "karpenter" {
  count = var.enable_karpenter ? 1 : 0
  name  = "${local.name_prefix}-karpenter"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = module.eks.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${module.eks.oidc_provider_url}:sub" = "system:serviceaccount:karpenter:karpenter"
        }
      }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "karpenter" {
  count = var.enable_karpenter ? 1 : 0
  name  = "karpenter"
  role  = aws_iam_role.karpenter[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:CreateLaunchTemplate",
          "ec2:CreateFleet",
          "ec2:CreateTags",
          "ec2:DescribeLaunchTemplates",
          "ec2:DescribeImages",
          "ec2:DescribeInstances",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSubnets",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeInstanceTypeOfferings",
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeSpotPriceHistory",
          "ec2:RunInstances",
          "ec2:TerminateInstances",
          "ec2:DeleteLaunchTemplate",
          "ssm:GetParameter",
          "pricing:GetProducts",
          "iam:PassRole",
        ]
        Resource = "*"
      }
    ]
  })
}

resource "helm_release" "karpenter" {
  count = var.enable_karpenter ? 1 : 0

  name       = "karpenter"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  namespace  = "karpenter"
  create_namespace = true
  version    = "0.37.0"

  set {
    name  = "settings.clusterName"
    value = module.eks.cluster_name
  }

  set {
    name  = "settings.interruptionQueue"
    value = "${local.name_prefix}-karpenter"
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.karpenter[0].arn
  }

  depends_on = [module.eks]
}

# Karpenter NodePool + EC2NodeClass
resource "kubectl_manifest" "karpenter_node_pool" {
  count = var.enable_karpenter ? 1 : 0

  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: default
    spec:
      template:
        metadata:
          labels:
            workload: general
        spec:
          requirements:
            - key: kubernetes.io/arch
              operator: In
              values: ["amd64"]
            - key: karpenter.sh/capacity-type
              operator: In
              values: ["on-demand", "spot"]
            - key: node.kubernetes.io/instance-type
              operator: In
              values: ["t3.medium", "t3.large", "t3.xlarge", "m5.large", "m5.xlarge"]
          nodeClassRef:
            group: karpenter.k8s.aws
            kind: EC2NodeClass
            name: default
          taints: []
      limits:
        cpu: 1000
        memory: 1000Gi
      disruption:
        consolidationPolicy: WhenEmptyOrUnderutilized
        consolidationWindow: 1m
  YAML

  depends_on = [helm_release.karpenter]
}

resource "kubectl_manifest" "karpenter_ec2_node_class" {
  count = var.enable_karpenter ? 1 : 0

  yaml_body = <<-YAML
    apiVersion: karpenter.k8s.aws/v1
    kind: EC2NodeClass
    metadata:
      name: default
    spec:
      amiFamily: AL2023
      subnetSelectorTerms:
        - tags:
            kubernetes.io/cluster/${module.eks.cluster_name}: owned
      securityGroupSelectorTerms:
        - tags:
            kubernetes.io/cluster/${module.eks.cluster_name}: owned
      role: "${module.eks.cluster_name}-workload"
      blockDeviceMappings:
        - deviceName: /dev/xvda
          ebs:
            volumeSize: 50Gi
            volumeType: gp3
            encrypted: true
  YAML

  depends_on = [helm_release.karpenter]
}

# SQS queue for Karpenter interruption handling
resource "aws_sqs_queue" "karpenter" {
  count                      = var.enable_karpenter ? 1 : 0
  name                       = "${local.name_prefix}-karpenter"
  message_retention_seconds = 300

  tags = local.common_tags
}
