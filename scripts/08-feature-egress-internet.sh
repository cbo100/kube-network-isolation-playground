#!/usr/bin/env bash
# Plan 08 — pod-to-internet (egress) isolation, done the ambient-correct way, with a
# PER-SERVICE access matrix.
#
# Under ambient, ztunnel is the egress actor, so Kubernetes NetworkPolicy egress and
# meshConfig REGISTRY_ONLY do NOT give per-identity external control (verified). The
# working mechanism is an EGRESS WAYPOINT: declare approved external services via
# ServiceEntry (routed through the waypoint) and authorize PER-SERVICE by targeting each
# ServiceEntry with its own AuthorizationPolicy (targeting the Gateway would be coarse).
#
# Matrix enforced:
#   trusted-client   -> tcpbin.com:4242 (TCP)  AND  example.com:443 (HTTPS)
#   untrusted-client -> en.wikipedia.org:443 (HTTPS)
#   any other pod    -> NONE of the declared services
# Idempotent: kubectl apply converges on re-run.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

need kubectl
kubectl config use-context "$KIND_CONTEXT" >/dev/null

M="${REPO_ROOT}/manifests/08-egress"

# --- 1. egress waypoint -------------------------------------------------------
log "creating egress waypoint (clientspace/egress-wp)"
kubectl apply -f "${M}/waypoint.yaml"
retry 30 5 kubectl -n clientspace rollout status deploy/egress-wp --timeout=20s

# --- 2. declare the three approved external services --------------------------
log "declaring 3 external services (tcpbin.com, example.com, en.wikipedia.org) via waypoint"
kubectl apply -f "${M}/serviceentries.yaml"

# --- 3. per-service authorization (the matrix) --------------------------------
log "applying per-ServiceEntry AuthorizationPolicies (identity -> service matrix)"
kubectl apply -f "${M}/authorizationpolicies.yaml"

# clean up policy names from earlier iterations, if present
kubectl -n clientspace delete authorizationpolicy \
  egress-allow-trusted-legacy egress-tcpbin-allow-trusted egress-example-allow-trusted \
  egress-wikipedia-allow-untrusted egress-trusted-multi \
  --ignore-not-found >/dev/null 2>&1 || true

sleep 8

# --- 4. verify ----------------------------------------------------------------
fail=0

# raw TCP echo test -> "ok"/"no"
echo_ok() { # <pod>
  kubectl -n clientspace exec "$1" -- sh -c \
    'out=$(echo plan08-probe | nc -w5 tcpbin.com 4242 2>/dev/null | head -1); [ "$out" = "plan08-probe" ] && echo ok || echo no'
}
# HTTPS code to an arbitrary https host -> code (000 on block), no double-print
https_code() { # <pod> <url>
  kubectl -n clientspace exec "$1" -- sh -c \
    "curl -sS --max-time 8 '$2' -o /dev/null -w '%{http_code}' 2>/dev/null; true"
}
expect() { # <label> <actual> <predicate: eq|ne> <value>
  local label="$1" actual="$2" pred="$3" val="$4"
  case "$pred" in
    eq) if [ "$actual" = "$val" ]; then log "  $label = ${actual} (ok)"; else warn "$label expected ${val}, got ${actual}"; fail=1; fi;;
    ne) if [ "$actual" != "$val" ]; then log "  $label = ${actual} (ok)"; else warn "$label expected NOT ${val}, got ${actual}"; fail=1; fi;;
  esac
}

log "MATRIX — trusted-client may reach tcpbin + example.com, NOT wikipedia:"
expect "trusted -> tcpbin"    "$(echo_ok trusted)"                       eq ok
expect "trusted -> example"   "$(https_code trusted https://example.com)" eq 200
expect "trusted -> wikipedia" "$(https_code trusted https://en.wikipedia.org)" eq 000

log "MATRIX — untrusted-client may reach ONLY wikipedia:"
expect "untrusted -> wikipedia" "$(https_code untrusted https://en.wikipedia.org)" ne 000
expect "untrusted -> tcpbin"    "$(echo_ok untrusted)"                            eq no
expect "untrusted -> example"   "$(https_code untrusted https://example.com)"      eq 000

log "MATRIX — any other in-mesh pod (netshoot, SA default) may reach NONE:"
expect "netshoot -> tcpbin"    "$(echo_ok netshoot)"                              eq no
expect "netshoot -> example"   "$(https_code netshoot https://example.com)"       eq 000
expect "netshoot -> wikipedia" "$(https_code netshoot https://en.wikipedia.org)"  eq 000

[ "$fail" = 0 ] || die "plan 08 verification had failures (see warnings above)"

log "plan 08 complete: per-service identity egress matrix enforced via waypoint."
log "  trusted -> {tcpbin, example.com}; untrusted -> {wikipedia}; others -> none."
log "  NOTE: only DECLARED hosts are controlled; a ServiceEntry with NO policy is open to"
log "  all, and undeclared hosts bypass the waypoint (REGISTRY_ONLY unenforced in ambient)."
log "next: plans/09-feature-tcp-service.md"
