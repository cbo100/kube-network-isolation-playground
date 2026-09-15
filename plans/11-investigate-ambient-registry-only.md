# Plan 11 — Investigate a REGISTRY_ONLY equivalent for ambient egress

> **Status: deferred.** Do NOT start this until plans 00–10 are complete. This is a
> research/investigation plan, not a build plan. It records an open question surfaced during
> plan 08 so it isn't lost.

## The open question
Plan 08 gives identity-aware egress to **declared** external services (ServiceEntry → egress
waypoint → `AuthorizationPolicy`). But it does **not** give a global allow-list: **undeclared
external hosts bypass the waypoint and egress freely.**

In sidecar mode you'd close that gap with `meshConfig.outboundTrafficPolicy: REGISTRY_ONLY`.
That flag is **not enforced in ambient** — confirmed by Solo's docs:
<https://ambientmesh.io/docs/traffic-management/egress/migrate-sidecar/>
> "In an ambient mesh, ztunnel does not read `outboundTrafficPolicy`. Traffic to
> unregistered destinations passes through by default."

The docs describe how to migrate *declared*-host egress (use-waypoint + AuthorizationPolicy
targeting the ServiceEntry/Gateway) but **do not** offer a drop-in replacement for the
"deny everything not in the registry" behavior. So: **is a REGISTRY_ONLY equivalent possible
in ambient at all, and if so, how?**

## Candidate approaches to investigate (later)
- **CNI-level default-deny egress on the ztunnel/node egress path.** Since ztunnel is the
  actual egress actor, a Calico policy applied where ztunnel egresses (node/ztunnel identity,
  not the app pod) might implement "deny all external, allow only the waypoint's resolved
  destinations." Open Q: can this be expressed without breaking in-cluster/mesh traffic, and
  can it stay in sync with ServiceEntry IPs?
- **Force ALL egress through the waypoint, then default-deny at the waypoint.** If every
  external destination (not just declared ones) can be made to transit the egress waypoint,
  an `AuthorizationPolicy` there could default-deny. Open Q: is there a catch-all
  ServiceEntry / config that routes unknown hosts through the waypoint in this version?
- **Solo/Enterprise ambient builds** may implement REGISTRY_ONLY-equivalent enforcement.
  Open Q: is it in upstream Istio roadmap / a newer minor than 1.31?
- **NetworkPolicy on egress at the node** (host-level) or an external firewall as a coarse
  belt-and-braces backstop.

## Deliverable when this is picked up
A short findings doc: is a true ambient egress allow-list achievable with our stack
(Istio 1.31 + Calico), which approach, and a working PoC + verification — or a clear
statement that it is not currently possible and why, with the recommended compensating
control.

## Prerequisites
- Plans 00–10 complete.
