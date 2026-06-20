# Observability Stack on AWS EKS

A production-grade, end-to-end observability platform on AWS EKS, provisioned
with Terraform and deployed with Helm. It gives you the **three pillars of
observability** (metrics, logs, traces) plus the **Four Golden Signals** as
pre-wired dashboards and alerts — out of the box.

> "kubectl top pod is not observability. Knowing what your system is doing, why
> it's slow, and where — that is."

---

## What you get

| Pillar    | Tool                                  | Role                                              |
|-----------|---------------------------------------|---------------------------------------------------|
| Metrics   | Prometheus + Alertmanager + Grafana   | "Is something wrong?" — smoke detector            |
| Logs      | Loki + Promtail                       | "What exactly happened?" — security footage       |
| Traces    | Jaeger + OpenTelemetry Collector      | "Where is the slowdown?" — flight recorder        |
| Glue      | OpenTelemetry SDK + Collector         | One SDK, one collector, vendor-neutral backends  |

Plus:

- **VPC** (3 AZs, public/private/intra subnets, NAT GW, flow logs)
- **EKS 1.30** with 3 managed node groups (system / workload / observability)
- **Karpenter** for autoscaling (optional, default on)
- **IRSA** roles for every observability component (least privilege)
- **S3 + KMS** buckets for Loki chunks, Jaeger spans, Prometheus LTSS
- **kube-prometheus-stack** with pre-loaded dashboards and PrometheusRules
- **OpenTelemetry Collector** as a gateway with full k8s attribute enrichment
- **4 demo microservices** (frontend / backend / cart / checkout) already
  instrumented with the OpenTelemetry SDK + Prometheus client
- **ServiceMonitors** for every demo app
- **PrometheusRules** for the Four Golden Signals (latency, traffic, errors,
  saturation) + cluster health + self-monitoring
- **Grafana dashboards**: Four Golden Signals, K8s overview, Traces & Logs

---

## Architecture

```
                         ┌──────────────────────────────────────────────────┐
                         │                   AWS Account                     │
                         │                                                  │
   Terraform ──────────► │   VPC (3 AZs, private+public+intra subnets)       │
                         │        │                                          │
                         │        ▼                                          │
                         │   EKS 1.30 (control plane, private endpoint)      │
                         │        │                                          │
                         │   ┌────┼──────────────────────────────────┐       │
                         │   │    ▼                                   │       │
                         │   │  Node groups:                          │       │
                         │   │   - system          (t3.large)         │       │
                         │   │   - workload         (t3.medium)        │       │
                         │   │   - observability    (r6i.xlarge,       │       │
                         │   │                       tainted)          │       │
                         │   │   - + Karpenter spot pool              │       │
                         │   └────────────────────────────────────────┘       │
                         │        │                                          │
                         │        ▼                                          │
                         │   Helm umbrella chart → observability namespace   │
                         │   ┌──────────────────────────────────────────┐    │
                         │   │  kube-prometheus-stack (Prometheus,       │    │
                         │   │    Alertmanager, Grafana, node-exporter,  │    │
                         │   │    kube-state-metrics)                    │    │
                         │   │  Loki  (single-binary dev / distributed  │    │
                         │   │    prod)  +  S3 backend                   │    │
                         │   │  Promtail  (DaemonSet on every node)     │    │
                         │   │  Jaeger all-in-one + S3 backend           │    │
                         │   │  OpenTelemetry Collector (gateway)        │    │
                         │   └──────────────────────────────────────────┘    │
                         │                                                  │
                         │   S3 buckets:                                    │
                         │     - obs-stack-<env>-loki       (KMS-encrypted)  │
                         │     - obs-stack-<env>-jaeger                      │
                         │     - obs-stack-<env>-prometheus                  │
                         │                                                  │
                         │   IRSA roles:                                    │
                         │     - <env>-loki, <env>-jaeger, <env>-prometheus │
                         └──────────────────────────────────────────────────┘
                                            │
                                            ▼
                          Demo apps (demo-apps namespace):
                            frontend ──► checkout ──► backend
                                       └─────────► cart
                          Every pod emits OTLP → otel-collector → backends
                          Every pod exposes /metrics → ServiceMonitor → Prometheus
                          Every pod logs to stdout → Promtail → Loki
```

