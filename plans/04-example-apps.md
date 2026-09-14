# Plan 04 — Example apps

## Purpose
Deploy workloads used across the feature demos.

## Apps
- **bookinfo** — Istio's multi-service sample; L7 mesh features + Kiali topology.
- **client pods** — swiss-army test/attacker pods (curl, dig, nc, redis-cli, psql) built as a
  non-root image (`manifests/04-apps/client-image/`) baked with all tools, loaded into kind.
  Three identities in `clientspace`: `netshoot` (generic), `trusted` (SA `trusted-client`),
  `untrusted` (SA `untrusted-client`).
- **redis** + **postgres** — TCP services for L4 service-isolation demos (in `dataspace`).

All app deployments run 2 replicas spread across the worker nodes (topology spread / pod
anti-affinity) so in-mesh traffic exercises more than one node.

## Prerequisites
- Plans 00–02 complete. A container engine (podman or docker) for building the client image.

## Steps
Executed by `scripts/04-example-apps.sh` (idempotent). It:
1. Creates namespaces `bookinfo`/`clientspace`/`dataspace`, enrolled in ambient
   (`istio.io/dataplane-mode=ambient`).
2. Builds the non-root client image and `kind load`s it onto every node.
3. Deploys bookinfo (from the `release-1.31` branch matching pinned istioctl) and an
   HTTPRoute (`bookinfo.localhost` -> `productpage:9080`) + ReferenceGrant so it's
   reachable through the kgateway ingress at `http://bookinfo.localhost:9090/productpage`.
4. Deploys the three client pods + their ServiceAccounts (`clientspace`).
5. Deploys redis + postgres, 2 replicas each, node-spread (`dataspace`).
6. Scales bookinfo frontends to 2 replicas and waits for all rollouts.
7. Verifies node spread and in-mesh reachability.

## Verify
```sh
kubectl get pods -A -o wide | grep -E 'bookinfo|netshoot|redis|postgres'
kubectl -n clientspace exec netshoot -- curl -sS productpage.bookinfo:9080/productpage -o /dev/null -w '%{http_code}\n'
kubectl -n clientspace exec trusted -- redis-cli -h redis.dataspace ping
kubectl -n clientspace exec trusted -- psql postgresql://app:app@postgres.dataspace:5432/app -tAc 'select 1'
```

## Next
`plans/05-security-baseline.md`
