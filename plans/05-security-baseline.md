# Plan 05 — Security baseline

## Purpose
Establish a mesh-wide secure default before layering per-feature policies: STRICT mTLS and
a default-deny authorization posture, plus baseline Kubernetes NetworkPolicy for
defense-in-depth.

## Prerequisites
- Plans 00–04 complete.

## Steps
Executed by `scripts/05-security-baseline.sh` (idempotent). Manifests in `manifests/05-baseline/`.
1. Enforce STRICT mTLS mesh-wide (`PeerAuthentication` in `istio-system`), **plus a scoped
   exception**: a workload `PeerAuthentication` in `kgateway-system` sets the ingress
   gateway's listener port (`80`) to `PERMISSIVE`. This is required because the gateway pod
   is ambient-enrolled but receives plaintext traffic from OUTSIDE the mesh (host hostPort);
   a blanket STRICT policy otherwise rejects that inbound and kills all ingress (even
   `/.gw/ping`). The gateway's *upstream* calls to app pods remain mTLS.
2. Default-deny authorization per app namespace (empty-spec `AuthorizationPolicy` denies all).
   Enforced by ztunnel at L4 — denials surface as **connection resets**, not HTTP 403.
   Then add explicit ALLOW policies per feature plan.
3. Baseline `NetworkPolicy` (Calico-enforced; see plan 00) per app namespace:
   default-deny **ingress** (allow same-namespace, plus `kgateway-system` -> `bookinfo`),
   with **egress left open**. Egress is intentionally not restricted — a default-deny egress
   easily severs DNS and the ztunnel HBONE data path; the ingress-deny + mesh authz provide
   the isolation the demos need. This is the L3/L4 half; the mesh authz is the identity half.

## Verify
```sh
istioctl analyze -A
# cross-namespace call is now reset (no HTTP response) until an explicit allow exists:
kubectl -n clientspace exec netshoot -- curl -sS --max-time 5 productpage.bookinfo:9080/productpage -o /dev/null -w '%{http_code}\n' || echo "denied (expected)"
# bookinfo ingress returns 503 (upstream denied by mesh authz):
curl -sS -o /dev/null -w '%{http_code}\n' -H 'Host: bookinfo.localhost' http://localhost:9090/productpage
# unaffected: gateway health + observability UIs still work:
curl -sS http://localhost:9090/.gw/ping
```

## Notes
- Default-deny is the foundation for plans 06–10; each feature plan adds the minimal ALLOW.
- Manifests in `manifests/05-baseline/` when executed.

## Optional: bring the monitoring tooling into the mesh
Entirely optional, but a nice extension — govern the observability stack with the same
mesh controls it observes:
```sh
kubectl label ns monitoring istio.io/dataplane-mode=ambient --overwrite
```
- Gives Grafana/Prometheus/Alertmanager SPIFFE identities + transparent mTLS (L4).
- Then restrict the UIs with an `AuthorizationPolicy` (e.g. only the kgateway ingress
  identity may reach them), demonstrating isolation applied to the tooling itself.
- Verify Prometheus targets stay `health=up` after enrollment (plan 03's check covers this).
- Do **not** enroll `istio-system` (istiod/ztunnel are the dataplane; leave them unlabeled).
- L7 policy on the UI routes would additionally require a waypoint (same rule as the feature
  plans).

## Next
`plans/06-feature-ns-isolation.md`
