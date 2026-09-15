# Plan 08 — Pod-to-internet (egress) isolation

## Purpose
Restrict which external destinations a pod may reach (block arbitrary websites; allow only
an approved list). Covers **external TCP services outside the cluster**, not just websites.

## Motivating tests (real targets)
Two concrete external targets exercise both a raw-TCP service and HTTP/S:
- **Raw TCP:** an external DNS server at **`192.168.1.1:53`**.
- **HTTP/S:** an approved website vs. an arbitrary one — e.g. allow **`example.com:443`**
  but block everything else on the internet.

As of plan 06, egress is completely **uncontrolled**: `trusted`, `untrusted`, and
`otherspace` can all freely open TCP to `192.168.1.1:53` AND reach `https://example.com`
(observed: HTTP 200 from every pod). This plan gates both.

## Why the earlier plans do NOT cover this (important)
- **Istio AuthorizationPolicy / mTLS gate in-mesh traffic only.** An external IP like
  `192.168.1.1` is not a mesh workload — it has no SPIFFE identity — so ztunnel authz is
  simply not in the egress path and cannot gate it.
- **Plans 05/06 left `NetworkPolicy` egress OPEN** (`egress: [{}]`) on purpose, to avoid
  breaking DNS/HBONE. So nothing currently blocks outbound to external IPs.
Egress control is therefore a distinct, additive layer — this plan.

## Mechanism (two complementary layers)
1. **Kubernetes NetworkPolicy egress (Calico-enforced)** — the primary tool here. Flip the
   namespace to **default-deny egress**, then allow only: DNS to kube-dns, the ztunnel/node
   path, and the approved external CIDR+port (e.g. `192.168.1.1/32:53`) for **specific pods**
   by label (e.g. only `trusted`). Gates on pod label + destination IP/port.
2. **Istio egress control** — `ServiceEntry` to model approved external hosts, optionally
   `outboundTrafficPolicy: REGISTRY_ONLY`; an **egress waypoint** for L7 (host/path) policy.

## Steps
1. Default-deny egress in `clientspace`, allowing DNS to kube-dns + the ztunnel/node path
   (must NOT sever the ambient dataplane — same lesson as plan 05):
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
2. Allow ONLY the approved pod to the approved external target:
   ```yaml
   # allow just the 'trusted' pod to reach the external DNS at 192.168.1.1:53
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata: { name: allow-external-dns, namespace: clientspace }
   spec:
     podSelector: { matchLabels: { app: trusted } }
     policyTypes: [Egress]
     egress:
       - to: [{ ipBlock: { cidr: 192.168.1.1/32 } }]
         ports: [{ protocol: TCP, port: 53 }, { protocol: UDP, port: 53 }]
   ```

### HTTP/S egress — two approaches (choose per how tight you need it)

**A. L3/L4 by CIDR (simple, NetworkPolicy only).** Allow `trusted` to reach HTTPS on
`443`. Note the limitation: NetworkPolicy matches **IP/CIDR**, not hostnames, so you must
allow the destination's resolved IP range(s). Good enough to say "may reach the internet on
443" or "may reach this fixed IP block", but it cannot express "only example.com".
   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata: { name: allow-https-egress, namespace: clientspace }
   spec:
     podSelector: { matchLabels: { app: trusted } }
     policyTypes: [Egress]
     egress:
       - to: [{ ipBlock: { cidr: 0.0.0.0/0 } }]   # or a tighter CIDR for the approved host
         ports: [{ protocol: TCP, port: 443 }]
   ```

**B. L7 by hostname (tight, Istio egress waypoint).** To actually restrict egress to a
specific **host** (`example.com`) rather than an IP range, model the host as a
`ServiceEntry`, set the mesh to registry-only egress, and attach an **egress waypoint** with
an `AuthorizationPolicy` matching the SNI/Host. The waypoint is REQUIRED for L7 host/path
egress rules (same rule as ingress L7).
   ```yaml
   apiVersion: networking.istio.io/v1
   kind: ServiceEntry
   metadata: { name: example-com, namespace: clientspace }
   spec:
     hosts: ["example.com"]
     ports: [{ number: 443, name: https, protocol: TLS }]
     resolution: DNS
     location: MESH_EXTERNAL
   ---
   # deploy an egress waypoint for clientspace, then an L7 AuthorizationPolicy on it that
   # allows host example.com and denies all other external hosts. (outboundTrafficPolicy
   # REGISTRY_ONLY at the mesh level blocks any host without a ServiceEntry.)
   ```

3. (Optional) Combine both: NetworkPolicy for coarse L3/L4 egress + ServiceEntry/waypoint for
   precise per-host L7 egress authz.

## Verify
```sh
# --- raw TCP (external DNS) ---
# allowed for the approved pod (trusted):
kubectl -n clientspace exec trusted   -- sh -c 'dig +time=3 +tries=1 @192.168.1.1 example.com +short'   # resolves
# blocked for a non-approved pod (untrusted / otherspace):
kubectl -n clientspace exec untrusted -- sh -c 'nc -zv -w3 192.168.1.1 53' || echo "blocked (expected)"

# --- HTTP/S egress ---
# approved host reachable from the approved pod:
kubectl -n clientspace exec trusted   -- curl -sS --max-time 6 https://example.com -o /dev/null -w 'trusted->example=%{http_code}\n'
# blocked from a non-approved pod (default-deny egress):
kubectl -n clientspace exec untrusted -- curl -sS --max-time 6 https://example.com -o /dev/null -w 'untrusted->example=%{http_code}\n' || echo "untrusted->example=blocked (expected)"
# with the L7 waypoint (approach B): a DIFFERENT, non-approved host is blocked even from trusted:
kubectl -n clientspace exec trusted   -- curl -sS --max-time 6 https://www.wikipedia.org -o /dev/null -w 'trusted->other=%{http_code}\n' || echo "trusted->other=blocked (expected, L7)"
```

## Notes
- NetworkPolicy egress enforcement is REAL here because the cluster runs **Calico** (plan 00);
  the earlier "kindnet may not enforce policy" caveat no longer applies.
- **L3/L4 vs L7 egress — the key distinction:**
  - Raw external TCP (DNS on `:53`, or "HTTPS on `:443` to this CIDR") is fully covered by the
    Calico egress NetworkPolicy (approach A). It matches **IP/CIDR + port**, not hostnames.
  - "Only `example.com`, block every other website" is a **hostname/L7** rule. NetworkPolicy
    cannot express it (it can't see SNI/Host); use the Istio `ServiceEntry` + **egress
    waypoint** (approach B). L7 egress per-host/URL always requires a waypoint.
- Careful with default-deny egress + ambient: allow DNS and the ztunnel/node path or you will
  sever the dataplane (same failure mode seen in plan 05).

## Next
`plans/09-feature-tcp-service.md`
