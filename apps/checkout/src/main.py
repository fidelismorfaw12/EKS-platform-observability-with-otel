"""Checkout service — orchestrates backend + cart into a single checkout flow.

This is the service where a distributed trace really shines: a single
/api/checkout request fans out to backend (to validate items) and cart (to
read what's being purchased), then computes the total.

The trace in Jaeger shows the full hop chain:
  frontend -> checkout -> backend
                       -> cart
"""
from __future__ import annotations

import asyncio
import os
import time

import httpx
from fastapi import FastAPI, HTTPException, Request
from opentelemetry import metrics, trace
from opentelemetry.exporter.otlp.proto.http.metric_exporter import OTLPMetricExporter
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.instrumentation.httpx import HTTPXClientInstrumentor
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest

SERVICE_NAME = "checkout"
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
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0),
)

BACKEND_URL = os.getenv("BACKEND_URL", "http://backend:8000")
CART_URL = os.getenv("CART_URL", "http://cart:8000")

app = FastAPI(title="obs-demo-checkout")
FastAPIInstrumentor.instrument_app(app)
HTTPXClientInstrumentor().instrument()
tracer = trace.get_tracer(__name__)


@app.middleware("http")
async def metrics_middleware(request: Request, call_next):
    start = time.perf_counter()
    response = await call_next(request)
    elapsed = time.perf_counter() - start
    REQUESTS.labels(request.method, request.url.path, str(response.status_code)).inc()
    LATENCY.labels(request.method, request.url.path, str(response.status_code)).observe(elapsed)
    return response


@app.post("/api/checkout")
async def checkout():
    """Fan-out to backend + cart, compute total, return order summary."""
    with tracer.start_as_current_span("checkout.process") as span:
        async with httpx.AsyncClient(timeout=3.0) as client:
            # Fan-out
            backend_resp, cart_resp = await asyncio.gather(
                client.get(f"{BACKEND_URL}/api/items"),
                client.get(f"{CART_URL}/api/cart"),
            )

            if backend_resp.status_code != 200:
                span.record_exception(Exception("backend down"))
                raise HTTPException(502, "backend unreachable")

            if cart_resp.status_code != 200:
                span.record_exception(Exception("cart down"))
                raise HTTPException(502, "cart unreachable")

            items = {i["id"]: i for i in backend_resp.json().get("items", [])}
            cart_items = cart_resp.json().get("items", [])

            total = 0.0
            line_items = []
            for ci in cart_items:
                item = items.get(ci["item_id"])
                if not item:
                    continue
                line_total = item["price"] * ci["qty"]
                total += line_total
                line_items.append({
                    "name": item["name"],
                    "qty": ci["qty"],
                    "price": item["price"],
                    "line_total": line_total,
                })

            span.set_attribute("checkout.total", total)
            span.set_attribute("checkout.items", len(line_items))

            return {
                "order_id": f"ord-{int(time.time())}",
                "items": line_items,
                "total": round(total, 2),
            }


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
