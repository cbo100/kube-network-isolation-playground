# Plan 11 — Investigate a REGISTRY_ONLY equivalent for ambient egress

> **Status: DONE (investigated).** Research/investigation plan (not a build plan). The
> original open question and candidate list are kept below for context; the outcome is in
> the **Findings** section at the bottom.

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

---

# Findings (investigated)

> **Status: DONE — investigated on Istio 1.31.0 ambient, OSS only.**
> **Constraints applied:** OSS-only (no Solo/Enterprise builds) and **no reliance on
> Calico** (not used in the target production environment).
>
> **Bottom line: a true ambient egress allow-list ("deny everything not in the registry")
> is NOT achievable with OSS Istio 1.31 ambient without a CNI/host-level control. The
> enforceable guarantee remains: "for a DECLARED external service, only an approved
> identity may reach it." Undeclared hosts egress freely and cannot be blocked in-mesh.**

## Why — the root cause (how ambient egress actually works)

Empirically traced in the running cluster:

1. **ztunnel captures the app's outbound and preserves identity**, but only routes a
   connection through the egress waypoint when the **destination IP is a mesh-assigned
   VIP**. Declared ServiceEntry hosts get an auto-allocated VIP from Istio's
   `240.240.0.0/16` / `2001:2::/…` range:
   ```
   istioctl ztunnel-config services
     clientspace  example-com  VIP 240.240.0.4,2001:2::4  WAYPOINT egress-wp  ENDPOINTS 1/1
   ```
2. **The VIP is handed to the app via ztunnel DNS capture.** Inside a mesh pod:
   - declared   `example.com` → `2001:2::4`   (mesh VIP → captured → waypoint → authz)
   - undeclared `example.org` → `104.20.26.136` (real public IP → **not** a VIP → passes through)
3. Because an undeclared host resolves to its **real IP** (no VIP), ztunnel has no
   ServiceEntry/waypoint binding for it and lets it egress directly. The AuthorizationPolicy
   layer never sees it.

This matches the official Solo/ambient docs:
<https://ambientmesh.io/docs/traffic-management/egress/migrate-sidecar/>
> "In an ambient mesh, ztunnel does not read `outboundTrafficPolicy`. Traffic to
> unregistered destinations passes through by default."
The docs provide migration paths for *declared*-host egress only, and **no** REGISTRY_ONLY
replacement.

## Candidates evaluated

| # | Approach | Verdict | Evidence |
|---|----------|---------|----------|
| 1 | **Calico egress NetworkPolicy on the app pod** | ❌ Rejected (constraint + ineffective) | Applied an egress-deny to `netshoot`; undeclared egress still returned **200**. The real external packet leaves from **ztunnel's own netns**, not the pod's — no external conntrack entry appears in the node's main table. Also disallowed: no Calico in prod. |
| 1b | **Calico/k8s NetworkPolicy on ztunnel** | ❌ Rejected (constraint + ineffective) | Egress-restricting the ztunnel pod had no effect (undeclared still **200**); ztunnel's external socket isn't subject to the pod's CNI egress chain. Also a Calico dependency. |
| 2 | **Catch-all ServiceEntry → waypoint → default-deny** | ❌ Does not work | Tried wildcard hosts (`*.org/*.com/*.net`, `resolution: NONE`) and an address catch-all (`addresses: 0.0.0.0/0`). Neither gets a VIP or endpoints (`istioctl ztunnel-config services` shows `catch-all-external … ENDPOINTS 0/0`), so ztunnel never intercepts arbitrary IPs. Waypoint logs stayed empty; `example.org` still **200**. |
| 3 | **Solo/Enterprise ambient builds** | ❌ Out of scope | OSS-only requirement. |
| 4 | **Node/host NetworkPolicy or external firewall** | ❌ Out of scope here | Would be a Calico GlobalNetworkPolicy / HostEndpoint or an external firewall — a CNI/host control, which the constraints exclude. (Left as the only *known* way to actually enforce this; see below.) |
| 5 | **ztunnel DNS capture to synthesize a catch-all VIP** | ❌ Not supported | DNS capture is already ON (declared hosts resolve to VIPs), but for **undeclared** hosts ztunnel proxies the query upstream and returns the **real IP** — it does not synthesize a VIP or NXDOMAIN them. No OSS `PILOT_*`/istiod flag in 1.31 changes this (checked istiod env; none present). |
| 6 | **NetworkPolicy: allow pod egress ONLY to the ztunnel IP** | ❌ Ineffective *and* harmful | Intuition: if the pod can only talk to ztunnel, maybe ztunnel becomes a chokepoint we can default-deny at. Tested (see below): undeclared `example.org` **still 200** (unaffected), while declared `example.com` via the waypoint **broke → 000**. The redirect to ztunnel happens *inside the pod netns below the CNI egress hook*, so the policy never sees undeclared traffic; meanwhile it severs the HBONE path to the cross-node waypoint. Net: you lose the control you had and gain nothing. |

