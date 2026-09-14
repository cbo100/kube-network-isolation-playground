# Plan 03 — Monitoring (Prometheus + Grafana + Kiali)

## Purpose
Observe cluster + mesh: metrics/dashboards via `kube-prometheus-stack`, and mesh topology
+ policy visualization via **Kiali**. Prometheus is wired to scrape Istio ambient metrics
(istiod + ztunnel).

## Prerequisites
- Plans 00–02 complete (Kiali + the Istio scrape configs need the mesh installed).

## Pinned versions
- kube-prometheus-stack: `91.2.3`
- kiali-server: `2.31.0`

## Run
```sh
./scripts/03-monitoring.sh
```
Idempotent. Installs the stack + Kiali (values files), applies Istio PodMonitors, and
verifies Prometheus is scraping istiod.

## What it installs
- **kube-prometheus-stack** in `monitoring` (Prometheus, Grafana, Alertmanager, operator,
  kube-state-metrics, node-exporter). Values:
  `manifests/03-monitoring/kube-prometheus-stack.values.yaml`
  (cluster-wide monitor discovery, 6h retention, grafana admin/admin).
- **Istio scrape config**: `manifests/03-monitoring/istio-podmonitors.yaml` — PodMonitors
  for `istiod` (port 15014 `/metrics`) and `ztunnel` (port 15020 `/stats/prometheus`).
- **Kiali** in `istio-system`, anonymous auth, pointed at the in-cluster Prometheus/Grafana.
  Values: `manifests/03-monitoring/kiali.values.yaml`.

## UIs (via the kgateway ingress)
All four UIs are exposed through the ingress at `localhost:9090` using host-based
`HTTPRoute`s (`manifests/03-monitoring/ui-routes.yaml`). On macOS, `*.localhost` resolves to
`127.0.0.1` automatically — just open:

| UI           | URL                                   | Notes            |
|--------------|---------------------------------------|------------------|
| Grafana      | http://grafana.localhost:9090         | login admin/admin |
| Prometheus   | http://prometheus.localhost:9090      |                  |
| Alertmanager | http://alertmanager.localhost:9090    |                  |
| Kiali        | http://kiali.localhost:9090           | mesh topology    |

Cross-namespace routing (Gateway in `kgateway-system` → Services in `monitoring` /
`istio-system`) is permitted by `ReferenceGrant`s in each backend namespace.
Grafana `root_url` and Kiali `web_root: /` are set so they serve correctly at the host root.

## Verify
```sh
kubectl -n monitoring get pods
kubectl -n istio-system get pods -l app=kiali

# Prometheus targets (istiod + ztunnels should be health=up):
kubectl -n monitoring port-forward sts/prometheus-monitoring-kube-prometheus-prometheus 9099:9090 &
curl -sS "http://localhost:9099/api/v1/targets?state=active" \
  | jq -r '.data.activeTargets[] | select(.labels.namespace=="istio-system") | "\(.labels.pod)  \(.health)"'

# UIs through the ingress:
curl -sSI http://grafana.localhost:9090/login
open http://kiali.localhost:9090      # macOS
```

## Notes
- The Prometheus container image has no `wget`/`curl`; the script verifies targets via a
  throwaway `curlimages/curl` pod hitting the Prometheus API.
- Optionally expose Grafana/Kiali through the kgateway ingress with `HTTPRoute` later.
- Loki/Tempo (logs/traces) are out of scope for now.

## Next
`plans/04-example-apps.md`
