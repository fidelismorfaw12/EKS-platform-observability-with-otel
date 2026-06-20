# Architecture — deeper reference

> This doc complements the README's high-level diagram with implementation
> details a new contributor needs to know.

## 1. Network topology

```
                       AWS Region (e.g. us-east-1)
                                │
                                ▼
                              VPC
                       (10.0.0.0/16)
                                │
        ┌───────────────────────┼───────────────────────┐
        │                       │                       │
       AZ-a                   AZ-b                   AZ-c
        │                       │                       │
   ┌────┴────┐             ┌────┴────┐             ┌────┴────┐
   │ public  │             │ public  │             │ public  │  <- ALB, NAT GW
   │ private │             │ private │             │ private │  <- EKS nodes
   │ intra   │             │ intra   │             │ intra   │  <- EKS control plane ENIs
   └─────────┘             └─────────┘             └─────────┘
```

- **public subnets**: ALBs and NAT Gateways live here. Tagged
  `kubernetes.io/role/elb=1` so the AWS LoadBalancer Controller knows where
  to put internet-facing LBs.
- **private subnets**: EKS worker nodes. No direct internet egress except via
  NAT GW. Tagged `kubernetes.io/role/internal-elb=1` for internal LBs.
- **intra subnets**: EKS control plane ENIs only. No route to IGW — saves
  NAT GW data processing cost.

## 2. EKS node group topology

| Group            | Instance types      | Default size | Taints                  | Purpose                          |
|------------------|---------------------|--------------|-------------------------|----------------------------------|
| system           | t3.large            | 2            | (none)                  | kube-system, karpenter, ALB ctrl |
| workload         | t3.medium           | 3            | (none)                  | user apps                        |
| observability    | r6i.xlarge          | 2            | observability=true:NOSCHEDULE | Prometheus, Loki, Jaeger, OTel   |
| karpenter pool   | t3/m5 spot          | dynamic      | (none)                  | burst capacity                   |

The observability taint keeps user pods off the dedicated nodes so a sudden
app burst can't starve Prometheus of memory.

## 3. Data flow

```
                       ┌─────────────────────────────────────────────────┐
                       │              demo-apps namespace                 │
                       │                                                 │
                       │   ┌──────────┐                                  │
                       │   │ frontend │ ─── HTTP ──►  ┌──────────┐        │
                       │   └──────────┘                │ checkout │        │
                       │         │                     └────┬─────┘        │
                       │         │ OTLP                     │              │
                       │         ▼                          │              │
                       │   ┌──────────┐    OTLP    ┌────────▼──┐          │
                       │   │ backend  │ ◄────────  │   cart    │          │
                       │   └──────────┘            └───────────┘          │
                       └────────────┬────────────────────────────────────┘
                                    │ OTLP/gRPC+HTTP (:4317, :4318)
                                    ▼
                       ┌─────────────────────────────────────────────────┐
                       │           observability namespace               │
                       │                                                 │
                       │           ┌──────────────────────┐              │
                       │           │  OTel Collector      │              │
                       │           │  (gateway deployment)│              │
                       │           └────┬─────┬──────┬────┘              │
                       │                │     │      │                   │
                       │       traces──►│     │      │◄── metrics        │
                       │                │     │      │                   │
                       │                ▼     │      ▼                   │
                       │      ┌─────────────┐ │ ┌───────────────────┐    │
                       │      │   Jaeger    │ │ │  Prometheus        │    │
                       │      │  (all-in-1) │ │ │  (remote-write)    │    │
                       │      └──────┬──────┘ │ └─────────┬─────────┘    │
                       │             │        │           │              │
                       │             │  logs──►           │              │
                       │             │        ▼           │              │
                       │             │  ┌──────────┐      │              │
                       │             │  │   Loki   │      │              │
                       │             │  └────┬─────┘      │              │
                       │             │       │            │              │
                       │             ▼       ▼            ▼              │
                       │      ┌────────────────────────────────────┐     │
                       │      │              Grafana                │     │
                       │      │  (Prometheus + Loki + Jaeger datasrcs) │  │
                       │      └────────────────────────────────────┘     │
                       └─────────────────────────────────────────────────┘
                                            │
                                            ▼
                       ┌─────────────────────────────────────────────────┐
                       │           Promtail DaemonSet                    │
                       │  (one pod per node, tails /var/log)             │
                       └─────────────────────────────────────────────────┘
```

## 4. IAM / IRSA mapping

