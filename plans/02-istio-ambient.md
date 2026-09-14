# Plan 02 — Istio ambient mesh

## Purpose
Install the Istio **ambient** dataplane (ztunnel + istio-cni) for transparent east-west
mTLS and workload identity, and integrate it with the kgateway ingress from plan 01.

## Prerequisites
- Plans 00–01 complete.
- `istioctl` (`v1.31.x`) installed. If missing:
  ```sh
  curl -L https://istio.io/downloadIstio | ISTIO_VERSION=1.31.0 sh -
  export PATH="$PWD/istio-1.31.0/bin:$PATH"
  ```

## Steps
1. Install ambient profile (idempotent — converges):
   ```sh
   istioctl install --set profile=ambient --skip-confirmation
   ```
   Installs `base`, `istiod`, `istio-cni` (node agent), and `ztunnel`.
2. Add the ingress namespace to the mesh so **gateway → app** traffic is mTLS via ztunnel:
   ```sh
   kubectl label ns kgateway-system istio.io/dataplane-mode=ambient --overwrite
   ```
3. App namespaces are enrolled per-demo in later plans:
   ```sh
   kubectl label ns <ns> istio.io/dataplane-mode=ambient --overwrite
   ```

## Verify
```sh
istioctl version
kubectl -n istio-system get pods            # istiod Running
kubectl get daemonset -n istio-system       # istio-cni-node + ztunnel on every node
istioctl ztunnel-config workload            # workloads listed with identities
```

## Notes / gotchas
- **kind is supported** for ambient. istio-cni runs alongside the kind (kindnet) CNI.
- Check platform prerequisites if ztunnel/cni crashloop:
  https://istio.io/latest/docs/ambient/install/platform-prerequisites/
- **L4 vs L7:** ztunnel enforces L4 (identity, ns, ports) + mTLS **without** a waypoint.
  L7 policy and JWT need a **waypoint** (plan 10). An L7 rule on a ztunnel-only path
  fails safe to DENY.

## Idempotency
`istioctl install` and `kubectl label --overwrite` are re-runnable.

## Next
`plans/03-monitoring.md`
