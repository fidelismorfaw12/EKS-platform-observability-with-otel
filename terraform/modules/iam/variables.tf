variable "project_name" { type = string }
variable "environment" { type = string }

variable "oidc_provider_arn" { type = string }
variable "oidc_provider_url" { type = string }

variable "loki_s3_bucket" { type = string }
variable "jaeger_s3_bucket" { type = string }
variable "prometheus_s3_bucket" { type = string }
