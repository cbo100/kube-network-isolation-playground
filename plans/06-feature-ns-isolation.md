# Plan 06 — Namespace-to-namespace isolation (L4)

## Purpose
Demonstrate that workloads in one namespace cannot reach another namespace unless an
explicit identity-based allow exists. Enforced by **ztunnel — no waypoint needed**.

## Mechanism
- `AuthorizationPolicy` matching on **source namespace** (`from.source.namespaces`) —
  evaluated against the authenticated SPIFFE identity, so it cannot be IP/header-spoofed.
- Layered `NetworkPolicy` (Calico) allowing the same namespace at L3/L4. **Both** layers
  must permit the path, so plan 06 adds an allow to each (the plan-05 baseline denies both).

## Steps
Executed by `scripts/06-feature-ns-isolation.sh` (idempotent). Manifests in
`manifests/06-ns-isolation/`.
1. Create `otherspace` (ambient-enrolled) with a netshoot client — the **negative
   control** that must stay denied.
2. Allow `clientspace -> bookinfo` at the **mesh layer**:
   ```yaml
   apiVersion: security.istio.io/v1
   kind: AuthorizationPolicy
   metadata: { name: allow-clientspace, namespace: bookinfo }
   spec:
     action: ALLOW
     rules:
       - from: [{ source: { namespaces: ["clientspace"] } }]
   ```
3. Allow `clientspace -> bookinfo` at the **CNI layer** (additive `NetworkPolicy` in
   `bookinfo`), since plan 05's baseline otherwise drops it at L3/L4.

## Verify
```sh
# allowed (200):
kubectl -n clientspace exec netshoot -- curl -sS --max-time 5 productpage.bookinfo:9080/productpage -o /dev/null -w 'clientspace=%{http_code}\n'
# denied (reset/timeout) — different namespace, not granted an allow:
kubectl -n otherspace exec netshoot -- curl -sS --max-time 5 productpage.bookinfo:9080/productpage -o /dev/null -w 'otherspace=%{http_code}\n' || echo "otherspace=denied (expected)"
```
Note: the bookinfo **ingress** route stays denied (503) — the allow is for `clientspace`,
not the gateway identity; restoring the ingress with end-user auth is plan 10.

## Next
`plans/07-feature-pod-isolation.md`
