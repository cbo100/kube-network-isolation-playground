# kubesandboxing

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
   host :9443 ──443─▶  │                                              │
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

- **kgateway** = north-south ingress (Gateway API `gatewayClassName: kgateway`), also does
  end-user **OIDC** at the edge.
- **Istio ambient** = east-west mesh. `ztunnel` gives every workload a SPIFFE identity and
  transparent mTLS (L4). **Waypoint** proxies add L7 policy and JWT validation where needed.

## Component versions (pinned)

| Component            | Version        |
|----------------------|----------------|
| kind                 | v0.33          |
| Kubernetes (node)    | v1.37.0 (digest-pinned; highest for kind v0.33) |
| Gateway API CRDs     | v1.6.1 (standard) |
| kgateway             | 2.4.4          |
| Istio (ambient)      | v1.31          |
| Monitoring           | kube-prometheus-stack 91.2.3 + Kiali 2.31.0 |
| OIDC provider        | Keycloak (Dex noted as lighter alt) |

## Feature demonstrations

| # | Feature                                   | Layer | Waypoint? | Mechanism |
|---|-------------------------------------------|-------|-----------|-----------|
| 6 | namespace-to-namespace isolation          | L4    | no        | `AuthorizationPolicy` (namespaces) + `NetworkPolicy` |
| 7 | pod-to-pod isolation                       | L4    | no        | `AuthorizationPolicy` (principals) + mTLS `PeerAuthentication` |
| 8 | pod-to-internet (egress) isolation         | L4/L7 | egress    | `NetworkPolicy` egress + authz / `ServiceEntry` |
| 9 | pod-to-TCP-service (redis/postgres)        | L4    | no        | `AuthorizationPolicy` (dest port + principal) |
| 10| mesh auth w/ identity carried into the app | L7    | yes       | OIDC at kgateway + `RequestAuthentication` (JWT) at waypoint, claims → headers |

**Key rule (Istio ambient):** L4 policy (identity, namespaces, ports) is enforced by
`ztunnel` **without** a waypoint. Any L7 policy (HTTP methods/paths/headers, JWT) **requires
a waypoint** — an L7 rule on a ztunnel-only path fails safe to *DENY*.

## Layout

```
kind/cluster.yaml     multi-node kind config (1 control-plane + 2 workers)
scripts/              idempotent bootstrap scripts (run in order)
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
- `plans/10-feature-auth-identity.md`
