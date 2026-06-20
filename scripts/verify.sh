#!/usr/bin/env bash
# Verify the observability stack is healthy after deploy.
# Exits 0 if green, 1 if any component is not ready.
set -uo pipefail
cd "$(dirname "$0")/.."

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { printf "${GREEN}\u2713${NC} %s\n" "$*"; }
fail() { printf "${RED}\u2717${NC} %s\n" "$*"; }

errors=0

# ---- Namespaces ---- #
for ns in observability demo-apps karpenter; do
  if kubectl get ns "$ns" >/dev/null 2>&1; then
    ok "namespace $ns exists"
  else
    fail "namespace $ns missing"
    errors=$((errors+1))
  fi
done

# ---- Prometheus operator pods ---- #
for deploy in observability-stack-kube-prometheus-prometheus \
              observability-stack-kube-prometheus-alertmanager \
              observability-stack-grafana \
              observability-stack-kube-state-metrics \
              observability-stack-prometheus-node-exporter; do
  if kubectl -n observability get deploy "$deploy" >/dev/null 2>&1; then
    ok "deployment $deploy exists"
  else
    fail "deployment $deploy missing"
    errors=$((errors+1))
  fi
done

# ---- Loki + Promtail ---- #
kubectl -n observability get deploy observability-stack-loki >/dev/null 2>&1 \
  && ok "Loki deployed" || { fail "Loki missing"; errors=$((errors+1)); }

if kubectl -n observability get ds observability-stack-promtail >/dev/null 2>&1; then
  DESIRED=$(kubectl -n observability get ds observability-stack-promtail -o jsonpath='{.status.desiredNumberScheduled}')
  READY=$(kubectl -n observability get ds observability-stack-promtail -o jsonpath='{.status.numberReady}')
  if [[ "$DESIRED" == "$READY" ]]; then
    ok "Promtail DaemonSet ready ($READY/$DESIRED)"
  else
    fail "Promtail DaemonSet NOT ready ($READY/$DESIRED)"
    errors=$((errors+1))
  fi
fi

# ---- Jaeger ---- #
kubectl -n observability get deploy observability-stack-jaeger >/dev/null 2>&1 \
  && ok "Jaeger deployed" || { fail "Jaeger missing"; errors=$((errors+1)); }

# ---- OTel Collector ---- #
kubectl -n observability get otelcol otel-gateway >/dev/null 2>&1 \
  && ok "OpenTelemetryCollector CR exists" \
  || { fail "OpenTelemetryCollector CR missing"; errors=$((errors+1)); }

# ---- CRDs ---- #
for crd in prometheuses.monitoring.coreos.com \
           alertmanagers.monitoring.coreos.com \
           servicemonitors.monitoring.coreos.com \
           podmonitors.monitoring.coreos.com \
           prometheusrules.monitoring.coreos.com \
           opentelemetrycollectors.opentelemetry.io; do
  kubectl get crd "$crd" >/dev/null 2>&1 \
    && ok "CRD $crd" \
    || { fail "CRD $crd missing"; errors=$((errors+1)); }
done

# ---- ServiceMonitors ---- #
SM_COUNT=$(kubectl -n demo-apps get servicemonitors -o jsonpath='{.items}' 2>/dev/null | jq 'length' 2>/dev/null || echo 0)
if [[ "$SM_COUNT" -ge 4 ]]; then
  ok "ServiceMonitors for demo apps ($SM_COUNT)"
else
  fail "Expected 4 ServiceMonitors, got $SM_COUNT"
  errors=$((errors+1))
fi

# ---- PrometheusRule ---- #
PR_COUNT=$(kubectl -n observability get prometheusrules -o jsonpath='{.items}' 2>/dev/null | jq 'length' 2>/dev/null || echo 0)
if [[ "$PR_COUNT" -ge 1 ]]; then
  ok "PrometheusRule count: $PR_COUNT"
else
  fail "No PrometheusRules found"
  errors=$((errors+1))
fi

echo
if [[ "$errors" -eq 0 ]]; then
  printf "${GREEN}All checks passed.${NC}\n"
  exit 0
else
  printf "${RED}%d check(s) failed.${NC}\n" "$errors"
  exit 1
fi
