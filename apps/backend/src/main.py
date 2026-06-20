"""Backend service — returns a list of items. Uses in-memory state."""
from __future__ import annotations

import os
import random
import time

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

SERVICE_NAME = "backend"
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

ITEMS = [
    {"id": 1, "name": "Keyboard", "price": 49.99},
    {"id": 2, "name": "Mouse", "price": 19.99},
    {"id": 3, "name": "Monitor", "price": 299.99},
    {"id": 4, "name": "Headphones", "price": 89.99},
    {"id": 5, "name": "Webcam", "price": 59.99},
]

app = FastAPI(title="obs-demo-backend")
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


@app.get("/api/items")
async def list_items():
    with tracer.start_as_current_span("backend.list_items") as span:
        # simulate DB latency
        latency = random.uniform(0.01, 0.05)
        time.sleep(latency)
        span.set_attribute("items.count", len(ITEMS))
        span.set_attribute("db.latency_ms", latency * 1000)
        return {"items": ITEMS}


@app.get("/api/items/{item_id}")
async def get_item(item_id: int):
    with tracer.start_as_current_span("backend.get_item") as span:
        span.set_attribute("item.id", item_id)
        for item in ITEMS:
            if item["id"] == item_id:
                return item
        return {"error": "not found"}, 404


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