---

## Folder layout

```
observability-stack/
├── README.md                         <-- you are here
├── Makefile                          <-- common commands
│
├── terraform/                        <-- all AWS + Helm infra
│   ├── main.tf                       root composition (vpc → eks → iam → storage → helm)
│   ├── variables.tf                  inputs
│   ├── outputs.tf                    cluster name, IRSA ARNs, grafana password
│   ├── providers.tf                  k8s/helm/kubectl providers wired to EKS
│   ├── versions.tf                   provider pinning
│   ├── backend.tf                    S3 + DynamoDB state backend
│   ├── terraform.tfvars.example      copy → terraform.tfvars
│   └── modules/
│       ├── vpc/                      AWS VPC, 3 AZs, flow logs
│       ├── eks/                      EKS cluster, 3 node groups, add-ons, Karpenter
│       ├── iam/                      IRSA roles for loki/jaeger/prometheus
│       └── storage/                  S3 buckets + KMS key
│
├── helm/                             <-- umbrella chart for the obs stack
│   ├── Chart.yaml                    declares 5 sub-chart dependencies
│   ├── values.yaml                   default values (dev-leaning)
│   ├── values-dev.yaml               dev overrides (cheap)
│   ├── values-prod.yaml              prod overrides (HA, distributed Loki)
│   └── templates/
│       ├── _helpers.tpl
│       ├── otel-collector.yaml       full OTel Collector pipeline
│       ├── otel-serviceaccount.yaml
│       └── prometheus-rules.yaml     recording rules + Four Golden Signals alerts
│
├── k8s/                              <-- standalone K8s manifests (if you skip TF)
│   └── namespaces/
│       └── namespaces.yaml
│
├── apps/                             <-- 4 demo microservices, fully instrumented
│   ├── frontend/   (FastAPI + OTel, fan-out to checkout/backend/cart)
│   ├── backend/    (returns items list)
│   ├── cart/       (in-memory cart)
│   └── checkout/   (orchestrates backend + cart — great for trace demos)
│       └── each has: src/main.py, Dockerfile, requirements.txt, k8s/deployment.yaml
│
├── dashboards/                       <-- Grafana dashboard ConfigMaps
│   ├── golden-signals.yaml           Four Golden Signals dashboard
│   ├── kubernetes-overview.yaml      cluster health dashboard
│   └── traces-logs.yaml              Jaeger + Loki integration dashboard
│
├── alerts/                           <-- standalone PrometheusRule (also in helm/templates)
│   └── golden-signals.yaml
│
├── scripts/                          <-- ops scripts
│   ├── bootstrap-state.sh            one-time: create S3 + DynamoDB backend
│   ├── deploy.sh                     full deploy (init → plan → apply → kubeconfig)
│   ├── destroy.sh                    full teardown
│   └── verify.sh                     health check (exits 0 if green)
│
└── docs/                             <-- deeper docs (add your own)
```

---

## Prerequisites

| Tool        | Version  | Notes                                            |
|-------------|----------|--------------------------------------------------|
| aws CLI     | >= 2.13  | configured with admin-ish credentials            |
| terraform   | >= 1.5   |                                                  |
| kubectl     | >= 1.28  |                                                  |
| helm        | >= 3.13  |                                                  |
| docker      | >= 24    | only if you want to build the demo app images    |
| jq          | >= 1.6   | used by `verify.sh`                              |

You also need an AWS account with permissions to create VPC, EKS, IAM, S3, KMS,
DynamoDB, and CloudWatch resources.

---

## Quick start (15-minute end-to-end)

