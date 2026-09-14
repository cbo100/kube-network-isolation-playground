#!/usr/bin/env bash
# Plan 04 — example apps: workloads used across the feature demos.
#   bookinfo   — Istio's multi-service L7 sample (Kiali topology, waypoint demos)
#   netshoot   — client/attacker pods with curl/dig/nc/redis-cli/psql (clientspace)
#   redis+postgres — TCP services for L4 identity-isolation demos (dataspace)
# All namespaces are enrolled in Istio ambient mode.
# Idempotent: kubectl apply converges on re-run.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

need kubectl

kubectl config use-context "$KIND_CONTEXT" >/dev/null

M="${REPO_ROOT}/manifests/04-apps"
CLIENT_IMAGE="localhost/kubesandboxing/client:1.0"
# Bookinfo ships in the Istio repo; track the branch matching the pinned istioctl.
ISTIO_BRANCH="release-${ISTIO_VERSION%.*}"
BOOKINFO_URL="https://raw.githubusercontent.com/istio/istio/${ISTIO_BRANCH}/samples/bookinfo/platform/kube/bookinfo.yaml"

# --- 1. namespaces (ambient) --------------------------------------------------
log "creating namespaces (bookinfo/clientspace/dataspace), enrolled in ambient"
kubectl apply -f "${M}/namespaces.yaml"

# --- 2. client image (non-root, baked with redis-cli/psql/curl/dig/nc) --------
# Build with podman (fallback: docker) and load into every kind node so the client
# pods can run non-root with tools preinstalled — no boot-time apk, no registry.
need kind
if command -v podman >/dev/null 2>&1; then
  CE=podman
  KIND_LOAD_ENV=(KIND_EXPERIMENTAL_PROVIDER=podman)
elif command -v docker >/dev/null 2>&1; then
  CE=docker
  KIND_LOAD_ENV=()
else
  die "need podman or docker to build the client image"
fi

log "building client image ${CLIENT_IMAGE} with ${CE}"
"$CE" build --platform linux/arm64 -t "$CLIENT_IMAGE" "${M}/client-image"

log "loading ${CLIENT_IMAGE} into kind cluster '${CLUSTER_NAME}'"
env "${KIND_LOAD_ENV[@]}" kind load docker-image "$CLIENT_IMAGE" --name "$CLUSTER_NAME"

# --- 3. bookinfo --------------------------------------------------------------
log "deploying bookinfo from ${ISTIO_BRANCH}"
kubectl -n bookinfo apply -f "$BOOKINFO_URL"

log "exposing bookinfo via ingress (bookinfo.localhost -> productpage:9080)"
kubectl apply -f "${M}/bookinfo-route.yaml"

# --- 4. clients (netshoot: trusted / untrusted / generic) ---------------------
log "deploying client identities in clientspace (trusted / untrusted / netshoot)"
# Pods are immutable; recreate them so spec changes converge on re-run. These are
# stateless test pods, so delete+apply is safe and idempotent.
kubectl -n clientspace delete pod netshoot trusted untrusted --ignore-not-found --wait=true
kubectl apply -f "${M}/clients.yaml"

# --- 5. TCP services (redis, postgres) ----------------------------------------
log "deploying redis + postgres in dataspace"
kubectl apply -f "${M}/redis.yaml"
kubectl apply -f "${M}/postgres.yaml"

# --- 6. wait for everything to come up ----------------------------------------
log "scaling bookinfo frontends to 2 replicas (spread across nodes)"
kubectl -n bookinfo scale deploy/productpage-v1 deploy/reviews-v1 --replicas=2

log "waiting for bookinfo deployments"
for d in productpage-v1 details-v1 ratings-v1 reviews-v1 reviews-v2 reviews-v3; do
  retry 40 5 kubectl -n bookinfo rollout status "deploy/$d" --timeout=20s
done

log "waiting for dataspace services (2 replicas each, node-spread)"
retry 40 5 kubectl -n dataspace rollout status deploy/redis --timeout=20s
retry 40 5 kubectl -n dataspace rollout status deploy/postgres --timeout=20s

log "waiting for clientspace pods (non-root baked client image)"
for p in netshoot trusted untrusted; do
  retry 60 5 kubectl -n clientspace wait --for=condition=Ready "pod/$p" --timeout=20s
done

# --- 7. verify ----------------------------------------------------------------
log "workloads:"
kubectl get pods -n bookinfo -o wide
kubectl get pods -n clientspace -o wide
kubectl get pods -n dataspace -o wide

log "verifying replicas spread across nodes:"
spread_ok=1
check_spread() { # <ns> <selector> <label>
  local nodes
  nodes="$(kubectl -n "$1" get pods -l "$2" \
    -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u | grep -c .)"
  log "  $3: pods on ${nodes} node(s)"
  [ "$nodes" -ge 2 ] || { warn "$3 not spread across >=2 nodes"; spread_ok=0; }
}
check_spread dataspace   app=redis    redis
check_spread dataspace   app=postgres postgres
check_spread bookinfo    app=productpage productpage
check_spread clientspace role=client  clients
[ "$spread_ok" = 1 ] || die "plan 04 verification failed: workloads not spread across nodes"

log "verifying netshoot -> bookinfo productpage (L7 in-mesh call):"
code="$(retry 15 4 kubectl -n clientspace exec netshoot -- \
  curl -sS --max-time 5 productpage.bookinfo:9080/productpage -o /dev/null -w '%{http_code}' 2>/dev/null || echo ERR)"
log "  productpage.bookinfo:9080/productpage -> ${code}"
[ "$code" = "200" ] || die "plan 04 verification failed: bookinfo productpage not reachable (got ${code})"

log "verifying bookinfo via ingress (bookinfo.localhost -> :9090):"
code="$(retry 15 4 bash -c "curl -sS -o /dev/null -w '%{http_code}' --max-time 5 -H 'Host: bookinfo.localhost' http://localhost:9090/productpage | grep -qx 200" >/dev/null 2>&1 && echo 200 || echo ERR)"
log "  http://bookinfo.localhost:9090/productpage -> ${code}"
[ "$code" = "200" ] || die "plan 04 verification failed: bookinfo not reachable via ingress (got ${code})"

log "verifying trusted -> redis (PING) and postgres (select 1):"
retry 15 4 kubectl -n clientspace exec trusted -- redis-cli -h redis.dataspace ping | grep -q PONG \
  && log "  redis PING -> PONG" || die "plan 04 verification failed: redis not reachable"
retry 15 4 kubectl -n clientspace exec trusted -- \
  psql "postgresql://app:app@postgres.dataspace:5432/app" -tAc 'select 1' | grep -q '^1$' \
  && log "  postgres select 1 -> 1" || die "plan 04 verification failed: postgres not reachable"

log "plan 04 complete: bookinfo + netshoot clients + redis/postgres up and reachable in-mesh"
log "  bookinfo UI: http://bookinfo.localhost:9090/productpage (add to /etc/hosts or use curl -H Host:)"
log "next: plans/05-security-baseline.md (STRICT mTLS + default-deny will lock these down)"
