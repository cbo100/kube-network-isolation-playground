#!/usr/bin/env bash
# Plan 00 — (re)create the multi-node kind cluster.
# Idempotent: safe to run repeatedly. Deletes an existing cluster of the same name
# and recreates it from kind/cluster.yaml, then waits until all nodes are Ready.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

need kind
need kubectl
need docker

CONFIG="${REPO_ROOT}/kind/cluster.yaml"
[ -f "$CONFIG" ] || die "missing kind config: $CONFIG"

log "kind version: $(kind version)"

# --- (re)create ---------------------------------------------------------------
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  warn "cluster '${CLUSTER_NAME}' exists — deleting for a clean, repeatable rebuild"
  kind delete cluster --name "$CLUSTER_NAME"
fi

log "creating multi-node cluster '${CLUSTER_NAME}' (1 control-plane + 2 workers)"
if [ -n "${K8S_NODE_IMAGE}" ]; then
  kind create cluster --name "$CLUSTER_NAME" --config "$CONFIG" --image "$K8S_NODE_IMAGE" --wait 120s
else
  kind create cluster --name "$CLUSTER_NAME" --config "$CONFIG" --wait 120s
fi

# --- context ------------------------------------------------------------------
kubectl config use-context "$KIND_CONTEXT" >/dev/null
log "using context: $KIND_CONTEXT"

# --- wait for all nodes Ready -------------------------------------------------
log "waiting for all nodes to become Ready"
retry 30 5 kubectl wait --for=condition=Ready nodes --all --timeout=20s

# --- report -------------------------------------------------------------------
log "nodes:"
kubectl get nodes -o wide

log "control-plane host port mappings (ingress reachability):"
docker ps --filter "name=${CLUSTER_NAME}-control-plane" --format '{{.Names}}\t{{.Ports}}'

log "plan 00 complete. host :9090 -> :80 and host :9443 -> :443 map to the control-plane node."