```bash
# 1. Unzip
unzip observability-stack.zip
cd observability-stack

# 2. Set AWS credentials (any method you like)
export AWS_REGION=us-east-1
aws configure

# 3. Copy tfvars and edit if you want non-default values
cp terraform/terraform.tfvars.example terraform/terraform.tfvars

# 4. One-time: create the S3 bucket + DynamoDB table for terraform state
make bootstrap

# 5. Edit backend.tf bucket name if you changed TF_STATE_BUCKET

# 6. Deploy EVERYTHING (VPC + EKS + Helm releases + demo apps)
make deploy
#   ~15 minutes — first time also creates the EKS cluster

# 7. Configure kubectl to talk to the new cluster
aws eks update-kubeconfig --region us-east-1 --name obs-stack-dev

# 8. Verify the stack is healthy
make verify

# 9. Open Grafana
make grafana
#   → http://localhost:8080   user=admin  password=$(terraform -chdir=terraform output -raw grafana_admin_password)

# 10. Generate traffic to see data flow
make load
```

---

## Verifying it works

### Metrics (Prometheus)

Open Grafana → "Four Golden Signals" dashboard. Hit the demo apps:

```bash
make load    # generates traffic to /api/items, /api/checkout, /slow, /error
```

You should see:
- **Latency p99** climbing because `/slow` adds 1.2-2.5s per call
- **Error rate** non-zero because `/error` always returns 500
- **Traffic** matching the load generator rate
- **Saturation** creeping up on the workload nodes

### Logs (Loki)

In Grafana, switch to **Explore** → **Loki** datasource. Try:

```logql
{namespace="demo-apps"} | json | severity_text="ERROR"
```

Or correlate logs with metrics: open the "Traces & Logs" dashboard and watch
the live tail.

### Traces (Jaeger)

```bash
make jaeger
```

Open http://localhost:16686, select service `frontend`, find a trace for
`GET /api/checkout`. You'll see the full hop chain:

```
frontend.get_items
└── checkout.process
    ├── backend.list_items
    └── cart.get
```

The OpenTelemetry Collector enriches every span with `k8s.namespace.name`,
`k8s.pod.name`, `k8s.deployment.name`, `k8s.node.name`, and `cluster`.

### Alerts

Hit `/error` repeatedly for >5 minutes:

```bash
kubectl -n demo-apps run gen-error --rm -it --image=curlimages/curl:8.7.1 \
  --restart=Never -- /bin/sh -c 'for i in $(seq 1 1000); do curl -s http://frontend/error; sleep 0.1; done'
```

After ~5 minutes the `HighErrorRate` alert should fire. Check:

```bash
kubectl -n observability port-forward svc/observability-stack-kube-prometheus-alertmanager 9093:9093
# → http://localhost:9093  to see firing alerts
```

If you wire Slack webhook URLs into `helm/values.yaml` (`alertmanager.config`),
the alerts route to your `#alerts-critical` and `#alerts-warning` channels.

---

## The Four Golden Signals — what to alert on

This stack ships pre-wired alerting rules based on Google SRE's framework:

| Signal      | What it answers                | Alert rule                    | Threshold                                  |
|-------------|--------------------------------|-------------------------------|--------------------------------------------|
| Latency     | "How long do requests take?"   | `HighLatencyP99`              | p99 > 800ms for 10m AND > 1 req/s          |
|             |                                | `LatencyP99Spike`             | p99 tripled vs 30m ago                     |
| Traffic     | "How much demand?"             | `TrafficDrop`                 | <10% of 1h-ago traffic for 10m (CRITICAL)  |
|             |                                | `TrafficSpike`                | 5x normal traffic for 10m (WARNING)        |
| Errors      | "What fraction is failing?"    | `HighErrorRate`               | 5xx ratio > 1% AND > 1 req/s, for 5m       |
|             |                                | `PodCrashLooping`             | >5 restarts in 1h                          |
| Saturation  | "How full is the system?"      | `NodeCPUHigh` / `NodeMemoryHigh` / `NodeDiskFull` | 85% / 90% / 85%                  |
|             |                                | `PodCPUThrottled`             | throttled > 50% of periods                 |
|             |                                | `PodMemoryNearLimit`          | > 90% of memory limit                      |

