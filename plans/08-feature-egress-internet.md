# Plan 08 — Pod-to-internet (egress) isolation

## Purpose
Restrict which external destinations a pod may reach, by **workload identity** — allow only
an approved pod to reach approved external services. Covers **raw external TCP** and
**HTTP/S**, not just websites.

## Motivating tests (real targets)
Two concrete external services, one per traffic shape:
- **Raw TCP:** `tcpbin.com:4242` — a public TCP echo server (send a line, it echoes back).
- **HTTP/S:** `example.com:443`.

As of plan 06, egress is completely **uncontrolled**: `trusted`, `untrusted`, and
`otherspace` can all freely reach these (observed: echo works and HTTP 200 from every pod).
This plan gates them so only the `trusted` identity gets out.

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
2. Declare the approved external services and route them through the waypoint
   (`serviceentries.yaml`): `tcpbin.com:4242` (protocol TCP) and `example.com:443`
   (protocol TLS, so the waypoint matches SNI/host without terminating TLS).
3. Authorize only the trusted identity on the waypoint
   (`authorizationpolicy-egress-allow-trusted.yaml`):
   ```yaml
   apiVersion: security.istio.io/v1
   kind: AuthorizationPolicy
   metadata: { name: egress-allow-trusted, namespace: clientspace }
   spec:
     targetRefs: [{ group: gateway.networking.k8s.io, kind: Gateway, name: egress-wp }]
     action: ALLOW
     rules:
       - from: [{ source: { principals: ["cluster.local/ns/clientspace/sa/trusted-client"] } }]
   ```

## Verify
```sh
# raw TCP echo — allowed for trusted, denied for untrusted:
kubectl -n clientspace exec trusted   -- sh -c 'echo hi | nc -w5 tcpbin.com 4242'   # echoes "hi"
kubectl -n clientspace exec untrusted -- sh -c 'echo hi | nc -w5 tcpbin.com 4242' || echo "denied (expected)"
# HTTPS — allowed for trusted, denied for untrusted:
kubectl -n clientspace exec trusted   -- curl -sS --max-time 8 https://example.com -o /dev/null -w 'trusted=%{http_code}\n'
kubectl -n clientspace exec untrusted -- curl -sS --max-time 8 https://example.com -o /dev/null -w 'untrusted=%{http_code}\n' || echo "untrusted=denied (expected)"
```

## Notes / limitations (be honest about the guarantee)
- **Enforceable guarantee:** "for a **declared** external service, only an approved identity
  may reach it." Enforced by the waypoint on cryptographic SPIFFE identity — un-spoofable by
  IP/namespace/header, unlike NetworkPolicy.
- **NOT enforced:** "block the entire rest of the internet." Undeclared hosts bypass the
  waypoint and egress directly, because REGISTRY_ONLY is ineffective in ambient here. To
  approximate a full allow-list you would need a working global egress deny (e.g. a Calico
  policy applied to the ztunnel/node egress path, or a future ambient REGISTRY_ONLY fix).
- The `example.com` ServiceEntry uses `protocol: TLS` so the waypoint matches on SNI/host
  without decrypting; per-URL (path) egress would additionally require L7 HTTP handling.

## Next
`plans/09-feature-tcp-service.md`