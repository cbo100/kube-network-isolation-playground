# Plan 01 — kgateway ingress (Gateway API)

## Purpose
Install kgateway as the **north-south ingress** using the Kubernetes Gateway API. Expose it
via the control-plane host-port mappings so apps are reachable at `localhost:9090`.

## Prerequisites
- Plan 00 complete (multi-node cluster Ready).

## Pinned versions
- Gateway API CRDs: `v1.6.1` (standard channel)
- kgateway: `2.4.4` (latest 2.4.x; note the chart tag has **no** `v` prefix), namespace `kgateway-system`

## Run
```sh
./scripts/01-kgateway.sh
```
Idempotent. Installs Gateway API CRDs, kgateway CRDs + control plane (with
`KGW_ENABLE_ISTIO_INTEGRATION=true`), then applies the pinned Gateway.

## How the ingress is exposed on kind
The generated proxy Deployment (`deploy/http`) is pinned to the **control-plane node** via
`GatewayParameters.spec.kube.podTemplate.nodeSelector` + a control-plane toleration, and a
`deploymentOverlay` adds `hostPort: 80` to the `kgateway-proxy` container's `listener-80`
port. kind maps host `:9090 -> node:80`, so the proxy is reachable at `localhost:9090`.
Manifests: `manifests/01-kgateway/gateway.yaml`.

## Steps (performed by the script)
1. Install Gateway API CRDs (idempotent — `apply`):
   ```sh
   kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.1/standard-install.yaml
   ```
2. Install kgateway CRDs chart (`helm upgrade -i` = idempotent):
   ```sh
   helm upgrade -i --create-namespace -n kgateway-system \
     --version 2.4.4 kgateway-crds \
     oci://cr.kgateway.dev/kgateway-dev/charts/kgateway-crds
   ```
3. Install kgateway control plane **with Istio ambient integration enabled up front**:
   ```sh
   helm upgrade -i -n kgateway-system kgateway \
     --version 2.4.4 \
     --set controller.extraEnv.KGW_ENABLE_ISTIO_INTEGRATION=true \
     oci://cr.kgateway.dev/kgateway-dev/charts/kgateway
   ```
4. Apply `manifests/01-kgateway/gateway.yaml` — the `Gateway` (class `kgateway`) plus a
   `GatewayParameters` that pins the proxy to the control-plane node and binds hostPort 80.

## Verify
```sh
kubectl get gatewayclass kgateway                       # ACCEPTED=True
kubectl -n kgateway-system get pods                     # controller + proxy Running
kubectl -n kgateway-system get gateway http             # PROGRAMMED=True

# End-to-end routing check (no backend needed): a kgateway DirectResponse serves
# /.gw/ping -> 200 PONG, attached via an HTTPRoute ExtensionRef filter.
curl -sS -w '\nHTTP %{http_code}\n' http://localhost:9090/.gw/ping   # -> PONG / HTTP 200
```
`200` alone from `/` only proves envoy is up. `/.gw/ping` returning **`200 PONG`** proves
the full path works: kind hostPort -> proxy listener -> HTTPRoute match -> DirectResponse.
Manifest: `manifests/01-kgateway/ping-route.yaml`. The install script runs this check and
fails loudly if it does not return `PONG`.

## Notes / gotchas
- The Gateway's data-plane pod must land on the control-plane node (host-port owner). Use a
  `nodeSelector` targeting the control-plane, or schedule via GatewayParameters.
- `KGW_ENABLE_ISTIO_INTEGRATION=true` makes kgateway honor Istio DestinationRules; harmless
  before Istio is installed, required for plan 02.

## Idempotency
`kubectl apply` and `helm upgrade -i` are re-runnable. Re-running converges state.

## Next
`plans/02-istio-ambient.md`
