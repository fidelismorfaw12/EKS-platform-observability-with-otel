/**
 * Root input variables.
 * Override these in terraform.tfvars or with -var flags.
 */

variable "region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Deployment environment (dev | staging | prod)"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "project_name" {
  description = "Short project name used as prefix for resources"
  type        = string
  default     = "obs-stack"
}

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
  default     = "obs-stack-cluster"
}

variable "cluster_version" {
  description = "EKS Kubernetes version"
  type        = string
  default     = "1.30"
}

variable "vpc_cidr" {
  description = "CIDR for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

# --------------------------------------------------------------------------- #
# Node groups                                                                 #
# --------------------------------------------------------------------------- #

variable "system_node_group" {
  description = "System node group (runs kube-system, observability stack)"
  type = object({
    instance_types = list(string)
    desired_size   = number
    min_size       = number
    max_size       = number
    disk_size      = number
  })
  default = {
    instance_types = ["t3.large"]
    desired_size   = 2
    min_size       = 2
    max_size       = 4
    disk_size      = 100
  }
}

variable "workload_node_group" {
  description = "Workload node group (runs user apps)"
  type = object({
    instance_types = list(string)
    desired_size   = number
    min_size       = number
    max_size       = number
    disk_size      = number
  })
  default = {
    instance_types = ["t3.medium"]
    desired_size   = 3
    min_size       = 3
    max_size       = 6
    disk_size      = 50
  }
}

variable "observability_node_group" {
  description = "Dedicated node group for the observability stack (Prometheus, Loki, Jaeger, OTel)"
  type = object({
    instance_types = list(string)
    desired_size   = number
    min_size       = number
    max_size       = number
    disk_size      = number
  })
  default = {
    instance_types = ["r6i.xlarge"]
    desired_size   = 2
    min_size       = 1
    max_size       = 4
    disk_size      = 200
  }
}

# --------------------------------------------------------------------------- #
# Helm chart versions (kept here so upgrades are obvious)                     #
# --------------------------------------------------------------------------- #

variable "kube_prometheus_stack_version" {
  type    = string
  default = "61.2.0"
}

variable "loki_chart_version" {
  type    = string
  default = "6.7.4"
}

variable "promtail_chart_version" {
  type    = string
  default = "6.16.0"
}

variable "jaeger_chart_version" {
  type    = string
  default = "3.1.2"
}

variable "otel_collector_chart_version" {
  type    = string
  default = "0.95.0"
}

variable "grafana_admin_password" {
  description = "Initial Grafana admin password. Change this in prod or rely on AWS Secrets Manager injection."
  type        = string
  default     = "admin-change-me"
  sensitive   = true
}

variable "enable_karpenter" {
  description = "Install Karpenter for node autoscaling"
  type        = bool
  default     = true
}
