# kube-network-isolation-playground

A local Kubernetes sandbox for learning and demonstrating **service-mesh isolation and
identity features** using a multi-node [kind](https://kind.sigs.k8s.io/) cluster,
[kgateway](https://kgateway.dev/) as the north-south ingress (Gateway API), and
[Istio ambient mesh](https://istio.io/latest/docs/ambient/) for east-west traffic.

## Why this repo exists

We want a reproducible, scriptable environment where we can build up — step by step — a
realistic mesh and then **prove** a set of isolation and identity properties by actually
attacking/testing them (not just asserting they work). Everything is pinned to specific
versions and driven by idempotent scripts so it can be torn down and rebuilt at will.

## Architecture

```
                       ┌─────────────────────────────────────────────┐
   host :9090 ──80──▶  │ kind: kind-cluster                           │
                       │                                              │
                       │  control-plane node (ingress pinned here)    │
                       │    └─ kgateway Gateway (north-south, L7)      │
                       │                                              │
                       │  worker-1        worker-2                    │
                       │    apps            apps                      │
                       │                                              │
                       │  Mesh: Istio ambient                         │
                       │    - ztunnel  (per-node L4 mTLS, identity)   │
                       │    - waypoints (per-ns/service L7 policy)     │
                       └─────────────────────────────────────────────┘
```

- **kgateway** = north-south ingress (Gateway API `gatewayClassName: kgateway`).
- **Istio ambient** = east-west mesh. `ztunnel` gives every workload a SPIFFE identity and
  transparent mTLS (L4). **Waypoint** proxies add L7 policy where needed (e.g. egress).
- **Calico** replaces kind's default CNI so Kubernetes `NetworkPolicy` is actually enforced.

## Component versions (pinned)

| Component            | Version        |
|----------------------|----------------|
| kind                 | v0.33          |
| Kubernetes (node)    | v1.37.0 (digest-pinned; highest for kind v0.33) |
| Gateway API CRDs     | v1.6.1 (standard) |
| kgateway             | 2.4.4          |
| Istio (ambient)      | v1.31          |
| CNI                  | Calico v3.32.2 (NetworkPolicy enforcement) |
| Monitoring           | kube-prometheus-stack 91.2.3 + Kiali 2.31.0 |

## Feature demonstrations

| # | Feature                                   | Layer | Waypoint? | Mechanism |
|---|-------------------------------------------|-------|-----------|-----------|
| 6 | namespace-to-namespace isolation          | L4    | no        | `AuthorizationPolicy` (namespaces) + `NetworkPolicy` |
| 7 | pod-to-pod isolation                       | L4    | no        | `AuthorizationPolicy` (principals) + mTLS `PeerAuthentication` |
| 8 | pod-to-internet (egress) isolation         | L4/L7 | egress    | `ServiceEntry` + `AuthorizationPolicy` via egress waypoint |
| 9 | pod-to-TCP-service (redis/postgres)        | L4    | no        | `AuthorizationPolicy` (dest port + principal) |
| 10| ingress → app + strict internal call graph | L4    | no        | `AuthorizationPolicy` (ingress SPIFFE id → productpage; least-privilege productpage→details/reviews, reviews→ratings) |
| 11| *investigation:* ambient egress registry-only | —  | —         | research doc — is a REGISTRY_ONLY egress default-deny achievable in ambient? (spoiler: not in-mesh, OSS) |

> **Note on plan 10:** the richer end-user **OIDC/JWT** design (Keycloak at the edge + JWT
> validation at a waypoint, carrying end-user identity into the app) is **parked on the
> backlog** — see `plans/10-feature-auth-identity.md`. What shipped is the simplified
> workload-identity version: expose bookinfo through the ingress gated by the kgateway
> proxy's SPIFFE identity, plus a strict least-privilege internal call graph.

**Key rule (Istio ambient):** L4 policy (identity, namespaces, ports) is enforced by
`ztunnel` **without** a waypoint. Any L7 policy (HTTP methods/paths/headers, JWT) **requires
a waypoint** — an L7 rule on a ztunnel-only path fails safe to *DENY*.

## Verifying the isolation matrix

`scripts/verify-isolation.sh` prints the **live allow/deny matrix** for every identity-based
rule the mesh enforces (plans 06–10) and exits non-zero on any mismatch, so it doubles as a
regression gate:

```sh
./scripts/verify-isolation.sh          # one-shot
watch -n2 ./scripts/verify-isolation.sh # watch cells flip as you apply/remove policies
```

It also demonstrates the plan 11 egress limitation directly (an **undeclared** external host
is reachable by all identities, because ambient has no in-mesh egress default-deny).

## Layout

```
kind/cluster.yaml     multi-node kind config (1 control-plane + 2 workers)
manifests/            declarative YAML applied by the scripts, grouped by plan
scripts/              idempotent bootstrap scripts (run in order) + verify-isolation.sh
plans/                step-by-step plan files, one per milestone
```

## Quickstart

```sh
# Plan 00 — (re)create the multi-node cluster
./scripts/00-cluster.sh

# then follow plans/ in order (01 kgateway, 02 istio, ...)
```

Each `plans/NN-*.md` is self-contained: purpose, prerequisites, exact commands, and how to
**verify** the milestone.

## Monitoring UIs

After plan 03, these are reachable through the kgateway ingress (macOS resolves
`*.localhost` automatically):

- Grafana — http://grafana.localhost:9090 (admin/admin)
- Prometheus — http://prometheus.localhost:9090
- Alertmanager — http://alertmanager.localhost:9090
- Kiali — http://kiali.localhost:9090

## Plan index

- `plans/00-cluster.md` — multi-node kind cluster
- `plans/01-kgateway.md` — Gateway API + kgateway ingress
- `plans/02-istio-ambient.md` — ambient mesh + kgateway integration
- `plans/03-monitoring.md` — Prometheus/Grafana + Kiali
- `plans/04-example-apps.md` — bookinfo, netshoot, redis, postgres
- `plans/05-security-baseline.md` — STRICT mTLS + default-deny baseline
- `plans/06-feature-ns-isolation.md`
- `plans/07-feature-pod-isolation.md`
- `plans/08-feature-egress-internet.md`
- `plans/09-feature-tcp-service.md`
- `plans/10-feature-auth-identity.md` — shipped: ingress→app via SPIFFE identity + strict internal call graph (OIDC/JWT design parked as backlog in the same doc)
- `plans/11-investigate-ambient-registry-only.md` — research: no in-mesh OSS egress default-deny in ambient (maintainers declined REGISTRY_ONLY); includes an "ambient vs. sidecar — worth it?" analysis