| Service account                   | Namespace      | AWS IAM role              | Permissions                          |
|-----------------------------------|----------------|---------------------------|--------------------------------------|
| `prometheus`                      | observability  | `<env>-prometheus`        | s3:Get/Put on `<env>-prometheus`     |
| `loki`                            | observability  | `<env>-loki`              | s3:Get/Put/List on `<env>-loki`      |
| `jaeger`                          | observability  | `<env>-jaeger`            | s3:Get/Put/List on `<env>-jaeger`    |
| `ebs-csi-controller-sa`           | kube-system    | `<env>-ebs-csi`           | ec2:AttachVolume, ec2:CreateVolume…  |
| `karpenter`                       | karpenter      | `<env>-karpenter`         | ec2:* (scoped by tag)                |

The trust policy on each role uses StringEquals on
`<oidc-provider>:sub = system:serviceaccount:<ns>:<name>` so only the
exact SA can assume it.

## 5. Helm dependency graph

The umbrella chart `helm/Chart.yaml` declares 5 sub-chart dependencies:

```
observability-stack (umbrella)
├── kube-prometheus-stack (Prometheus + Alertmanager + Grafana + node-exporter + kube-state-metrics)
├── loki
├── promtail
├── jaeger
└── opentelemetry-collector
```

`helm dependency update` (or `terraform`'s helm provider) resolves them.

The umbrella chart's `templates/` directory adds:
- `otel-collector.yaml` — a full `OpenTelemetryCollector` CR with receivers,
  processors (k8sattributes, batch, memory_limiter, resourcedetection),
  exporters (otlp/jaeger, prometheusremotewrite, loki), and 3 pipelines.
- `prometheus-rules.yaml` — recording rules + the Four Golden Signals alerts.
- `otel-serviceaccount.yaml` — explicitly created SA (so IRSA works).

## 6. Storage tiers

| Bucket                     | Purpose                       | Lifecycle              | Encryption |
|----------------------------|-------------------------------|------------------------|------------|
| `obs-stack-<env>-loki`     | Loki chunks + index           | 30d → STANDARD_IA, 365d expire | KMS-CMK    |
| `obs-stack-<env>-jaeger`   | Jaeger span archive           | 30d expire             | KMS-CMK    |
| `obs-stack-<env>-prometheus`| Prometheus LTSS via Thanos   | 30d IA, 90d Glacier, 730d expire | KMS-CMK    |

All three buckets share a single customer-managed KMS key
`alias/obs-stack-<env>-obs` so audit logs in CloudTrail show one consistent
key.

## 7. Update / upgrade procedure

1. **Bump a chart version**: edit `terraform/variables.tf` (e.g.
   `kube_prometheus_stack_version = "62.0.0"`).
2. `cd terraform && terraform plan` — should show a helm_release in-place
   update.
3. `terraform apply`.
4. Watch the rollout:
   ```bash
   kubectl -n observability rollout status deploy/observability-stack-kube-prometheus-prometheus
   ```
5. Verify with `make verify`.

For stateful components (Loki, Prometheus) the PVCs persist across upgrades,
so no data loss.

## 8. On-call runbook (very abbreviated)

| Symptom                                  | First place to look                | Likely cause                          |
|------------------------------------------|------------------------------------|---------------------------------------|
| "App is slow"                            | Traces & Logs dashboard in Grafana | A downstream hop adding latency       |
| `HighErrorRate` alert fires              | Logs dashboard, filter severity=ERROR | Bad deploy, dependency outage         |
| `NodeCPUHigh` fires                      | K8s overview dashboard             | Runaway pod, need to scale out        |
| `PodCrashLooping` fires                  | `kubectl -n <ns> logs <pod> --previous` | Bad config, missing secret, OOM      |
| `PrometheusDown` fires                   | `kubectl -n observability get pod -l app.kubernetes.io/name=prometheus` | PVC full, OOM kill |
| Loki "too many outstanding requests"     | Loki logs + Grafana "Loki" panel   | Query too broad, scale read replicas  |
| Jaeger UI empty                          | OTel collector metrics endpoint    | Collector down, exporter misconfigured |

## 9. Multi-cluster (future work)

For multi-cluster, the recommended pattern:

- Run **one** Prometheus per cluster (this stack, unchanged).
- Add **Thanos receive** in a central cluster (or use Amazon Managed
  Prometheus).
- Each cluster's Prometheus remote-writes to the central receiver.
- Run **one** Loki per cluster, with object storage shared in each region.
- Run **one** Jaeger per cluster, with shared S3 per region (Jaeger supports
  multi-tenant namespaces).
- Grafana in the central cluster queries everything.
