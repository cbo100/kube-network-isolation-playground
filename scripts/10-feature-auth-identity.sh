#!/usr/bin/env bash
# Plan 10 (simplified) — expose bookinfo through the ingress, protected by WORKLOAD
# (SPIFFE) identity at the mesh L4 layer.
#
# plan 05's default-deny blocks the kgateway ingress from reaching productpage (the
# bookinfo.localhost route returns 503). This restores it with the minimal, identity-
# scoped ALLOW: only the kgateway proxy's SPIFFE identity
# (cluster.local/ns/kgateway-system/sa/http) may call productpage. Enforced by ztunnel
# at L4 — no waypoint. Denials for other identities remain connection resets.
#
# NOTE: the richer end-user auth story (Keycloak OIDC at the edge + JWT validation at an
# Istio waypoint, carrying END-USER identity into the app) is PARKED on the backlog. See
# plans/10-feature-auth-identity.md (kept as the backlog design) and the git history for
# the deferred implementation.
#
# Idempotent: kubectl apply converges on re-run.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

need kubectl
kubectl config use-context "$KIND_CONTEXT" >/dev/null

M="${REPO_ROOT}/manifests/10-auth-identity"

# --- 1. allow the ingress identity into productpage ---------------------------
log "allowing ONLY the kgateway ingress SPIFFE identity -> productpage (AuthorizationPolicy)"
kubectl apply -f "${M}/authorizationpolicy-allow-ingress.yaml"

# --- 1b. open the internal bookinfo call graph, strictly per-identity ----------
# productpage->details, productpage->reviews, reviews->ratings (details canNOT reach
# ratings). The reviews->ratings edge also needs plan 07's DENY exception, re-applied here.
log "opening the internal bookinfo call graph (strict per-identity) + plan 07 DENY exception"
kubectl apply -f "${M}/authorizationpolicy-bookinfo-internal.yaml"
kubectl apply -f "${REPO_ROOT}/manifests/07-pod-isolation/authorizationpolicy-ratings-trusted-only.yaml"

# let ztunnel converge
sleep 6

# --- 2. verify ----------------------------------------------------------------
fail=0
check() { # <label> <actual> <expected>
  if [ "$2" = "$3" ]; then log "  $1 = $2 (ok)"; else warn "$1 expected $3, got $2"; fail=1; fi
}

log "MATRIX — the ingress route to bookinfo is now reachable (was 503 under default-deny):"
code="$(curl -sS -o /dev/null -w '%{http_code}' -H 'host: bookinfo.localhost' \
  http://localhost:9090/productpage || echo 000)"
check "GET bookinfo.localhost/productpage" "$code" 200

log "MATRIX — the full page renders (details + reviews panels populated, no error text):"
page="$(curl -sS -H 'host: bookinfo.localhost' 'http://localhost:9090/productpage?u=normal' || true)"
det="$(printf '%s' "$page" | grep -qi 'Error fetching product details' && echo no || echo ok)"
rev="$(printf '%s' "$page" | grep -qi 'Error fetching product reviews' && echo no || echo ok)"
check "details panel populated" "$det" ok
check "reviews panel populated" "$rev" ok

log "MATRIX — strictness: details CANNOT reach ratings (leaf stays a leaf):"
# details is a ruby app (no curl/wget); use ruby to attempt the actual HTTP GET. A mesh
# reset/timeout => blocked (expected); any HTTP status => reachable (would be a leak).
# NOTE: must issue a real request — merely opening the socket can succeed before ztunnel
# resets the L7 exchange.
d2r="$(kubectl -n bookinfo exec deploy/details-v1 -- ruby -e '
require "net/http"
begin
  res = Net::HTTP.get_response(URI("http://ratings:9080/ratings/0"))
  puts "reachable"
rescue => e
  puts "blocked"
end' 2>/dev/null || echo blocked)"
check "details -> ratings" "$d2r" blocked

[ "$fail" = 0 ] || die "plan 10 verification had failures (see warnings above)"

log "plan 10 (simplified) complete: bookinfo is exposed through the ingress, and reaching"
log "  productpage requires the kgateway proxy's cryptographic SPIFFE identity — enforced"
log "  by ztunnel at L4 on top of STRICT mTLS. End-user OIDC/JWT auth is parked on the"
log "  backlog (see plans/10-feature-auth-identity.md)."
