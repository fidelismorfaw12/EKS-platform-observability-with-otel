"""Cart service — holds an in-memory cart per session."""
from __future__ import annotations

import os
import time
import uuid
from collections import defaultdict

from fastapi import FastAPI, Request
from opentelemetry import metrics, trace
from opentelemetry.exporter.otlp.proto.http.metric_exporter import OTLPMetricExporter
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest

SERVICE_NAME = "cart"
OTLP_ENDPOINT = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://otel-collector:4318")

resource = Resource.create({"service.name": SERVICE_NAME, "service.namespace": "demo"})
tracer_provider = TracerProvider(resource=resource)
tracer_provider.add_span_processor(
    BatchSpanProcessor(OTLPSpanExporter(endpoint=f"{OTLP_ENDPOINT}/v1/traces"))
)
trace.set_tracer_provider(tracer_provider)

meter_provider = MeterProvider(
    resource=resource,
    metric_readers=[
        PeriodicExportingMetricReader(
            OTLPMetricExporter(endpoint=f"{OTLP_ENDPOINT}/v1/metrics"),
            export_interval_millis=10_000,
        )
    ],
)
metrics.set_meter_provider(meter_provider)

REQUESTS = Counter("http_requests_total", "Total HTTP requests", ["method", "endpoint", "status"])
LATENCY = Histogram(
    "http_request_duration_seconds",
    "HTTP request duration",
    ["method", "endpoint", "status"],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0),
)

CARTS: dict[str, list[dict]] = defaultdict(list)

app = FastAPI(title="obs-demo-cart")
FastAPIInstrumentor.instrument_app(app)
tracer = trace.get_tracer(__name__)


@app.middleware("http")
async def metrics_middleware(request: Request, call_next):
    start = time.perf_counter()
    response = await call_next(request)
    elapsed = time.perf_counter() - start
    REQUESTS.labels(request.method, request.url.path, str(response.status_code)).inc()
    LATENCY.labels(request.method, request.url.path, str(response.status_code)).observe(elapsed)
    return response


@app.get("/api/cart")
async def get_cart():
    """Returns the demo user's cart."""
    with tracer.start_as_current_span("cart.get") as span:
        session = "demo-user"
        span.set_attribute("user.id", session)
        return {"session": session, "items": CARTS[session]}


@app.post("/api/cart")
async def add_to_cart(item: dict):
    with tracer.start_as_current_span("cart.add") as span:
        session = "demo-user"
        item["line_id"] = str(uuid.uuid4())
        CARTS[session].append(item)
        span.set_attribute("cart.size", len(CARTS[session]))
        return {"added": item, "total_items": len(CARTS[session])}


@app.delete("/api/cart")
async def clear_cart():
    with tracer.start_as_current_span("cart.clear"):
        session = "demo-user"
        CARTS[session].clear()
        return {"cleared": True}


@app.get("/healthz")
async def healthz():
    return {"status": "ok"}


@app.get("/metrics")
async def metrics_endpoint():
    from starlette.responses import Response
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
