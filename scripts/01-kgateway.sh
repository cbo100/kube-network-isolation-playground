#!/usr/bin/env bash
# Plan 01 — install kgateway as the north-south ingress (Gateway API).
# Idempotent: safe to run repeatedly (kubectl apply + helm upgrade -i converge).
set -euo pipefail
. "$(dirname "$0")/lib.sh"

need kubectl
need helm

kubectl config use-context "$KIND_CONTEXT" >/dev/null

# --- 1. Gateway API CRDs (standard channel) -----------------------------------
log "installing Gateway API CRDs ${GATEWAY_API_VERSION}"
kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

# --- 2. kgateway CRDs chart ---------------------------------------------------
log "installing kgateway-crds ${KGATEWAY_VERSION}"
helm upgrade -i --create-namespace -n kgateway-system \
  --version "$KGATEWAY_VERSION" kgateway-crds \
  oci://cr.kgateway.dev/kgateway-dev/charts/kgateway-crds

# --- 3. kgateway control plane (with Istio ambient integration enabled) -------
log "installing kgateway control plane ${KGATEWAY_VERSION} (values from manifests/01-kgateway/values.yaml)"
helm upgrade -i -n kgateway-system kgateway \
  --version "$KGATEWAY_VERSION" \
  -f "${REPO_ROOT}/manifests/01-kgateway/values.yaml" \
  oci://cr.kgateway.dev/kgateway-dev/charts/kgateway

log "waiting for kgateway control plane"
retry 30 5 kubectl -n kgateway-system rollout status deploy/kgateway --timeout=20s

# --- 4. Gateway pinned to the control-plane node ------------------------------
log "applying Gateway + GatewayParameters (pinned to control-plane, hostPort 80)"
kubectl apply -f "${REPO_ROOT}/manifests/01-kgateway/gateway.yaml"

log "waiting for the generated proxy deployment"
retry 30 5 kubectl -n kgateway-system rollout status deploy/http --timeout=20s

# --- 5. Health route: /.gw/ping -> 200 PONG (DirectResponse, no backend) -------
log "applying gateway health route (/.gw/ping -> 200 PONG)"
kubectl apply -f "${REPO_ROOT}/manifests/01-kgateway/ping-route.yaml"

# --- 6. Report ----------------------------------------------------------------
log "gatewayclass:"; kubectl get gatewayclass kgateway
log "gateway:";      kubectl -n kgateway-system get gateway http
log "proxy pod placement:"
kubectl -n kgateway-system get pods -l app.kubernetes.io/name=http -o wide

log "end-to-end routing check via /.gw/ping (expect: 200 PONG):"
ping_ok=false
if retry 10 3 bash -c 'curl -fsS --max-time 5 http://localhost:9090/.gw/ping | grep -qx PONG'; then
  ping_ok=true
fi
body="$(curl -sS --max-time 5 http://localhost:9090/.gw/ping || true)"
code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 http://localhost:9090/.gw/ping || true)"
log "curl http://localhost:9090/.gw/ping -> HTTP ${code} body='${body}'"
if [ "$ping_ok" = true ]; then
  log "plan 01 complete: kgateway ${KGATEWAY_VERSION} routing verified (200 PONG on :9090)"
else
  die "gateway health check FAILED: /.gw/ping did not return 200 PONG"
fi
