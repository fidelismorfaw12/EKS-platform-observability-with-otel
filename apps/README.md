# Demo Apps — instrumented microservices

Four small FastAPI services that exercise the entire observability stack:

| Service   | Port | Calls              | Demonstrates                                   |
|-----------|------|--------------------|------------------------------------------------|
| frontend  | 8000 | backend, cart, checkout | Entry point. Fan-out traces, error/slow endpoints. |
| backend   | 8000 | (none)             | Simple GET. Baseline latency.                  |
| cart      | 8000 | (none)             | In-memory state.                               |
| checkout  | 8000 | backend, cart      | The killer demo: one trace shows the whole hop chain. |

## Topology

```
   User
    │
    ▼
┌──────────┐
│ frontend │──┬──► /api/items    ──► backend + cart (parallel)
└──────────┘  ├──► /api/checkout ──► checkout ──► backend + cart (parallel)
              ├──► /slow          ──► sleeps 1.2-2.5s (latency alert)
              └──► /error         ──► always 500 (error alert)
```

## Building

```bash
make build-apps   # builds all 4 images as obs-demo/<svc>:latest
```

Then push to your registry (ECR / kind / minikube):

```bash
# ECR example:
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin 000000000000.dkr.ecr.us-east-1.amazonaws.com

for svc in frontend backend cart checkout; do
  docker tag obs-demo/$svc:latest 000000000000.dkr.ecr.us-east-1.amazonaws.com/obs-demo/$svc:latest
  docker push 000000000000.dkr.ecr.us-east-1.amazonaws.com/obs-demo/$svc:latest
done
```

Then patch the deployments to use your image URI:

```bash
for svc in frontend backend cart checkout; do
  kubectl -n demo-apps set image deploy/$svc \
    $svc=000000000000.dkr.ecr.us-east-1.amazonaws.com/obs-demo/$svc:latest
done
```

## What each service emits

Every service:

- **Logs**: stdout JSON-structured logs (Promtail tails them).
- **Metrics** (Prometheus format on `/metrics`):
  - `http_requests_total{method, endpoint, status}` — Counter
  - `http_request_duration_seconds_bucket{method, endpoint, status, le}` — Histogram
- **Traces** (OTLP/gRPC+HTTP to `otel-gateway-collector:4317/4318`):
  - One span per request
  - k8s attributes added by the collector (namespace, pod, deployment, node)
  - `service.name`, `service.namespace`, `service.version`, `deployment.environment`

## The trace you want to see

After `make load`, open Jaeger and find a trace for `GET /api/checkout` on
service `frontend`. You should see:

```
frontend
└── checkout.process                            (gateway span)
    ├── backend.list_items                      (downstream HTTP call)
    └── cart.get                                (downstream HTTP call)
```

If a downstream is slow, Jaeger shows the latency on that specific span. **This
is the flight recorder the README talks about.**

## Without code changes: auto-instrumentation

If you'd rather not touch application code, install the OpenTelemetry Operator
and use its auto-instrumentation CRs. The SDK libraries (Python, Java, Node,
.NET, Go) get injected into your pods at runtime.

```bash
helm -n opentelemetry-operator install opentelemetry-operator \
  open-telemetry/opentelemetry-operator --create-namespace --set admissionWebhooks.autogenerateServiceName=true

cat <<'EOF' | kubectl apply -f -
apiVersion: opentelemetry.io/v1alpha1
kind: Instrumentation
metadata:
  name: python-auto
  namespace: demo-apps
spec:
  exporter:
    endpoint: http://otel-gateway-collector.observability:4318
  propagators: ["tracecontext", "baggage"]
  python:
    image: ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-python:latest
EOF
```

Then annotate your pods:

```yaml
metadata:
  annotations:
    instrumentation.opentelemetry.io/inject-python: "true"
```
