# Plan 00 — Multi-node kind cluster

## Purpose
Create a repeatable, multi-node local Kubernetes cluster to host the mesh and demos.
Topology: **1 control-plane + 2 workers**. Ingress host ports (`9090->80`, `9443->443`)
are mapped on the control-plane node; the kgateway Gateway is later pinned there so the
mappings always resolve.

## Prerequisites
- `kind` (v0.33+), `kubectl`, `docker` running.
- No conflicting process bound to host ports **9090** / **9443**.

## Files
- `kind/cluster.yaml` — cluster topology + control-plane `extraPortMappings`; the default
  CNI is disabled here (`disableDefaultCNI: true`) so Calico can be installed instead.
- `scripts/00-cluster.sh` — idempotent create/recreate, Calico CNI install, readiness wait.
- `scripts/lib.sh` — shared helpers and pinned versions.

## Run
```sh
./scripts/00-cluster.sh
```
The script is **idempotent**: if a cluster named `cluster` exists it is deleted and
recreated from config, guaranteeing a clean, reproducible state every run.

## Verify
```sh
kubectl config use-context kind-cluster
kubectl get nodes -o wide            # expect 1 control-plane + 2 workers, all Ready
docker ps --filter name=cluster-control-plane --format '{{.Ports}}'  # 9090->80, 9443->443
```

## Notes / gotchas
- Node image: the script pins **`kindest/node:v1.37.0`** by digest — the highest
  Kubernetes version pre-built for kind v0.33.0, for reproducibility. Override by exporting
  `K8S_NODE_IMAGE=kindest/node:vX.Y.Z@sha256:...` before running.
- Only the control-plane node carries the host-port mappings; ingress workloads must be
  scheduled there (handled in plan 01 via `nodeSelector`/pinning).
- **CNI = Calico** (pinned `CALICO_VERSION` in `lib.sh`): kind's default kindnet does **not**
  enforce Kubernetes NetworkPolicy, so it is disabled and Calico is installed via the tigera
  operator. This makes plan 05's baseline NetworkPolicies actually enforced. Nodes remain
  `NotReady` until Calico programs the dataplane — expected during bootstrap.

## Next
`plans/01-kgateway.md`
