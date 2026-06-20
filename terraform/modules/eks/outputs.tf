output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  value = module.eks.cluster_certificate_authority_data
}

output "cluster_arn" {
  value = module.eks.cluster_arn
}

output "oidc_provider_arn" {
  value = module.eks.oidc_provider_arn
}

output "oidc_provider_url" {
  value = module.eks.oidc_provider_url
}

output "ebs_csi_driver_role_arn" {
  value = aws_iam_role.ebs_csi.arn
}

output "karpenter_role_arn" {
  value = var.enable_karpenter ? aws_iam_role.karpenter[0].arn : null
}

output "node_group_arns" {
  value = module.eks.eks_managed_node_groups
}
