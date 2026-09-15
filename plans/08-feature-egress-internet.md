# Plan 08 — Pod-to-internet (egress) isolation

## Purpose
Restrict which external destinations a pod may reach, by **workload identity**, with a
**per-service access matrix** — different identities get different external services. Covers
**raw external TCP** and **HTTP/S**.

## The matrix (goal state)
Three declared external services, two client identities:

| source \ service | tcpbin.com:4242 (TCP) | example.com:443 (HTTPS) | en.wikipedia.org:443 (HTTPS) |
|---|---|---|---|
| **trusted-client** | allow | allow | deny |
| **untrusted-client** | deny | deny | allow |
| any other in-mesh pod | deny | deny | deny |

So `trusted` may reach 2 services, `untrusted` exactly 1, and everyone else none.

As of plan 06, egress is completely **uncontrolled**: every pod can freely reach all of
these (observed: echo works and HTTP 200 from every pod). This plan gates them per the matrix.

## What did NOT work in ambient (verified empirically — important)
The obvious approaches fail under Istio **ambient**, because ztunnel (not the app pod) is the
actual egress actor for external traffic:
- **Kubernetes NetworkPolicy egress** cannot do per-pod identity control: Calico sees the
  connection as originating from **ztunnel** (istio-system, on the node), not the app pod, so
  a pod-scoped egress policy never matches external traffic. (Tested: `untrusted` still
  reached the internet with a pod-scoped default-deny egress in place.)
- **`meshConfig outboundTrafficPolicy: REGISTRY_ONLY`** is **not enforced by ztunnel** in
  this version — undeclared external hosts still pass through. (Tested: `wikipedia.org`
  stayed reachable under REGISTRY_ONLY.) So it can't be used as a global allow-list here.
- **DNS (`:53`) is a poor demo target:** ztunnel runs a DNS proxy and answers declared hosts
  with a synthetic IP (`240.240.0.1`) to route the connection — this collides with using
  port 53 itself as the destination service. Use a non-DNS raw-TCP service (tcpbin) instead.

## Mechanism that DOES work: an egress waypoint
For external services **declared via `ServiceEntry`** and pinned to a waypoint
(`istio.io/use-waypoint`), ztunnel routes the traffic **through the waypoint** (an Envoy
proxy), where an `AuthorizationPolicy` can allow/deny by the source workload's **SPIFFE
identity** (and by host). This is the only mechanism that enforces identity-aware egress in
ambient.

## Steps
Executed by `scripts/08-feature-egress-internet.sh` (idempotent). Manifests in
`manifests/08-egress/`.
1. Create an **egress waypoint** in `clientspace` (`waypoint.yaml`; Gateway of class
   `istio-waypoint`, `istio.io/waypoint-for: all`).
2. Declare the three approved external services and route them through the waypoint
   (`serviceentries.yaml`): `tcpbin.com:4242` (protocol TCP), `example.com:443` and
   `en.wikipedia.org:443` (protocol TLS, so the waypoint matches SNI/host without
   terminating TLS).
3. Authorize per the matrix (`authorizationpolicies.yaml`). Two important shape choices:
   - **Target the `ServiceEntry`, not the waypoint Gateway.** A Gateway-targeted allow is
     coarse — it grants the identity access to *every* service through the waypoint, so you
     can't scope per service. Targeting the ServiceEntry scopes the allow to specific hosts.
   - **`targetRefs` is a list**, and one policy may target multiple ServiceEntries — so we
     write **one policy per identity** (not per service), listing the services it may reach:
   ```yaml
   apiVersion: security.istio.io/v1
   kind: AuthorizationPolicy
   metadata: { name: egress-allow-trusted, namespace: clientspace }
   spec:
     targetRefs:                       # a LIST: one identity, multiple allowed services
       - { group: networking.istio.io, kind: ServiceEntry, name: tcpbin-echo }
       - { group: networking.istio.io, kind: ServiceEntry, name: example-com }
     action: ALLOW
     rules:
       - from: [{ source: { principals: ["cluster.local/ns/clientspace/sa/trusted-client"] } }]
   # ...plus a second policy: egress-allow-untrusted -> [wikipedia]
   ```

## Verify
```sh
# trusted may reach tcpbin + example.com, but NOT wikipedia:
kubectl -n clientspace exec trusted   -- sh -c 'echo hi | nc -w5 tcpbin.com 4242'                                    # echoes "hi"
kubectl -n clientspace exec trusted   -- curl -sS --max-time 8 https://example.com    -o /dev/null -w 'ex=%{http_code}\n'   # 200
kubectl -n clientspace exec trusted   -- curl -sS --max-time 8 https://en.wikipedia.org -o /dev/null -w 'wiki=%{http_code}\n' || echo "wiki=denied (expected)"
# untrusted may reach ONLY wikipedia:
kubectl -n clientspace exec untrusted -- curl -sS --max-time 8 https://en.wikipedia.org -o /dev/null -w 'wiki=%{http_code}\n'  # 301
kubectl -n clientspace exec untrusted -- sh -c 'echo hi | nc -w5 tcpbin.com 4242' || echo "tcpbin=denied (expected)"
# any other pod (netshoot, SA default) reaches none:
kubectl -n clientspace exec netshoot  -- curl -sS --max-time 8 https://example.com    -o /dev/null -w 'ex=%{http_code}\n' || echo "denied (expected)"
```

## Notes / limitations (be honest about the guarantee)
- **`targetRefs` is a list; one policy can target many ServiceEntries.** You do NOT need a
  separate AuthorizationPolicy per service — group by identity instead.
- **A ServiceEntry with NO policy targeting it is OPEN TO ALL.** There is no automatic
  per-service default-deny; every declared service must be covered by some allow policy, or
  it is wide open. (`authorizationpolicies.yaml` and `serviceentries.yaml` must stay in sync.)
- **Enforceable guarantee:** "for a **declared** external service, only the listed identities
  may reach it." Enforced on cryptographic SPIFFE identity — un-spoofable by IP/namespace/
  header, unlike NetworkPolicy.
- **NOT enforced:** "block the entire rest of the internet." Undeclared hosts bypass the
  waypoint (REGISTRY_ONLY is ineffective in ambient — see plan 11).
- The TLS ServiceEntries match on SNI/host without decrypting; per-URL (path) egress would
  additionally require L7 HTTP handling.

## Next
`plans/09-feature-tcp-service.md`