The single most useful alert query:

```promql
rate(http_requests_total{status=~"5.."}[5m])
  / rate(http_requests_total[5m]) > 0.01
```

One PromQL. One signal. One alert that actually means something.

---

## Configuration

### Per-environment overrides

| File                       | When to use                                  |
|----------------------------|----------------------------------------------|
| `helm/values.yaml`         | defaults — dev-leaning                       |
| `helm/values-dev.yaml`     | cheap & small (single Loki, short retention) |
| `helm/values-prod.yaml`    | HA (2 Prometheus, 3 Loki replicas per role)  |

Pass them at deploy time:

```bash
# In terraform/main.tf, the helm_release block builds values dynamically,
# but you can also post-apply override with helm:
helm -n observability upgrade observability-stack ./helm \
  -f helm/values.yaml -f helm/values-prod.yaml
```

### Key Terraform variables

| Variable                   | Default         | What                                            |
|----------------------------|-----------------|-------------------------------------------------|
| `region`                   | us-east-1       | AWS region                                      |
| `environment`              | dev             | dev / staging / prod — gates retention, HA      |
| `cluster_version`          | 1.30            | EKS Kubernetes version                          |
| `system_node_group`        | t3.large ×2     | kube-system + ops                               |
| `workload_node_group`      | t3.medium ×3    | user apps                                       |
| `observability_node_group` | r6i.xlarge ×2   | tainted — only obs pods schedule here           |
| `grafana_admin_password`   | change-me       | override in prod                                |
| `enable_karpenter`         | true            | spot autoscaling                                |

### Helm chart versions

Pinned in `terraform/variables.tf` so upgrades are explicit. Current versions:

| Chart                          | Version  |
|--------------------------------|----------|
| kube-prometheus-stack          | 61.2.0   |
| loki                           | 6.7.4    |
| promtail                       | 6.16.0   |
| jaeger                         | 3.1.2    |
| opentelemetry-collector        | 0.95.0   |

---

## Cost notes (dev defaults)

On `us-east-1` as of 2025:

| Item                       | $/hour | Notes                              |
|----------------------------|--------|------------------------------------|
| 2 × t3.large (system)      | 0.166  |                                    |
| 3 × t3.medium (workload)   | 0.084  |                                    |
| 2 × r6i.xlarge (obs)       | 0.502  |                                    |
| 1 NAT GW                   | 0.045  |                                    |
| EKS control plane          | 0.100  |                                    |
| **≈ Total**                | **~$1.93/hr ≈ $1,400/month** |

Switch to `spot` instance types, drop `observability_node_group` to 1, and
disable Karpenter to drop to ~$700/month.

---

## Disaster recovery / backup

- **Terraform state** lives in versioned S3 with KMS encryption.
- **Loki chunks** in `obs-stack-<env>-loki` S3 bucket (versioned, 365d lifecycle).
- **Jaeger spans** in `obs-stack-<env>-jaeger` S3 bucket (30d expiration).
- **Prometheus LTSS** in `obs-stack-<env>-prometheus` (1y lifecycle, 2y expire).
- **Grafana dashboards** as ConfigMaps (GitOps-friendly, recoverable from repo).
- **Alert rules** as `PrometheusRule` CRs (recoverable from repo).

To restore: re-clone the repo, run `terraform init && terraform apply`. State
re-attaches to the existing AWS resources via the S3 backend.

---

## Security

- All S3 buckets: KMS-encrypted, public access blocked, TLS enforced.
- All IRSA roles: least-privilege, scoped to a single bucket per component.
- EKS control plane: secrets encrypted with KMS.
- EKS API: public endpoint open in dev (close in prod via
  `cluster_endpoint_public_access_cidrs`).
- Node groups: IMDSv2 required, latest AL2023 AMI.
- Service Accounts: IRSA everywhere — no static AWS keys in pods.

