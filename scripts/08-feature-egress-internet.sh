#!/usr/bin/env bash
# Plan 08 — pod-to-internet (egress) isolation, done the ambient-correct way.
#
# Under ambient, ztunnel is the egress actor, so Kubernetes NetworkPolicy egress and
# meshConfig REGISTRY_ONLY do NOT give per-identity external control (verified). The
# working mechanism is an EGRESS WAYPOINT: declare approved external services via
# ServiceEntry (routed through the waypoint) and authorize by source SPIFFE identity.
#
# Demo: only the 'trusted' pod may reach two declared external services:
#   - tcpbin.com:4242  (raw TCP echo)   - non-HTTP L4 egress
#   - example.com:443  (HTTPS)          - web egress
# 'untrusted' and 'netshoot' are denied to BOTH.
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

# --- 2. declare approved external services (routed via the waypoint) ----------
log "declaring approved external services (tcpbin.com:4242, example.com:443)"
kubectl apply -f "${M}/serviceentries.yaml"

# --- 3. authorize ONLY the trusted identity on the waypoint -------------------
log "authorizing ONLY clientspace/trusted-client for egress (AuthorizationPolicy on waypoint)"
kubectl apply -f "${M}/authorizationpolicy-egress-allow-trusted.yaml"

# let the waypoint + ztunnel converge
sleep 8

# --- 4. verify ----------------------------------------------------------------
fail=0

# raw TCP echo test: send a line, expect it echoed back. prints "ok"/"no".
echo_ok() { # <pod>
  kubectl -n clientspace exec "$1" -- sh -c \
    'out=$(echo plan08-egress-probe | nc -w5 tcpbin.com 4242 2>/dev/null | head -1); [ "$out" = "plan08-egress-probe" ] && echo ok || echo no'
}
# HTTPS code (000 on block/timeout, no double-print)
https_code() { # <pod>
  kubectl -n clientspace exec "$1" -- sh -c \
    "curl -sS --max-time 8 https://example.com -o /dev/null -w '%{http_code}' 2>/dev/null; true"
}

log "verifying raw TCP egress (tcpbin.com:4242 echo):"
t="$(echo_ok trusted)"
log "  trusted   -> tcpbin.com:4242 = ${t} (expect ok: allowed)"
[ "$t" = "ok" ] || { warn "trusted should reach tcpbin echo, got ${t}"; fail=1; }
u="$(echo_ok untrusted)"
log "  untrusted -> tcpbin.com:4242 = ${u} (expect no: denied)"
[ "$u" = "no" ] || { warn "untrusted should be denied to tcpbin echo, got ${u}"; fail=1; }

log "verifying HTTPS egress (example.com:443):"
t="$(https_code trusted)"
log "  trusted   -> https://example.com = ${t} (expect 200: allowed)"
[ "$t" = "200" ] || { warn "trusted should reach HTTPS, got ${t}"; fail=1; }
u="$(https_code untrusted)"
log "  untrusted -> https://example.com = ${u} (expect 000: denied)"
[ "$u" = "000" ] || { warn "untrusted should be denied to HTTPS, got ${u}"; fail=1; }

[ "$fail" = 0 ] || die "plan 08 verification had failures (see warnings above)"

log "plan 08 complete: identity-aware egress via waypoint — only 'trusted' reaches the"
log "  declared external services (tcpbin.com:4242 raw TCP + example.com:443 HTTPS);"
log "  untrusted/netshoot are denied. NOTE: only DECLARED hosts are enforced — undeclared"
log "  hosts bypass the waypoint (REGISTRY_ONLY is not enforced by ztunnel in this version)."
log "next: plans/09-feature-tcp-service.md"
