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

## Upstream backlog: is the gap being closed?

Checked the Istio GitHub backlog (istio/istio + istio/ztunnel) for any sign a REGISTRY_ONLY
equivalent is coming to ambient. **It is not — and this is a deliberate design decision, not
an unfixed bug.**

- **istio/istio #54281 — "ztunnel not respecting `outboundTrafficPolicy: REGISTRY_ONLY`"**
  (CLOSED / *working as intended*). Maintainer **howardjohn**:
  > "This is working as intended. Ambient mode does not support this setting. 99% of the
  > time someone is aiming to use this, they are **using it wrong**, so we opted to avoid it."
  He points to his write-up *"You can't block egress"*
  (<https://blog.howardjohn.info/posts/bypass-egress/>): in-mesh egress blocking is trivially
  bypassable (a compromised pod can just leave the mesh), so it gives false assurance — real
  egress control belongs at the network/firewall layer. This is exactly plan 11's
  "enforce below the mesh" conclusion, straight from the maintainers.
- **istio/istio #58644 — "Ambient can't block outgoing HTTPS connections?"** (2026): no fix;
  went stale and auto-closed, users only left `+1`.
- **istio/istio #57661 — "Pods can access external services via waypoints in other
  namespaces"** (2026): closed; the thread is about ServiceEntry `exportTo`/merging quirks,
  not a default-deny feature.
- **istio/ztunnel #369 — RFC on outbound passthrough behavior**: CLOSED/COMPLETED — the
  passthrough (allow-unknown) behavior was intentionally *specified*, not removed.
- **No open issue or enhancement** in istio/istio proposes an ambient egress default-deny
  (`ambient egress` → none open). Open ztunnel egress-related issues are all
  performance/stability (e.g. #2019 external-connect latency, #2085 stale CIDR lookups), not
  a registry-only mode.

**Implication:** don't wait for upstream. The sanctioned posture is precisely what plan 08
does (per-declared-service identity authz) plus a network-layer backstop for a hard lockdown.
This is stronger than "not yet implemented" — the maintainers have explicitly declined to
bring REGISTRY_ONLY to ambient.

## Re-check trigger

`scripts/verify-isolation.sh` asserts the undeclared-host rows are reachable by all three
identities. If a future Istio/ztunnel version starts blocking them (an effective
registry-only landed), those rows will flip to `no` and the script will fail — that's the
signal to revisit this plan.

---

## Side question: is ambient worth the hassle, vs. plain sidecar Istio?

This came up naturally from the egress work: **the one control we couldn't build in ambient
(a REGISTRY_ONLY egress default-deny) is exactly the thing sidecar Istio gives you for
free.** So it's fair to ask whether ambient earned its keep across plans 05–10. Honest,
grounded-in-what-we-saw take:

### Where sidecar would have been equal or better
- **Egress default-deny (this plan).** `outboundTrafficPolicy: REGISTRY_ONLY` is a one-line
  MeshConfig change in sidecar mode and it *works* — undeclared hosts are blocked. In
  ambient it is unenforceable in-mesh (the whole reason plan 11 exists). Straight loss for
  ambient.
- **L7 egress from the source proxy.** In sidecar, the workload's own Envoy applies egress
  policy inline; no separate egress waypoint hop/pod to run. Fewer moving parts for that
  specific feature.
- **Maturity of niche knobs.** `exportTo` scoping, per-sidecar egress — all long-settled in
  sidecar, partially different/ignored in ambient (documented in the Solo migration guide).

### Where ambient clearly paid off in *this* repo
- **L4 identity authz with ZERO proxies in the path (plans 06/07/09).** ns-isolation,
  pod-to-pod isolation, and the raw-TCP redis/postgres isolation are all enforced by
  **ztunnel at L4 — no waypoint, no sidecar injection**. Same SPIFFE-identity guarantees,
  but nothing was injected into the app pods. In sidecar mode every one of those pods
  (bookinfo ×6, redis, postgres, the clients) would carry an Envoy sidecar just to get mTLS
  identity + L4 authz.
- **Raw TCP services for free (plan 09).** redis/postgres got identity-based authz with no
  per-pod proxy and no protocol fuss. The isolation is protocol-agnostic at ztunnel.
- **Pay for L7 only where you use it (plans 08/10).** We ran a waypoint *only* for egress
  (plan 08) and would have for JWT (parked plan 10) — i.e. an L7 proxy exists exactly at the
  two places that need L7, instead of one Envoy per pod everywhere.
- **Operational blast radius / upgrades.** No sidecar injection means no pod restarts to
  adopt or upgrade the data plane, no init-container ordering issues, no sidecar-vs-app
  lifecycle races. We swapped ztunnel/waypoint versions without touching app pods.
- **Resource cost.** One ztunnel per node + a couple of waypoints, vs. ~10 sidecars here.
  At small scale it's a wash; the gap widens with pod count.

### Bottom line (for this workload)
For a repo whose center of gravity is **identity-based L4 isolation** (namespaces, pods,
raw-TCP services), **ambient is the better fit**: we got the core guarantees with far fewer
proxies and no injection, and only stood up an L7 proxy where L7 was actually required. The
**single** feature where sidecar wins outright is the **egress default-deny** — and that is
better solved *below* the mesh anyway (firewall/CNI), regardless of sidecar vs. ambient, so
it's a weak reason to adopt sidecars everywhere.

Rule of thumb this exercise supports:
- Mostly-L4 identity/segmentation, many pods, want cheap mTLS everywhere → **ambient**.
- Heavy per-request L7 policy on *most* services, or a hard in-mesh egress allow-list is a
  non-negotiable requirement and you can't add a network-layer firewall → **sidecar** is
  still the pragmatic choice.

(Not investigated here, so flagged rather than claimed: sidecar's richer per-workload L7
story — e.g. EnvoyFilter, fine-grained per-route policy — may matter for other workloads.)
