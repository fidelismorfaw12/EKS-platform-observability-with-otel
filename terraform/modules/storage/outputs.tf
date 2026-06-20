output "loki_s3_bucket" {
  value = module.loki_bucket.s3_bucket_id
}

output "jaeger_s3_bucket" {
  value = module.jaeger_bucket.s3_bucket_id
}

output "prometheus_s3_bucket" {
  value = module.prometheus_bucket.s3_bucket_id
}

output "kms_key_arn" {
  value = aws_kms_key.obs.arn
}
