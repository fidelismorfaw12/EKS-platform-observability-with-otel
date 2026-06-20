# Quick reference — common commands after deploy

```bash
# === Access ===
make grafana      # http://localhost:8080  (admin / output of `terraform output grafana_admin_password`)
make jaeger       # http://localhost:16686
make prometheus   # http://localhost:9090
make loki         # http://localhost:3100/ready (readiness probe)

# === Health ===
make verify
kubectl -n observability get pods
kubectl -n observability get prometheusrules -o yaml
kubectl -n observability get servicemonitors -A

# === Demo load ===
make load         # generates mixed traffic including /slow and /error

# === Trigger alerts ===
# HighLatencyP99: hit /slow repeatedly for >10m
kubectl -n demo-apps run slow-load --rm -it --image=curlimages/curl:8.7.1 \
  --restart=Never -- /bin/sh -c 'while true; do curl -s http://frontend/slow; done'

# HighErrorRate: hit /error repeatedly for >5m
kubectl -n demo-apps run err-load --rm -it --image=curlimages/curl:8.7.1 \
  --restart=Never -- /bin/sh -c 'while true; do curl -s http://frontend/error; sleep 0.1; done'

# === Useful PromQL ===
# p99 latency per job
histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket[5m])) by (job, le))

# Error ratio per job
sum(rate(http_requests_total{status=~"5.."}[5m])) by (job) /
  clamp_min(sum(rate(http_requests_total[5m])) by (job), 1)

# Top 10 pods by CPU
topk(10, sum(rate(container_cpu_usage_seconds_total{container!=""}[5m])) by (namespace, pod))

# Node memory pressure
1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)

# === Useful LogQL (Loki) ===
{namespace="demo-apps"} | json | severity_text="ERROR"
{namespace="demo-apps", pod=~"frontend-.*"} |= "checkout"

# === Useful trace search (Jaeger UI) ===
# Service: frontend
# Operation: GET /api/checkout
# Tags: error=true
```
