"""
Frontend service — calls three downstream services and emits OTel signals.

Endpoints:
  GET /            -> homepage with links
  GET /api/items   -> fetches items from backend, then cart from cart service
  GET /api/checkout-> fan-out to checkout (which calls backend + cart)
  GET /healthz     -> liveness
  GET /slow        -> artificially slow endpoint (use this to test alerts)
  GET /error       -> always returns 500 (use this to test error alerts)

OTel instrumentation:
  - auto-instruments FastAPI with @trace
  - exports OTLP to http://otel-collector:4318 (the gateway)
  - all spans carry k8s metadata added by the collector's k8sattributes processor
"""
from __future__ import annotations

import asyncio
import os
import random
import time
from contextlib import asynccontextmanager

import httpx
from fastapi import FastAPI, HTTPException, Request
from opentelemetry import metrics, trace
from opentelemetry.exporter.otlp.proto.http.metric_exporter import OTLPMetricExporter
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.instrumentation.httpx import HTTPXClientInstrumentor
from opentelemetry.instrumentation.logging import LoggingInstrumentor
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest

# --------------------------------------------------------------------------- #
#  OTel setup                                                                  #
# --------------------------------------------------------------------------- #
SERVICE_NAME = "frontend"
OTLP_ENDPOINT = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://otel-collector:4318")

resource = Resource.create({
    "service.name": SERVICE_NAME,
    "service.namespace": os.getenv("SERVICE_NAMESPACE", "demo"),
    "service.version": os.getenv("APP_VERSION", "1.0.0"),
    "deployment.environment": os.getenv("DEPLOY_ENV", "dev"),
})

# Traces
tracer_provider = TracerProvider(resource=resource)
tracer_provider.add_span_processor(
    BatchSpanProcessor(OTLPSpanExporter(endpoint=f"{OTLP_ENDPOINT}/v1/traces"))
)
trace.set_tracer_provider(tracer_provider)

# Metrics — also exported via OTLP (the collector forwards to Prometheus remote-write)
metric_reader = PeriodicExportingMetricReader(
    OTLPMetricExporter(endpoint=f"{OTLP_ENDPOINT}/v1/metrics"),
    export_interval_millis=10_000,
)
meter_provider = MeterProvider(resource=resource, metric_readers=[metric_reader])
metrics.set_meter_provider(meter_provider)

meter = metrics.get_meter(__name__)

# Prometheus-format metrics (also scraped by ServiceMonitor)
REQUESTS = Counter(
    "http_requests_total",
    "Total HTTP requests",
    ["method", "endpoint", "status"],
)
LATENCY = Histogram(
    "http_request_duration_seconds",
    "HTTP request duration",
    ["method", "endpoint", "status"],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 0.8, 1.0, 2.5, 5.0, 10.0),
)

# --------------------------------------------------------------------------- #
#  Downstream URLs                                                             #
# --------------------------------------------------------------------------- #
BACKEND_URL = os.getenv("BACKEND_URL", "http://backend:8000")
CART_URL = os.getenv("CART_URL", "http://cart:8000")
CHECKOUT_URL = os.getenv("CHECKOUT_URL", "http://checkout:8000")


@asynccontextmanager
async def lifespan(app: FastAPI):
    HTTPXClientInstrumentor().instrument()
    LoggingInstrumentor().instrument(set_logging_format=True)
    yield
    tracer_provider.shutdown()
    meter_provider.shutdown()


app = FastAPI(title="obs-demo-frontend", lifespan=lifespan)
FastAPIInstrumentor.instrument_app(app)

tracer = trace.get_tracer(__name__)


# --------------------------------------------------------------------------- #
#  Routes                                                                      #
# --------------------------------------------------------------------------- #
@app.get("/")
async def root():
    REQUESTS.labels("GET", "/", "200").inc()
    return {
        "service": SERVICE_NAME,
        "endpoints": [
            "/api/items",
            "/api/checkout",
            "/slow",
            "/error",
            "/healthz",
            "/metrics",
        ],
    }


@app.get("/api/items")
async def get_items():
    start = time.perf_counter()
    status = "200"
    try:
        with tracer.start_as_current_span("frontend.get_items") as span:
            span.set_attribute("user.id", "demo-user")

            async with httpx.AsyncClient(timeout=2.0) as client:
                # Fan-out: backend + cart in parallel
                backend_task = client.get(f"{BACKEND_URL}/api/items")
                cart_task = client.get(f"{CART_URL}/api/cart")

                backend_resp, cart_resp = await asyncio.gather(
                    backend_task, cart_task, return_exceptions=True
                )

                if isinstance(backend_resp, Exception):
                    span.record_exception(backend_resp)
                    status = "502"
                    raise HTTPException(502, "backend unreachable")

                return {
                    "items": backend_resp.json().get("items", []),
                    "cart": cart_resp.json() if not isinstance(cart_resp, Exception) else {},
                }
    finally:
        elapsed = time.perf_counter() - start
        REQUESTS.labels("GET", "/api/items", status).inc()
        LATENCY.labels("GET", "/api/items", status).observe(elapsed)


@app.get("/api/checkout")
async def checkout():
    start = time.perf_counter()
    status = "200"
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            resp = await client.post(f"{CHECKOUT_URL}/api/checkout")
            if resp.status_code != 200:
                status = str(resp.status_code)
                raise HTTPException(resp.status_code, "checkout failed")
            return resp.json()
    finally:
        elapsed = time.perf_counter() - start
        REQUESTS.labels("GET", "/api/checkout", status).inc()
        LATENCY.labels("GET", "/api/checkout", status).observe(elapsed)


@app.get("/slow")
async def slow():
    """Artificially slow endpoint — used to trigger latency alerts."""
    start = time.perf_counter()
    delay = random.uniform(1.2, 2.5)   # above the 800ms p99 alert threshold
    await asyncio.sleep(delay)
    REQUESTS.labels("GET", "/slow", "200").inc()
    LATENCY.labels("GET", "/slow", "200").observe(time.perf_counter() - start)
    return {"slept": delay}


@app.get("/error")
async def error():
    """Always returns 500 — used to trigger error alerts."""
    REQUESTS.labels("GET", "/error", "500").inc()
    LATENCY.labels("GET", "/error", "500").observe(0.001)
    raise HTTPException(500, "intentional error for demo")


@app.get("/healthz")
async def healthz():
    REQUESTS.labels("GET", "/healthz", "200").inc()
    return {"status": "ok"}


@app.get("/metrics")
async def metrics_endpoint():
    from starlette.responses import Response
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
