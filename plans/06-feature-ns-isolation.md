# Plan 06 — Namespace-to-namespace isolation (L4)

## Purpose
Demonstrate that workloads in one namespace cannot reach another namespace unless an
explicit identity-based allow exists. Enforced by **ztunnel — no waypoint needed**.

## Mechanism
- `AuthorizationPolicy` matching on **source namespace** (`from.source.namespaces`).
- Layered `NetworkPolicy` selecting by namespace label.

## Steps
1. With default-deny (plan 05) in `bookinfo`, add an allow for only `clientspace`:
   ```yaml
   apiVersion: security.istio.io/v1
   kind: AuthorizationPolicy
   metadata: { name: allow-clientspace, namespace: bookinfo }
   spec:
     action: ALLOW
     rules:
       - from: [{ source: { namespaces: ["clientspace"] } }]
   ```
2. Create a second namespace `otherspace` (ambient-enrolled) with a netshoot pod.

## Verify
```sh
# allowed:
kubectl -n clientspace exec netshoot -- curl -sS --max-time 5 productpage.bookinfo:9080/productpage -o /dev/null -w 'clientspace=%{http_code}\n'
# denied (different namespace):
kubectl -n otherspace exec netshoot -- curl -sS --max-time 5 productpage.bookinfo:9080/productpage -o /dev/null -w 'otherspace=%{http_code}\n' || echo "otherspace=denied (expected)"
```

## Next
`plans/07-feature-pod-isolation.md`
