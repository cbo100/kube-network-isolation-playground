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

## Verify
```sh
kubectl -n monitoring get pods
kubectl -n istio-system get pods -l app=kiali

# Prometheus targets (istiod + ztunnels should be health=up):
kubectl -n monitoring port-forward sts/prometheus-monitoring-kube-prometheus-prometheus 9099:9090 &
curl -sS "http://localhost:9099/api/v1/targets?state=active" \
  | jq -r '.data.activeTargets[] | select(.labels.namespace=="istio-system") | "\(.labels.pod)  \(.health)"'

# UIs (port-forward):
kubectl -n monitoring   port-forward svc/monitoring-grafana 3000:80 &     # admin/admin
kubectl -n istio-system port-forward svc/kiali 20001:20001 &
```

## Notes
- The Prometheus container image has no `wget`/`curl`; the script verifies targets via a
  throwaway `curlimages/curl` pod hitting the Prometheus API.
- Optionally expose Grafana/Kiali through the kgateway ingress with `HTTPRoute` later.
- Loki/Tempo (logs/traces) are out of scope for now.

## Next
`plans/04-example-apps.md`
