# Plan 09 — Pod-to-TCP-service isolation (redis / postgres)

## Purpose
Show identity-based isolation for **non-HTTP TCP services** (databases, caches). Enforced by
**ztunnel at L4 — no waypoint needed** (works for arbitrary TCP).

## Mechanism
- `AuthorizationPolicy` on the target service selecting by **source principal** and
  **destination port** (e.g. 6379 redis, 5432 postgres).
- STRICT mTLS ensures the source principal is authenticated, not spoofable.

## Steps
1. redis + postgres run in `dataspace` (plan 04), ambient-enrolled, default-deny (plan 05).
2. Allow only an approved app identity to redis:
   ```yaml
   apiVersion: security.istio.io/v1
   kind: AuthorizationPolicy
   metadata: { name: allow-redis-client, namespace: dataspace }
   spec:
     action: ALLOW
     selector: { matchLabels: { app: redis } }
     rules:
       - from: [{ source: { principals: ["cluster.local/ns/clientspace/sa/trusted-client"] } }]
         to:   [{ operation: { ports: ["6379"] } }]
   ```

## Verify
```sh
# trusted identity can PING redis:
kubectl -n clientspace exec trusted -- redis-cli -h redis.dataspace ping        # PONG
# untrusted identity blocked at L4 (connection reset/timeout):
kubectl -n clientspace exec untrusted -- redis-cli -h redis.dataspace ping || echo "denied (expected)"
# postgres analog:
kubectl -n clientspace exec trusted -- psql -h postgres.dataspace -U app -c 'select 1' || true
```

## Notes
- This proves mesh isolation is protocol-agnostic (raw TCP), unlike NetworkPolicy which is
  IP/port only — here it is cryptographic identity.

## Next
`plans/10-feature-auth-identity.md`
