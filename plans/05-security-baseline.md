# Plan 05 — Security baseline

## Purpose
Establish a mesh-wide secure default before layering per-feature policies: STRICT mTLS and
a default-deny authorization posture, plus baseline Kubernetes NetworkPolicy for
defense-in-depth.

## Prerequisites
- Plans 00–04 complete.

## Steps
1. Enforce STRICT mTLS mesh-wide (ztunnel):
   ```yaml
   apiVersion: security.istio.io/v1
   kind: PeerAuthentication
   metadata: { name: default, namespace: istio-system }
   spec: { mtls: { mode: STRICT } }
   ```
2. Default-deny authorization per app namespace (empty-spec AuthorizationPolicy denies all):
   ```yaml
   apiVersion: security.istio.io/v1
   kind: AuthorizationPolicy
   metadata: { name: default-deny, namespace: <ns> }
   spec: {}
   ```
   Then add explicit ALLOW policies per feature plan.
3. Baseline `NetworkPolicy` default-deny ingress/egress per app namespace (L3/L4 belt-and-braces).

## Verify
```sh
istioctl analyze -A
# cross-namespace call should now fail until an explicit allow exists:
kubectl -n clientspace exec netshoot -- curl -sS --max-time 5 productpage.bookinfo:9080/productpage -o /dev/null -w '%{http_code}\n' || echo "denied (expected)"
```

## Notes
- Default-deny is the foundation for plans 06–10; each feature plan adds the minimal ALLOW.
- Manifests in `manifests/05-baseline/` when executed.

## Next
`plans/06-feature-ns-isolation.md`
