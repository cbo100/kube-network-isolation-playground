#!/usr/bin/env bash
# Plan 07 — pod-to-pod isolation (L4, workload identity).
# On top of plan 06's namespace-wide allow, tighten a SINGLE workload ('ratings') so only
# ONE SPIFFE principal (clientspace/trusted-client) may reach it — while a same-namespace,
# different-identity pod ('untrusted') is denied to ratings but still reaches other
# bookinfo services. Enforced by ztunnel at L4 (no waypoint) via a targeted DENY.
# Idempotent: kubectl apply converges on re-run.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

need kubectl
kubectl config use-context "$KIND_CONTEXT" >/dev/null

M="${REPO_ROOT}/manifests/07-pod-isolation"

# --- 1. apply the identity-scoped restriction on 'ratings' --------------------
log "restricting bookinfo/ratings to principal clientspace/trusted-client (DENY others)"
kubectl apply -f "${M}/authorizationpolicy-ratings-trusted-only.yaml"

# let ztunnel converge on the new policy
sleep 6

# --- 2. verify ----------------------------------------------------------------
fail=0

# helper: HTTP code from a clientspace pod to a bookinfo URL. On an L4 reset/timeout curl
# already prints "000" to stdout, so we do NOT append our own fallback (that would yield
# "000000"); we just capture whatever curl reports.
code_from() { # <pod> <url>
  kubectl -n clientspace exec "$1" -- sh -c \
    "curl -sS --max-time 5 '$2' -o /dev/null -w '%{http_code}' 2>/dev/null; true"
}

log "verifying ALLOWED: trusted (SA trusted-client) -> ratings (expect 200):"
c="$(code_from trusted ratings.bookinfo:9080/ratings/0)"
log "  trusted -> ratings.bookinfo = ${c}"
[ "$c" = "200" ] || { warn "expected 200 for trusted-client, got ${c}"; fail=1; }

log "verifying DENIED: untrusted (same ns, SA untrusted-client) -> ratings (expect reset/000):"
c="$(code_from untrusted ratings.bookinfo:9080/ratings/0)"
log "  untrusted -> ratings.bookinfo = ${c}"
[ "$c" = "000" ] || { warn "expected untrusted -> ratings to be denied (000), got ${c}"; fail=1; }

log "verifying SCOPE: untrusted -> productpage STILL works (isolation is per-workload):"
c="$(code_from untrusted productpage.bookinfo:9080/productpage)"
log "  untrusted -> productpage.bookinfo = ${c} (expect 200: only ratings is restricted)"
[ "$c" = "200" ] || { warn "expected untrusted -> productpage to still work (200), got ${c}"; fail=1; }

log "verifying netshoot (SA default, same ns) -> ratings is also denied (only trusted-client allowed):"
c="$(code_from netshoot ratings.bookinfo:9080/ratings/0)"
log "  netshoot -> ratings.bookinfo = ${c} (expect reset/000)"
[ "$c" = "000" ] || { warn "expected netshoot -> ratings denied (000), got ${c}"; fail=1; }

[ "$fail" = 0 ] || die "plan 07 verification had failures (see warnings above)"

log "plan 07 complete: 'ratings' reachable ONLY by the trusted-client SPIFFE identity;"
log "  same-namespace pods with a different identity are denied to ratings (but not to"
log "  other services). Isolation proven by cryptographic workload identity, not IP/ns."
log "next: plans/08-feature-egress-internet.md"
