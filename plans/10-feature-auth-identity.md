# Plan 10 — Mesh auth with identity carried into the app (L7)

> **STATUS: the L7 end-user-identity design below is PARKED on the backlog.**
> What actually shipped is a simplified plan 10: expose bookinfo through the ingress,
> protected by the kgateway proxy's **workload (SPIFFE) identity** at L4 (ztunnel, no
> waypoint). See `scripts/10-feature-auth-identity.sh` and
> `manifests/10-auth-identity/authorizationpolicy-allow-ingress.yaml`.
>
> The full OIDC/JWT design (Keycloak at the edge + waypoint JWT validation) is retained
> below as the backlog spec. Note learned during a spike: the authorization-code flow
> needs an HTTPS listener on host :9443, and kind+Podman rootlessport only wires a host
> port whose container port is bound at node startup — so enabling :9443 later requires
> restarting the kind node container (or baking the HTTPS listener in from plan 01).

## Purpose
Demonstrate **two identity layers** and carry end-user identity into application traffic:
1. **Workload identity** — SPIFFE mTLS from ztunnel (already in place from plan 05).
2. **End-user identity** — OIDC login at the kgateway edge, JWT validated at an Istio
   **waypoint**, and user claims forwarded to the app as headers.

> L7 auth (JWT validation, header propagation) **requires a waypoint**. An L7 rule on a
> ztunnel-only path fails safe to DENY.

## Prerequisites
- Plans 00–05 complete. A target app (bookinfo `productpage`) in an ambient namespace.

## Components
- **Keycloak** (primary; kgateway's OIDC tutorials use it). **Dex** is a lighter alternative.
- kgateway native OIDC (OAuth2 backend + `TrafficPolicy`) at the edge.
- Istio **waypoint** + `RequestAuthentication` + L7 `AuthorizationPolicy` in the app ns.

## Steps
1. Deploy Keycloak (in-cluster), create a realm + client + a test user. (Dex swap-in noted.)
2. Configure kgateway OIDC on the `HTTPRoute`/`Gateway` (authorization-code flow):
   - OAuth2 backend pointing at Keycloak's issuer/JWKS.
   - `TrafficPolicy` enabling OIDC; kgateway manages the session cookie and injects the
     bearer JWT upstream.
3. Deploy a **waypoint** for the app namespace/service:
   ```sh
   istioctl waypoint apply -n bookinfo --enroll-namespace
   ```
4. Validate the JWT at the waypoint and require it:
   ```yaml
   apiVersion: security.istio.io/v1
   kind: RequestAuthentication
   metadata: { name: jwt, namespace: bookinfo }
   spec:
     targetRefs: [{ group: gateway.networking.k8s.io, kind: Gateway, name: <waypoint> }]
     jwtRules:
       - issuer: "https://<keycloak-issuer>/realms/demo"
         jwksUri: "https://<keycloak>/realms/demo/protocol/openid-connect/certs"
         outputClaimToHeaders:
           - header: x-user-email
             claim: email
           - header: x-user-sub
             claim: sub
   ---
   apiVersion: security.istio.io/v1
   kind: AuthorizationPolicy
   metadata: { name: require-jwt, namespace: bookinfo }
   spec:
     action: ALLOW
     targetRefs: [{ group: gateway.networking.k8s.io, kind: Gateway, name: <waypoint> }]
     rules:
       - from: [{ source: { requestPrincipals: ["*"] } }]
   ```

## Verify
```sh
# unauthenticated is rejected at the edge / waypoint:
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:9090/productpage         # 302 to Keycloak or 403
# after OIDC login, the app receives forwarded identity headers:
kubectl -n bookinfo logs deploy/productpage-v1 | grep -i x-user-email
```
Confirms: end-user authenticates once at the edge, and their **identity is carried into
in-mesh application traffic** as verifiable claims/headers, on top of workload mTLS identity.

## Notes / gotchas
- Keep issuer/JWKS reachable from within the cluster (in-cluster Keycloak service DNS).
- Waypoint identity replaces source identity on the L4 path — attach identity-based authz at
  the waypoint, not ztunnel, once a waypoint is in the path.
- To swap Keycloak → Dex: point the OAuth2 backend + `RequestAuthentication` issuer/JWKS at
  Dex; flow is identical.

## Done
This is the final feature plan. See `README.md` for the full feature matrix.