### Detail on candidate 6 — "lock pod egress to ztunnel only"

A natural question: *what if a NetworkPolicy ensures a pod can only connect to ztunnel —
would ztunnel still egress the undeclared traffic?* Tested against `netshoot`
(`clientspace`), whose node-local ztunnel is `10.244.1.147`:

```yaml
# NetworkPolicy: egress allowed ONLY to the ztunnel pod IP (+ DNS)
egress:
  - to: [{ ipBlock: { cidr: 10.244.1.147/32 } }]
  - ports: [{ protocol: UDP, port: 53 }, { protocol: TCP, port: 53 }]
```

| Destination | Before | With "only-ztunnel" policy |
|-------------|--------|----------------------------|
| undeclared `example.org` | 200 | **200 (unchanged — NOT blocked)** |
| declared `example.com` (waypoint) | 200 (trusted) | **000 (BROKE the mesh path)** |
| in-cluster `productpage` | 200 | 200 |

**Why it fails both ways:**
- **Undeclared traffic is intercepted *below* the policy.** istio-cni redirects the pod's
  outbound to the node-local ztunnel via socket-level redirection *inside the pod's own
  network namespace*, before the packet reaches the Kubernetes/CNI egress enforcement point.
  So the NetworkPolicy never observes the original destination — nor a packet "to the
  ztunnel IP" on the wire — and cannot deny it. ztunnel then egresses from **its own netns**.
- **It severs the legitimate declared path.** Declared hosts route as a mesh VIP over an
  HBONE tunnel to the egress waypoint, which lives on **another node** (`egress-wp` on
  `cluster-worker2`). Restricting egress to only the *local* ztunnel IP blocks reaching that
  cross-node waypoint, so the one path that actually depends on the network is broken.

Conclusion: no pod-scoped egress NetworkPolicy — "only ztunnel" or otherwise — can implement
a registry-only equivalent, because the ambient redirect sits beneath the pod's CNI policy
enforcement point. Enforcement must happen where ztunnel *itself* egresses (node/host or an
external firewall), which is outside OSS in-mesh controls.

## Recommendation / compensating control

Since no in-mesh OSS mechanism enforces a global egress allow-list in ambient 1.31, and
CNI/host controls are excluded by our constraints, the recommended posture is:

- **Keep plan 08 as the enforceable control**: identity-aware, per-service egress for every
  **declared** external dependency (ServiceEntry + `use-waypoint` + AuthorizationPolicy).
  Treat the ServiceEntry set as the source of truth for "approved egress".
- **Accept that undeclared egress is not blockable in-mesh** and document it as a known gap
  (this is exactly what `scripts/verify-isolation.sh` demonstrates with the `example.org`
  row: all identities reach an undeclared host).
- **If a hard egress lockdown is actually required**, it must live **below the mesh**: an
  egress firewall / NAT allow-list, a network-level default-deny at the node/VPC, or a CNI
  GlobalNetworkPolicy where that CNI is in use. That is an infrastructure control, outside
  Istio ambient. Revisit if we adopt a CNI with enforced egress or a newer Istio minor that
  adds a ztunnel-level registry-only mode.

## Re-check trigger

`scripts/verify-isolation.sh` asserts the undeclared-host rows are reachable by all three
identities. If a future Istio/ztunnel version starts blocking them (an effective
registry-only landed), those rows will flip to `no` and the script will fail — that's the
signal to revisit this plan.
