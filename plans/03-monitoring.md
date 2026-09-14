# Plan 03 — Monitoring (Prometheus + Grafana + Kiali)

## Purpose
Observe cluster + mesh: metrics/dashboards via `kube-prometheus-stack`, and mesh topology
+ policy visualization via **Kiali**.

## Prerequisites
- Plans 00–02 complete (Kiali wants Istio metrics).

## Steps
1. kube-prometheus-stack (idempotent):
   ```sh
   helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
   helm repo update
   helm upgrade -i monitoring prometheus-community/kube-prometheus-stack \
     --create-namespace -n monitoring
   ```
2. Istio addons — Prometheus scrape config + Kiali:
   ```sh
   kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.31/samples/addons/kiali.yaml
   ```
   (Point Kiali at the kube-prometheus-stack Prometheus service if not using the bundled one.)

## Verify
```sh
kubectl -n monitoring get pods
kubectl -n istio-system get deploy kiali
# port-forward to view:
kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80 &
kubectl -n istio-system port-forward svc/kiali 20001:20001 &
```

## Notes
- Optionally expose Grafana/Kiali through the kgateway ingress with `HTTPRoute` instead of
  port-forward.
- Loki/Tempo (logs/traces) are out of scope for now; can be layered later.

## Next
`plans/04-example-apps.md`
