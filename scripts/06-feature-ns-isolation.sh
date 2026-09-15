#!/usr/bin/env bash
# Plan 06 — namespace-to-namespace isolation (L4).
# On top of plan 05's default-deny, allow ONLY clientspace -> bookinfo (by authenticated
# source namespace), and prove a second identical namespace (otherspace) stays denied.
# Enforced by ztunnel at L4 (no waypoint) + a layered Calico NetworkPolicy.
# Idempotent: kubectl apply converges on re-run.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

need kubectl
kubectl config use-context "$KIND_CONTEXT" >/dev/null

M="${REPO_ROOT}/manifests/06-ns-isolation"

# --- 1. negative-control namespace (otherspace) -------------------------------
log "creating otherspace (ambient) + netshoot client (negative control)"
kubectl apply -f "${M}/otherspace.yaml"

# --- 2. allow clientspace -> bookinfo (mesh authz + NetworkPolicy) ------------
log "allowing clientspace -> bookinfo at the mesh layer (AuthorizationPolicy)"
kubectl apply -f "${M}/authorizationpolicy-allow-clientspace.yaml"

log "allowing clientspace -> bookinfo at the CNI layer (NetworkPolicy)"
kubectl apply -f "${M}/networkpolicy-allow-clientspace.yaml"

# --- 3. wait for the otherspace client ----------------------------------------
log "waiting for otherspace client to be Ready"
retry 40 5 kubectl -n otherspace wait --for=condition=Ready pod/netshoot --timeout=20s

# let ztunnel + Calico converge on the new policies
sleep 6

# --- 4. verify ----------------------------------------------------------------
fail=0

log "verifying ALLOWED: clientspace -> bookinfo productpage (expect 200):"
code="$(kubectl -n clientspace exec netshoot -- curl -sS --max-time 5 productpage.bookinfo:9080/productpage -o /dev/null -w '%{http_code}' 2>/dev/null || echo 000)"
log "  clientspace/netshoot -> productpage.bookinfo:9080 = ${code}"
[ "$code" = "200" ] || { warn "expected 200 (clientspace allowed), got ${code}"; fail=1; }

log "verifying DENIED: otherspace -> bookinfo productpage (expect reset/timeout):"
if kubectl -n otherspace exec netshoot -- curl -sS --max-time 5 productpage.bookinfo:9080/productpage -o /dev/null 2>/dev/null; then
  warn "expected otherspace to be DENIED, but the call SUCCEEDED"; fail=1
  log "  otherspace/netshoot -> productpage.bookinfo:9080 = SUCCESS (unexpected!)"
else
  log "  otherspace/netshoot -> productpage.bookinfo:9080 = reset/denied (expected)"
fi

log "verifying the ingress route is STILL denied (no allow for the gateway identity yet):"
ing="$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' -H 'Host: bookinfo.localhost' http://localhost:9090/productpage 2>/dev/null || echo 000)"
log "  ingress bookinfo.localhost -> productpage = ${ing} (expect 503/000; ingress auth is plan 10)"
case "$ing" in 503|000) : ;; *) warn "expected ingress still denied, got ${ing}"; fail=1;; esac

[ "$fail" = 0 ] || die "plan 06 verification had failures (see warnings above)"

log "plan 06 complete: clientspace -> bookinfo ALLOWED by authenticated namespace;"
log "  otherspace still DENIED. Identity-based ns isolation proven at L4 (ztunnel + Calico)."
log "next: plans/07-feature-pod-isolation.md"
