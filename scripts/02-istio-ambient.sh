#!/usr/bin/env bash
# Plan 02 — install Istio ambient mesh (base, istiod, istio-cni, ztunnel) and
# enroll the kgateway ingress namespace so gateway->app traffic is mTLS via ztunnel.
# Idempotent: istioctl install and `kubectl label --overwrite` converge on re-run.
# istioctl is provided by mise (pinned in mise.toml).
set -euo pipefail
. "$(dirname "$0")/lib.sh"

need kubectl
mise_ensure

kubectl config use-context "$KIND_CONTEXT" >/dev/null
log "istioctl: $(istioctl version --remote=false 2>/dev/null | head -1)"

# --- 1. Install the ambient profile -------------------------------------------
log "installing Istio ${ISTIO_VERSION} (ambient profile)"
istioctl install --set profile=ambient --skip-confirmation

log "waiting for control plane + dataplane components"
retry 30 5 kubectl -n istio-system rollout status deploy/istiod --timeout=20s
retry 30 5 kubectl -n istio-system rollout status daemonset/istio-cni-node --timeout=20s
retry 30 5 kubectl -n istio-system rollout status daemonset/ztunnel --timeout=20s

# --- 2. Enroll the ingress namespace into the mesh ----------------------------
log "labelling kgateway-system for ambient (gateway->app mTLS via ztunnel)"
kubectl label ns kgateway-system istio.io/dataplane-mode=ambient --overwrite

# --- 3. Report ----------------------------------------------------------------
log "istio-system pods:"
kubectl -n istio-system get pods -o wide
log "ztunnel / cni per node:"
kubectl -n istio-system get daemonset istio-cni-node ztunnel

# --- 4. Verify ambient healthy + kgateway still routes ------------------------
log "verifying ztunnel sees workloads:"
istioctl ztunnel-config workload 2>/dev/null | head -20 || warn "ztunnel-config not ready yet"

log "verifying kgateway ingress still serves /.gw/ping through the mesh:"
if retry 15 3 bash -c 'curl -fsS --max-time 5 http://localhost:9090/.gw/ping | grep -qx PONG'; then
  log "plan 02 complete: Istio ambient installed; ingress /.gw/ping still returns 200 PONG"
else
  die "post-install check FAILED: /.gw/ping did not return PONG after enrolling ingress in mesh"
fi
