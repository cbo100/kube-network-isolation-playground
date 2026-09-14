# Plan 04 — Example apps

## Purpose
Deploy workloads used across the feature demos.

## Apps
- **bookinfo** — Istio's multi-service sample; L7 mesh features + Kiali topology.
- **netshoot** — swiss-army test/attacker pod (curl, dig, nc, psql client, redis-cli).
- **redis** + **postgres** — TCP services for L4 service-isolation demos.

## Prerequisites
- Plans 00–02 complete.

## Steps
1. Namespaces (enrolled in ambient):
   ```sh
   for ns in bookinfo clientspace dataspace; do
     kubectl create ns "$ns" --dry-run=client -o yaml | kubectl apply -f -
     kubectl label ns "$ns" istio.io/dataplane-mode=ambient --overwrite
   done
   ```
2. Bookinfo:
   ```sh
   kubectl -n bookinfo apply -f https://raw.githubusercontent.com/istio/istio/release-1.31/samples/bookinfo/platform/kube/bookinfo.yaml
   ```
3. netshoot client (in `clientspace`):
   ```sh
   kubectl -n clientspace run netshoot --image=nicolaka/netshoot -- sleep infinity
   ```
4. redis + postgres (in `dataspace`) — manifests in `manifests/04-apps/` when executed.

## Verify
```sh
kubectl get pods -A -o wide | grep -E 'bookinfo|netshoot|redis|postgres'
kubectl -n clientspace exec netshoot -- curl -sS productpage.bookinfo:9080/productpage -o /dev/null -w '%{http_code}\n'
```

## Next
`plans/05-security-baseline.md`
