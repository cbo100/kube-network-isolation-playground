# Plan 07 — Pod-to-pod isolation (L4, workload identity)

## Purpose
Show that isolation can be scoped to a specific **workload identity** (SPIFFE principal),
not just namespace. Enforced by **ztunnel — no waypoint needed**.

## Mechanism
- STRICT mTLS gives each workload a SPIFFE identity:
  `spiffe://cluster.local/ns/<ns>/sa/<serviceaccount>`.
- A `AuthorizationPolicy` keyed on the source **principal**. Because plan 06 already added a
  namespace-wide ALLOW (clientspace → bookinfo) and Istio ALLOWs are additive (they cannot
  remove access), we tighten a single workload with a **targeted DENY** instead: DENY is
  evaluated before ALLOW (precedence CUSTOM → DENY → ALLOW), so a DENY on `ratings` that
  fires for every principal EXCEPT `trusted-client` yields "only trusted-client may reach
  ratings" — without touching plan 06.

## Steps
Executed by `scripts/07-feature-pod-isolation.sh` (idempotent). Manifest in
`manifests/07-pod-isolation/`.
1. The client pods already carry dedicated ServiceAccounts (plan 04): `trusted` →
   `trusted-client`, `untrusted` → `untrusted-client`, `netshoot` → `default`.
2. Restrict `ratings` to the trusted principal via a targeted DENY:
   ```yaml
   apiVersion: security.istio.io/v1
   kind: AuthorizationPolicy
   metadata: { name: ratings-only-trusted-client, namespace: bookinfo }
   spec:
     action: DENY
     selector: { matchLabels: { app: ratings } }
     rules:
       - from: [{ source: { notPrincipals: ["cluster.local/ns/clientspace/sa/trusted-client"] } }]
   ```

## Verify
```sh
# trusted pod allowed:
kubectl -n clientspace exec trusted   -- curl -sS --max-time 5 ratings.bookinfo:9080/ratings/0 -o /dev/null -w 'trusted=%{http_code}\n'
# untrusted pod (same ns, different identity) denied to ratings:
kubectl -n clientspace exec untrusted -- curl -sS --max-time 5 ratings.bookinfo:9080/ratings/0 -o /dev/null -w 'untrusted=%{http_code}\n' || echo "untrusted=denied (expected)"
# but untrusted still reaches other services (isolation is per-workload, not blanket):
kubectl -n clientspace exec untrusted -- curl -sS --max-time 5 productpage.bookinfo:9080/productpage -o /dev/null -w 'untrusted->productpage=%{http_code}\n'
```
Confirms isolation is by cryptographic identity, defeating IP/namespace spoofing, and is
scoped to a single workload rather than the whole namespace.

## Next
`plans/08-feature-egress-internet.md`
