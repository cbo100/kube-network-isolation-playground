#!/usr/bin/env bash
# Plan 09 — pod-to-TCP-service isolation (redis / postgres), L4, no waypoint.
# On top of plan 05's default-deny, allow ONLY the trusted-client identity to reach the
# raw-TCP data services (redis:6379, postgres:5432), enforced by ztunnel on source
# principal + destination port. untrusted/netshoot stay denied. Proves mesh isolation is
# protocol-agnostic (works for opaque TCP, by cryptographic identity, not IP).
# Idempotent: kubectl apply converges on re-run.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

need kubectl
kubectl config use-context "$KIND_CONTEXT" >/dev/null

M="${REPO_ROOT}/manifests/09-tcp-service"

# --- 1. open the L3/L4 path (CNI) ---------------------------------------------
log "allowing clientspace -> dataspace at the CNI layer (NetworkPolicy)"
kubectl apply -f "${M}/networkpolicy-allow-clientspace-to-dataspace.yaml"

# --- 2. identity+port authz (mesh, ztunnel L4) --------------------------------
log "allowing ONLY trusted-client -> redis:6379 / postgres:5432 (AuthorizationPolicy)"
kubectl apply -f "${M}/authorizationpolicies.yaml"

# let ztunnel + Calico converge
sleep 6

# --- 3. verify ----------------------------------------------------------------
fail=0

redis_ok() { # <pod> -> ok/no
  kubectl -n clientspace exec "$1" -- sh -c \
    'out=$(redis-cli -h redis.dataspace ping 2>/dev/null | tr -d "\r"); [ "$out" = "PONG" ] && echo ok || echo no'
}
pg_ok() { # <pod> -> ok/no
  kubectl -n clientspace exec "$1" -- sh -c \
    'out=$(psql "postgresql://app:app@postgres.dataspace:5432/app" -tAc "select 1" 2>/dev/null | tr -d "\r" | head -1); [ "$out" = "1" ] && echo ok || echo no'
}
check() { # <label> <actual> <expected>
  if [ "$2" = "$3" ]; then log "  $1 = $2 (ok)"; else warn "$1 expected $3, got $2"; fail=1; fi
}

log "MATRIX — trusted-client (approved identity) may reach BOTH services:"
check "trusted -> redis:6379"    "$(redis_ok trusted)" ok
check "trusted -> postgres:5432" "$(pg_ok trusted)"    ok

log "MATRIX — untrusted-client (same ns, different identity) is DENIED to both:"
check "untrusted -> redis:6379"    "$(redis_ok untrusted)" no
check "untrusted -> postgres:5432" "$(pg_ok untrusted)"    no

log "MATRIX — netshoot (SA default) is DENIED to both:"
check "netshoot -> redis:6379"    "$(redis_ok netshoot)" no
check "netshoot -> postgres:5432" "$(pg_ok netshoot)"    no

[ "$fail" = 0 ] || die "plan 09 verification had failures (see warnings above)"

log "plan 09 complete: redis/postgres reachable ONLY by the trusted-client identity, on"
log "  their service ports — enforced by ztunnel at L4 (no waypoint). Proves mesh isolation"
log "  is protocol-agnostic (raw TCP) and identity-based, not IP/port like NetworkPolicy."
log "next: plans/10-feature-auth-identity.md"
