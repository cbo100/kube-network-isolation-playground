# Plan 07 — Pod-to-pod isolation (L4, workload identity)

## Purpose
Show that isolation can be scoped to a specific **workload identity** (SPIFFE principal),
not just namespace. Enforced by **ztunnel — no waypoint needed**.

## Mechanism
- STRICT mTLS gives each workload a SPIFFE identity:
  `spiffe://cluster.local/ns/<ns>/sa/<serviceaccount>`.
- `AuthorizationPolicy` matching on `from.source.principals`.

## Steps
1. Give the client a dedicated ServiceAccount (identity), e.g. `sa: trusted-client`.
2. Allow only that principal to reach a target (e.g. `ratings` in bookinfo):
   ```yaml
   apiVersion: security.istio.io/v1
   kind: AuthorizationPolicy
   metadata: { name: allow-trusted-client, namespace: bookinfo }
   spec:
     action: ALLOW
     selector: { matchLabels: { app: ratings } }
     rules:
       - from: [{ source: { principals: ["cluster.local/ns/clientspace/sa/trusted-client"] } }]
   ```
3. Deploy two client pods in the same namespace: one with `trusted-client` SA, one with `default`.

## Verify
```sh
# trusted pod allowed:
kubectl -n clientspace exec trusted -- curl -sS --max-time 5 ratings.bookinfo:9080/ratings/0 -o /dev/null -w 'trusted=%{http_code}\n'
# untrusted pod (same ns, different identity) denied:
kubectl -n clientspace exec untrusted -- curl -sS --max-time 5 ratings.bookinfo:9080/ratings/0 -o /dev/null -w 'untrusted=%{http_code}\n' || echo "untrusted=denied (expected)"
```
Confirms isolation is by cryptographic identity, defeating IP/namespace spoofing.

## Next
`plans/08-feature-egress-internet.md`
