#!/usr/bin/env bash
# Plan 05 — security baseline: STRICT mTLS mesh-wide + default-deny authorization per
# app namespace + baseline Kubernetes NetworkPolicy (enforced by Calico).
# Idempotent: kubectl apply converges on re-run.
#
# After this runs, the ambient app namespaces are default-deny: the bookinfo ingress
# route and cross-namespace calls are DENIED until the feature plans (06-10) add the
# minimal explicit ALLOW. The monitoring/kiali UIs are unaffected (not mesh-enrolled,
# no policy applied there).
set -euo pipefail
. "$(dirname "$0")/lib.sh"

need kubectl
kubectl config use-context "$KIND_CONTEXT" >/dev/null

M="${REPO_ROOT}/manifests/05-baseline"

# --- 1. STRICT mTLS mesh-wide -------------------------------------------------
log "enforcing STRICT mTLS mesh-wide (PeerAuthentication in istio-system)"
kubectl apply -f "${M}/peerauthentication-strict.yaml"

# --- 2. default-deny authorization per app namespace --------------------------
log "applying default-deny AuthorizationPolicy (bookinfo/clientspace/dataspace)"
kubectl apply -f "${M}/authorizationpolicy-default-deny.yaml"

# --- 3. baseline NetworkPolicy (Calico-enforced) ------------------------------
log "applying baseline NetworkPolicy (L3/L4 default-deny ingress per app ns)"
kubectl apply -f "${M}/networkpolicy-baseline.yaml"

# give ztunnel/Calico a moment to converge on the new policies
sleep 5

# --- 4. verify ----------------------------------------------------------------
log "istioctl analyze (all namespaces):"
istioctl analyze -A || true

fail=0

log "verifying default-deny is in effect (denials appear as L4 resets, not HTTP 403):"

# 4a. in-mesh cross-namespace HTTP call should now be DENIED. ztunnel enforces L4 authz
# by RESETTING the connection, so curl fails (no HTTP response), NOT an HTTP 403.
# We assert curl FAILS (non-zero exit) rather than parsing a code, since a reset yields
# no code at all.
if kubectl -n clientspace exec netshoot -- curl -sS --max-time 5 productpage.bookinfo:9080/productpage -o /dev/null 2>/dev/null; then
  warn "expected connection reset under default-deny, but the call SUCCEEDED"; fail=1
  log "  clientspace/netshoot -> productpage.bookinfo:9080 = SUCCESS (unexpected!)"
else
  log "  clientspace/netshoot -> productpage.bookinfo:9080 = reset/denied (expected)"
fi

# 4b. bookinfo INGRESS route: the gateway can reach the mesh, but productpage's
# default-deny resets the upstream, which kgateway surfaces to the client as HTTP 503.
ing="$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' -H 'Host: bookinfo.localhost' http://localhost:9090/productpage 2>/dev/null || echo 000)"
log "  ingress bookinfo.localhost -> productpage = ${ing} (expect 503: upstream denied)"
case "$ing" in 503|000) : ;; *) warn "expected 503/000 at ingress under default-deny, got ${ing}"; fail=1;; esac

# 4c. redis (L4/TCP) should now be DENIED for the trusted client (was PONG in plan 04).
rc="$(kubectl -n clientspace exec trusted -- sh -c 'redis-cli -h redis.dataspace ping 2>&1 || true' 2>/dev/null | tr -d '\r')"
log "  clientspace/trusted -> redis.dataspace:6379 ping = '${rc}' (expect a reset error, NOT 'PONG')"
[ "$rc" != "PONG" ] || { warn "expected redis to be denied under default-deny, got PONG"; fail=1; }

# 4d. same-namespace traffic must STILL work (NetworkPolicy allows intra-ns): redis local.
loc="$(kubectl -n dataspace exec deploy/redis -- sh -c 'redis-cli -h 127.0.0.1 ping 2>&1 || true' 2>/dev/null | tr -d '\r')"
log "  dataspace redis local ping = '${loc}' (expect PONG: same-ns not blocked)"
[ "$loc" = "PONG" ] || { warn "same-namespace traffic unexpectedly blocked, got '${loc}'"; fail=1; }

# 4e. DNS must STILL resolve (egress left open so kube-dns is reachable).
dns="$(kubectl -n clientspace exec netshoot -- sh -c 'nslookup redis.dataspace >/dev/null 2>&1 && echo ok || echo fail' 2>/dev/null | tr -d '\r')"
log "  clientspace DNS resolution = '${dns}' (expect ok)"
[ "$dns" = "ok" ] || { warn "DNS resolution broke under the baseline"; fail=1; }

log "verifying the observability UIs are UNAFFECTED (not mesh-enrolled, no policy):"
for h in grafana.localhost prometheus.localhost alertmanager.localhost kiali.localhost; do
  c="$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' -H "Host: $h" -L http://localhost:9090/ 2>/dev/null || echo 000)"
  log "  http://$h/ -> ${c}"
  case "$c" in 200|30*) : ;; *) warn "UI $h returned ${c} (expected 200/30x)"; fail=1;; esac
done

log "verifying the gateway health endpoint still works (needs the PERMISSIVE :80 exception):"
ping="$(curl -sS --max-time 5 http://localhost:9090/.gw/ping 2>/dev/null || echo ERR)"
log "  /.gw/ping -> '${ping}' (expect PONG)"
[ "$ping" = "PONG" ] || { warn "expected PONG from /.gw/ping, got '${ping}'"; fail=1; }

[ "$fail" = 0 ] || die "plan 05 verification had failures (see warnings above)"

log "plan 05 complete: STRICT mTLS + default-deny baseline in place and verified."
log "  bookinfo/cross-ns/redis now DENIED by design; feature plans 06-10 add minimal ALLOWs."
log "  observability UIs + gateway health endpoint remain reachable."
log "next: plans/06-feature-ns-isolation.md"
