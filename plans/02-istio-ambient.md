# Plan 02 — Istio ambient mesh

## Purpose
Install the Istio **ambient** dataplane (ztunnel + istio-cni) for transparent east-west
mTLS and workload identity, and integrate it with the kgateway ingress from plan 01.

## Prerequisites
- Plans 00–01 complete.
- `mise` installed. `istioctl` (pinned to `1.31.0` in `mise.toml`) is provided by mise —
  no manual download. The script runs `mise install` then `mise exec -- istioctl ...`.

## Run
```sh
./scripts/02-istio-ambient.sh
```
Idempotent. Installs the ambient profile, waits for istiod/cni/ztunnel, enrolls
`kgateway-system`, and re-checks that the ingress `/.gw/ping` still returns `200 PONG`.

## Steps (performed by the script)
1. Install ambient profile:
   ```sh
   istioctl install --set profile=ambient --skip-confirmation
   ```
   Installs `base`, `istiod`, `istio-cni` (node agent), and `ztunnel`.
2. Add the ingress namespace to the mesh so **gateway -> app** traffic is mTLS via ztunnel:
   ```sh
   kubectl label ns kgateway-system istio.io/dataplane-mode=ambient --overwrite
   ```
3. App namespaces are enrolled per-demo in later plans:
   ```sh
   kubectl label ns <ns> istio.io/dataplane-mode=ambient --overwrite
   ```

## Verify
```sh
mise exec -- istioctl version
kubectl -n istio-system get pods                       # istiod Running
kubectl -n istio-system get daemonset istio-cni-node ztunnel   # both on every node
mise exec -- istioctl ztunnel-config workload          # workloads listed; enrolled ns show HBONE
curl -sS http://localhost:9090/.gw/ping                # still 200 PONG (no ingress regression)
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
