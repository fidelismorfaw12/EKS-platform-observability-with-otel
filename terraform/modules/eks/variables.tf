variable "project_name" { type = string }
variable "environment" { type = string }
variable "cluster_name" { type = string }
variable "cluster_version" { type = string }
variable "vpc_id" { type = string }
variable "subnet_ids" { type = list(string) }
variable "control_plane_subnet_ids" { type = list(string) }

variable "system_node_group" {
  type = object({
    instance_types = list(string)
    desired_size   = number
    min_size       = number
    max_size       = number
    disk_size      = number
  })
}

variable "workload_node_group" {
  type = object({
    instance_types = list(string)
    desired_size   = number
    min_size       = number
    max_size       = number
    disk_size      = number
  })
}

variable "observability_node_group" {
  type = object({
    instance_types = list(string)
    desired_size   = number
    min_size       = number
    max_size       = number
    disk_size      = number
  })
}

variable "enable_karpenter" {
  type    = bool
  default = false
}
