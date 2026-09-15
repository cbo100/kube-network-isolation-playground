# Plan 09 — Pod-to-TCP-service isolation (redis / postgres)

## Purpose
Show identity-based isolation for **non-HTTP TCP services** (databases, caches). Enforced by
**ztunnel at L4 — no waypoint needed** (works for arbitrary TCP).

## Mechanism
- `AuthorizationPolicy` on the target service selecting by **source principal** and
  **destination port** (6379 redis, 5432 postgres). Enforced by ztunnel at L4.
- STRICT mTLS (plan 05) makes the source principal authenticated, not spoofable.
- A layered `NetworkPolicy` opens the L3/L4 path `clientspace -> dataspace` (plan 05's
  dataspace baseline drops it at the CNI, so both layers must permit it).

## The matrix
| source \ service | redis:6379 | postgres:5432 |
|---|---|---|
| **trusted-client** | allow | allow |
| **untrusted-client** (same ns) | deny | deny |
| **netshoot** / any other identity | deny | deny |

## Steps
Executed by `scripts/09-feature-tcp-service.sh` (idempotent). Manifests in
`manifests/09-tcp-service/`. redis + postgres run in `dataspace` (plan 04), ambient-enrolled,
default-deny (plan 05).
1. Open `clientspace -> dataspace` at the CNI layer (additive `NetworkPolicy`).
2. Allow ONLY `trusted-client` to each service, port-scoped:
   ```yaml
   apiVersion: security.istio.io/v1
   kind: AuthorizationPolicy
   metadata: { name: allow-redis-trusted-client, namespace: dataspace }
   spec:
     action: ALLOW
     selector: { matchLabels: { app: redis } }
     rules:
       - from: [{ source: { principals: ["cluster.local/ns/clientspace/sa/trusted-client"] } }]
         to:   [{ operation: { ports: ["6379"] } }]
   # ...and an analogous policy for postgres on 5432.
   ```

## Verify
```sh
# trusted identity can reach BOTH services:
kubectl -n clientspace exec trusted   -- redis-cli -h redis.dataspace ping                                   # PONG
kubectl -n clientspace exec trusted   -- psql "postgresql://app:app@postgres.dataspace:5432/app" -tAc 'select 1'  # 1
# untrusted identity (same ns) blocked at L4 (connection reset):
kubectl -n clientspace exec untrusted -- redis-cli -h redis.dataspace ping || echo "denied (expected)"
kubectl -n clientspace exec untrusted -- psql "postgresql://app:app@postgres.dataspace:5432/app" -tAc 'select 1' || echo "denied (expected)"
```

## Notes
- Proves mesh isolation is protocol-agnostic (raw TCP), unlike NetworkPolicy which is
  IP/port only — here it is cryptographic identity, and **no waypoint is needed** (ztunnel
  handles L4 principal+port rules directly; waypoints are only for L7).
- `to.operation.ports` scopes the grant to the service port (least privilege): if the pod
  exposed another port (metrics/admin), it would NOT be covered by this allow.

## Next
`plans/10-feature-auth-identity.md`
