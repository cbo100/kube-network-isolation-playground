# Plan 01 — kgateway ingress (Gateway API)

## Purpose
Install kgateway as the **north-south ingress** using the Kubernetes Gateway API. Expose it
via the control-plane host-port mappings so apps are reachable at `localhost:9090`.

## Prerequisites
- Plan 00 complete (multi-node cluster Ready).

## Pinned versions
- Gateway API CRDs: `v1.6.1` (standard channel)
- kgateway: `v2.4.3` (namespace `kgateway-system`)

## Steps
1. Install Gateway API CRDs (idempotent — `apply`):
   ```sh
   kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.1/standard-install.yaml
   ```
2. Install kgateway CRDs chart (`helm upgrade -i` = idempotent):
   ```sh
   helm upgrade -i --create-namespace -n kgateway-system \
     --version v2.4.3 kgateway-crds \
     oci://cr.kgateway.dev/kgateway-dev/charts/kgateway-crds
   ```
3. Install kgateway control plane **with Istio ambient integration enabled up front**:
   ```sh
   helm upgrade -i -n kgateway-system kgateway \
     --version v2.4.3 \
     --set controller.extraEnv.KGW_ENABLE_ISTIO_INTEGRATION=true \
     oci://cr.kgateway.dev/kgateway-dev/charts/kgateway
   ```
4. Create a `Gateway` (gatewayClassName `kgateway`) and **pin it to the control-plane node**
   so it binds the mapped host ports. Provide a `Deployment` patch / `nodeSelector` via the
   gateway parameters or a `kgateway` GatewayParameters/patch. (Manifests live in
   `manifests/01-kgateway/` — created when this plan is executed.)

## Verify
```sh
kubectl get gatewayclass kgateway                       # ACCEPTED=True
kubectl -n kgateway-system get pods                     # controller Running
kubectl get gateway -A                                  # PROGRAMMED=True, ADDRESS assigned
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:9090/  # reachable (404 ok pre-routes)
```

## Notes / gotchas
- The Gateway's data-plane pod must land on the control-plane node (host-port owner). Use a
  `nodeSelector` targeting the control-plane, or schedule via GatewayParameters.
- `KGW_ENABLE_ISTIO_INTEGRATION=true` makes kgateway honor Istio DestinationRules; harmless
  before Istio is installed, required for plan 02.

## Idempotency
`kubectl apply` and `helm upgrade -i` are re-runnable. Re-running converges state.

## Next
`plans/02-istio-ambient.md`
