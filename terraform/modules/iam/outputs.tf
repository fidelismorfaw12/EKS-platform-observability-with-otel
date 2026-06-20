output "loki_role_arn" {
  value = aws_iam_role.loki.arn
}

output "jaeger_role_arn" {
  value = aws_iam_role.jaeger.arn
}

output "prometheus_role_arn" {
  value = aws_iam_role.prometheus.arn
}
