# Helm Umbrella Chart

This is the umbrella chart that installs the entire observability stack on top
of an existing EKS cluster.

## CRDs

All CRDs are installed **automatically** by their respective sub-charts:

| CRD                                 | Installed by                    |
|-------------------------------------|---------------------------------|
| `Prometheus`                        | kube-prometheus-stack           |
| `Alertmanager`                      | kube-prometheus-stack           |
| `ServiceMonitor`                    | kube-prometheus-stack           |
| `PodMonitor`                        | kube-prometheus-stack           |
| `PrometheusRule`                    | kube-prometheus-stack           |
| `Probe`                             | kube-prometheus-stack           |
| `AlertmanagerConfig`                | kube-prometheus-stack           |
| `OpenTelemetryCollector`            | opentelemetry-collector         |
| `Instrumentation` (optional)        | opentelemetry-operator          |

If you want to manage CRDs separately (GitOps style), set
`kubePrometheusStack.installCRDs=false` in `values.yaml` and apply the CRDs
from the upstream repos directly.

## Adding the chart deps locally

```bash
cd helm
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana             https://grafana.github.io/helm-charts
helm repo add jaegertracing       https://jaegertracing.github.io/helm-charts
helm repo add open-telemetry      https://open-telemetry.github.io/opentelemetry-helm-charts
helm dependency update
```

This populates `charts/` with `.tgz` files. They're gitignored by default.

## Templating without applying

```bash
helm template observability-stack . \
  --namespace observability \
  --values values.yaml \
  --values values-dev.yaml \
  > /tmp/rendered.yaml
```

Useful for diffing changes before deploy.

## Upgrading chart versions

1. Edit `Chart.yaml` and bump the version.
2. Edit `terraform/variables.tf` to match (so terraform doesn't try to downgrade).
3. `helm dependency update`.
4. `terraform plan` → should show `helm_release` in-place update.
5. `terraform apply`.

## Customizing the OTel Collector pipeline

The full pipeline is rendered in `templates/otel-collector.yaml`. The
receivers/processors/exporters are NOT parameterized through Helm values — we
opted for a single, opinionated, full-featured config so you can see exactly
what's running. To change it:

1. Edit `templates/otel-collector.yaml`.
2. `helm upgrade observability-stack . -n observability`.
3. Watch the new pod come up:
   ```bash
   kubectl -n observability rollout status deploy/otel-gateway-collector
   ```
