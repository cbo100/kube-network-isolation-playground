# Plan 08 — Pod-to-internet (egress) isolation

## Purpose
Restrict which external destinations a pod may reach (block arbitrary websites; allow only
an approved list).

## Mechanism (two complementary layers)
1. **Kubernetes NetworkPolicy egress** — L3/L4 default-deny egress, allow DNS + specific CIDRs.
2. **Istio egress control** — `ServiceEntry` to model approved external hosts; optional
   **egress waypoint** for L7 (host/path) egress policy (waypoint required for L7).

## Steps
1. Default-deny egress in `clientspace` (allow kube-dns):
   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata: { name: default-deny-egress, namespace: clientspace }
   spec:
     podSelector: {}
     policyTypes: [Egress]
     egress:
       - to: []                       # allow DNS to kube-system
         ports: [{ protocol: UDP, port: 53 }, { protocol: TCP, port: 53 }]
   ```
2. Add an allow for one approved host via `ServiceEntry` + (optional) egress waypoint L7 authz.

## Verify
```sh
# arbitrary site blocked:
kubectl -n clientspace exec netshoot -- curl -sS --max-time 5 https://example.com -o /dev/null -w 'example=%{http_code}\n' || echo "example=blocked (expected)"
# approved host allowed (after allow rule):
kubectl -n clientspace exec netshoot -- curl -sS --max-time 5 https://<approved-host>/ -o /dev/null -w 'approved=%{http_code}\n'
```

## Notes
- NetworkPolicy egress here relies on kindnet supporting policy; if enforcement is absent,
  demonstrate egress control via Istio `ServiceEntry` with `outboundTrafficPolicy: REGISTRY_ONLY`.
- L7 egress (per-URL) requires an **egress waypoint**.

## Next
`plans/09-feature-tcp-service.md`
