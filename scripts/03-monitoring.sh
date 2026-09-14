#!/usr/bin/env bash
# Plan 03 — monitoring: kube-prometheus-stack (Prometheus/Grafana/Alertmanager) + Kiali,
# wired to scrape Istio ambient metrics (istiod, ztunnel).
# Idempotent: helm upgrade -i + kubectl apply converge on re-run.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

need kubectl
need helm

kubectl config use-context "$KIND_CONTEXT" >/dev/null

M="${REPO_ROOT}/manifests/03-monitoring"

# --- helm repos ---------------------------------------------------------------
log "adding/updating helm repos"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo add kiali https://kiali.org/helm-charts >/dev/null 2>&1 || true
helm repo update prometheus-community kiali >/dev/null

# --- 1. kube-prometheus-stack -------------------------------------------------
log "installing kube-prometheus-stack ${KUBE_PROM_STACK_VERSION}"
helm upgrade -i monitoring prometheus-community/kube-prometheus-stack \
  --version "$KUBE_PROM_STACK_VERSION" \
  --create-namespace -n monitoring \
  -f "${M}/kube-prometheus-stack.values.yaml"

log "waiting for Prometheus Operator + Grafana"
retry 40 5 kubectl -n monitoring rollout status deploy/monitoring-kube-prometheus-operator --timeout=20s
retry 40 5 kubectl -n monitoring rollout status deploy/monitoring-grafana --timeout=20s

# --- 2. Istio scrape config (PodMonitors) -------------------------------------
log "applying Istio ambient PodMonitors (istiod, ztunnel)"
kubectl apply -f "${M}/istio-podmonitors.yaml"

# --- 3. Kiali -----------------------------------------------------------------
log "installing kiali-server ${KIALI_VERSION}"
helm upgrade -i kiali-server kiali/kiali-server \
  --version "$KIALI_VERSION" \
  -n istio-system \
  -f "${M}/kiali.values.yaml"
retry 40 5 kubectl -n istio-system rollout status deploy/kiali --timeout=20s

# --- 4. Report + verify -------------------------------------------------------
log "monitoring namespace:"; kubectl -n monitoring get pods
log "kiali:"; kubectl -n istio-system get pods -l app=kiali

log "verifying Prometheus scrapes Istio targets (istiod, ztunnel):"
# Query the Prometheus API via a throwaway curl pod (the prometheus image lacks wget/curl).
check_targets() {
  kubectl -n monitoring run prom-check-$$ --rm -i --restart=Never --quiet \
    --image=curlimages/curl:8.11.1 --command -- \
    curl -sf "http://monitoring-kube-prometheus-prometheus.monitoring:9090/api/v1/targets?state=active" 2>/dev/null \
    | grep -q '"pod":"istiod'
}
if retry 20 6 check_targets; then
  log "plan 03 complete: Prometheus/Grafana/Alertmanager + Kiali up; Istio targets scraped"
else
  warn "Istio targets not yet visible in Prometheus; check PodMonitors and give it a minute"
  die "plan 03 verification incomplete"
fi
