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
# NOTE: no --wait here. The default CNI is disabled (see kind/cluster.yaml), so nodes
# stay NotReady until Calico is installed below; waiting for Ready now would time out.
if [ -n "${K8S_NODE_IMAGE}" ]; then
  kind create cluster --name "$CLUSTER_NAME" --config "$CONFIG" --image "$K8S_NODE_IMAGE"
else
  kind create cluster --name "$CLUSTER_NAME" --config "$CONFIG"
fi

# --- context ------------------------------------------------------------------
kubectl config use-context "$KIND_CONTEXT" >/dev/null
log "using context: $KIND_CONTEXT"

# --- CNI: Calico --------------------------------------------------------------
# kind's default CNI (kindnet) is disabled in kind/cluster.yaml because it does not
# enforce NetworkPolicy. Install Calico so plan 05's baseline NetworkPolicies are
# actually enforced. Nodes stay NotReady until the CNI is up.
log "installing Calico ${CALICO_VERSION} (operator + custom resources)"
kubectl apply --server-side -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml"

log "waiting for tigera-operator to be ready"
retry 30 5 kubectl -n tigera-operator rollout status deploy/tigera-operator --timeout=20s

log "configuring Calico Installation (pod CIDR ${POD_SUBNET})"
kubectl apply -f - <<EOF
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    ipPools:
      - name: default-ipv4-ippool
        cidr: ${POD_SUBNET}
        encapsulation: VXLANCrossSubnet
        natOutgoing: Enabled
        nodeSelector: all()
---
apiVersion: operator.tigera.io/v1
kind: APIServer
metadata:
  name: default
spec: {}
EOF

log "waiting for Calico to program the dataplane (calico-node DaemonSet)"
retry 60 5 kubectl -n calico-system rollout status ds/calico-node --timeout=20s

# --- wait for all nodes Ready -------------------------------------------------
log "waiting for all nodes to become Ready"
retry 30 5 kubectl wait --for=condition=Ready nodes --all --timeout=20s

# --- report -------------------------------------------------------------------
log "nodes:"
kubectl get nodes -o wide

log "control-plane host port mappings (ingress reachability):"
docker ps --filter "name=${CLUSTER_NAME}-control-plane" --format '{{.Names}}\t{{.Ports}}'

log "plan 00 complete. host :9090 -> :80 and host :9443 -> :443 map to the control-plane node."