To harden for prod:

1. Set `cluster_endpoint_public_access = false` and use a private VPN.
2. Enable EKS Pod Identities instead of IRSA (EKS 1.30+).
3. Add NetworkPolicies to restrict pod-to-pod traffic.
4. Wire Grafana to AWS Cognito / SSO.

---

## Troubleshooting

### `terraform apply` fails on helm_release with "context deadline exceeded"

This is normal on first deploy — some CRDs need a reconcile cycle. Wait 60s
and re-run `terraform apply`. The release is idempotent.

### Pods stuck in `Pending` on the observability namespace

Check the taint — only pods with the matching toleration can land on the
observability node group:

```bash
kubectl -n observability describe pod <pod> | grep -A5 Events
kubectl get nodes -l workload=observability
```

If you're out of capacity, bump `observability_node_group.desired_size` in
`terraform/variables.tf`.

### Loki: `too many outstanding requests`

Increase `loki.singleBinary.replicas` (dev) or switch to `values-prod.yaml`
which uses distributed mode.

### Prometheus: `out of order samples`

You have two Prometheuses scraping the same target (e.g. via remote-write
plus direct scrape). Disable one.

### Jaeger: no traces showing

1. Confirm the OTel Collector pod is running:
   ```bash
   kubectl -n observability get pods -l app.kubernetes.io/name=opentelemetry-collector
   ```
2. Confirm the demo apps are emitting OTLP:
   ```bash
   kubectl -n demo-apps exec -it deploy/frontend -- \
     python -c "import os; print(os.getenv('OTEL_EXPORTER_OTLP_ENDPOINT'))"
   ```
   Should print `http://otel-gateway-collector.observability:4318`.
3. Check the Collector's metrics endpoint:
   ```bash
   kubectl -n observability port-forward svc/otel-gateway-collector 8888:8888
   curl -s localhost:8888/metrics | grep otelcol_receiver_accepted_spans
   ```

### Grafana shows "datasource not found"

The datasources are configured via the umbrella chart values. If they're
missing, run:

```bash
kubectl -n observability get secret observability-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d ; echo
kubectl -n observability get configmap observability-stack-grafana -o yaml | grep -A20 datasources
```

### Want to switch from Jaeger to Tempo?

Replace the `jaeger` dependency in `helm/Chart.yaml` with:

```yaml
- name: tempo
  repository: https://grafana.github.io/helm-charts
  version: "1.10.0"
  condition: tempo.enabled
```

Add a `tempo` block to `values.yaml`, and point the OTel exporter
`otlp/jaeger` endpoint at `observability-stack-tempo:4317`. Grafana already
ships with a Tempo datasource option.

---

## Roadmap (intentionally not included)

- Amazon Managed Grafana / Managed Prometheus swap
- Loki distributed mode (already templated in `values-prod.yaml`)
- Tempo instead of Jaeger (5-line swap above)
- Thanos for Prometheus LTSS (skeleton in `values-prod.yaml`)
- Flux/ArgoCD GitOps wiring
- OpenTelemetry Operator auto-instrumentation (no code changes for app teams)
- Pyrra SLO automation

---

## Uninstall

```bash
make destroy                  # tears down all AWS resources + Helm releases
FORCE_DELETE_BUCKETS=1 make destroy   # also wipes the S3 buckets
```

This will leave the S3 state bucket and DynamoDB table in place so you can
re-apply later. To wipe them too:

```bash
aws s3 rb s3://obs-stack-tfstate --force
aws dynamodb delete-table --table-name obs-stack-tfstate-locks
```

---

## License

MIT. See `LICENSE` (or add your own).

---

## Acknowledgements

Inspired by the LinkedIn post on the three pillars + four golden signals
framework that originally motivated this repo. The stack is the open-source
answer to "what would a real SRE team actually install?" — Prometheus, Loki,
Jaeger, Grafana, OpenTelemetry — wired together with Terraform and Helm so
you can go from zero to "I can see my p99" in 15 minutes.
