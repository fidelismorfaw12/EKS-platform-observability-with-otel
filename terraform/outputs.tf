output "vpc_id" {
  description = "ID of the created VPC"
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnet IDs (where EKS nodes live)"
  value       = module.vpc.private_subnet_ids
}

output "public_subnet_ids" {
  description = "Public subnet IDs (where ALBs / NAT GW live)"
  value       = module.vpc.public_subnet_ids
}

output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint"
  value       = module.eks.cluster_endpoint
}

output "cluster_ca_certificate" {
  description = "Base64-encoded cluster CA"
  value       = module.eks.cluster_certificate_authority_data
  sensitive   = true
}

output "configure_kubectl" {
  description = "Run this command to point kubectl at the new cluster"
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

output "loki_s3_bucket" {
  value = module.storage.loki_s3_bucket
}

output "jaeger_s3_bucket" {
  value = module.storage.jaeger_s3_bucket
}

output "prometheus_s3_bucket" {
  value = module.storage.prometheus_s3_bucket
}

output "loki_irsa_role" {
  value = module.iam.loki_role_arn
}

output "jaeger_irsa_role" {
  value = module.iam.jaeger_role_arn
}

output "grafana_admin_password" {
  description = "Initial Grafana admin password (change immediately in prod)"
  value       = var.grafana_admin_password
  sensitive   = true
}

output "grafana_port_forward_cmd" {
  description = "Open a tunnel to Grafana"
  value       = "kubectl -n observability port-forward svc/observability-stack-grafana 8080:80"
}
