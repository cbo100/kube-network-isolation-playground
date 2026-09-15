#!/usr/bin/env bash
# Reusable isolation probe — prints the LIVE allow/deny matrix for EVERY identity-based
# rule the mesh enforces (plans 05–10), any time you run it (not just during a feature
# script). Each cell is probed against real cluster state, so you can:
#   - run it after any plan to confirm the whole matrix,
#   - apply/remove an AuthorizationPolicy and re-run to watch a cell flip,
#   - `watch -n2 scripts/verify-isolation.sh` to see changes in real time,
#   - use it as a regression gate (non-zero exit on ANY mismatch).
#
# COVERAGE (every enforced rule):
#   dataspace (plan 09, raw TCP):
#     redis:6379, postgres:5432  <- ONLY clientspace/trusted-client
#   bookinfo ingress + internal call graph (plans 06/07/10, HTTP L4):
#     ingress(http SA) -> productpage        (allow; others denied)
#     productpage -> details, reviews         (allow)
#     reviews -> ratings                      (allow, via plan 07 DENY exception)
#     details -> ratings, details -> reviews  (DENIED — least privilege)
#     productpage -> ratings                  (DENIED — ratings accepts only reviews)
#     clientspace -> productpage (allow) / otherspace -> productpage (denied) (plan 06)
#     ratings: only trusted-client + reviews  (plan 07 DENY)
#   egress via waypoint (plan 08, per-identity external allow-list):
#     trusted   -> tcpbin.com:4242 (TCP) + example.com:443 (HTTPS)  [allowed]
#     untrusted -> en.wikipedia.org:443 (HTTPS)                     [allowed]
#     cross/other combinations                                     [denied]
#     UNDECLARED host (example.org) -> reachable by ALL             [plan 11 limitation]
#
# Sources are distinct SPIFFE identities under STRICT mTLS (plan 05); matches are on the
# authenticated source principal, un-spoofable by IP/namespace/header.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

need kubectl
kubectl config use-context "$KIND_CONTEXT" >/dev/null

# =============================================================================
# probes — each echoes "ok" (reachable) or "no" (blocked/reset). Short timeouts so a
# mesh deny (connection reset / TLS error) returns quickly instead of hanging.
# =============================================================================

# ---- clientspace/dataspace clients (image ships redis-cli/psql/curl/nc) -------
probe_redis() { # <ns> <pod>
  kubectl -n "$1" exec "$2" -- sh -c \
    'out=$(redis-cli -h redis.dataspace ping 2>/dev/null | tr -d "\r"); [ "$out" = "PONG" ] && echo ok || echo no' \
    2>/dev/null || echo no
}
probe_postgres() { # <ns> <pod>
  kubectl -n "$1" exec "$2" -- sh -c \
    'out=$(psql "postgresql://app:app@postgres.dataspace:5432/app?connect_timeout=3" -tAc "select 1" 2>/dev/null | tr -d "\r" | head -1); [ "$out" = "1" ] && echo ok || echo no' \
    2>/dev/null || echo no
}
probe_http() { # <ns> <pod> <host:port/path>  — HTTP 200 => ok, else no
  kubectl -n "$1" exec "$2" -- sh -c \
    "code=\$(curl -s -o /dev/null -m 4 -w '%{http_code}' http://$3 2>/dev/null); [ \"\$code\" = 200 ] && echo ok || echo no" \
    2>/dev/null || echo no
}
probe_https() { # <ns> <pod> <url>  — HTTPS 200 => ok (deny shows as TLS error / 000)
  kubectl -n "$1" exec "$2" -- sh -c \
    "code=\$(curl -s -o /dev/null -m 10 -w '%{http_code}' $3 2>/dev/null); [ \"\$code\" = 200 ] && echo ok || echo no" \
    2>/dev/null || echo no
}
probe_tcp_echo() { # <ns> <pod> <host> <port>  — echo server returns our payload => ok
  kubectl -n "$1" exec "$2" -- sh -c \
    "out=\$(printf 'ping\n' | nc -w 6 $3 $4 2>/dev/null | tr -d '\r' | head -1); [ \"\$out\" = ping ] && echo ok || echo no" \
    2>/dev/null || echo no
}

# ---- in-mesh HTTP from bookinfo pods (no curl/wget in those images) -----------
# details is ruby; productpage/reviews are python. Both attempt a real GET so a ztunnel
# reset (which can occur AFTER the socket opens) is correctly observed as "no".
probe_ruby_http() { # <deploy> <host:port/path>
  kubectl -n bookinfo exec "deploy/$1" -- ruby -e '
    require "net/http"; require "uri"
    begin; Net::HTTP.get_response(URI("http://"+ARGV[0])); puts "ok"
    rescue => e; puts "no"; end' "$2" 2>/dev/null || echo no
}
probe_py_http() { # <deploy> <host:port/path>
  kubectl -n bookinfo exec "deploy/$1" -- python -c '
import sys, urllib.request
try:
    urllib.request.urlopen("http://"+sys.argv[1], timeout=4); print("ok")
except Exception: print("no")' "$2" 2>/dev/null || echo no
}
probe_curl_http() { # <deploy> <host:port/path>  (for bookinfo pods that ship curl, e.g. reviews)
  kubectl -n bookinfo exec "deploy/$1" -- sh -c \
    "code=\$(curl -s -o /dev/null -m 4 -w '%{http_code}' http://$2 2>/dev/null); [ \"\$code\" = 200 ] && echo ok || echo no" \
    2>/dev/null || echo no
}

# =============================================================================
# matrix runner
# =============================================================================
fail=0
row() { # <label> <observed> <expected>
  local mark colour
  if [ "$2" = "$3" ]; then mark="ok"; colour='1;32'; else mark="MISMATCH"; colour='1;31'; fail=1; fi
  printf '  %-40s observed=%-3s expected=%-3s %s%s%s\n' \
    "$1" "$2" "$3" "$(_c "$colour")" "$mark" "$(_c 0)"
}

# ---- plan 09: raw TCP data services -----------------------------------------
log "dataspace redis:6379 (raw TCP) — ONLY trusted-client (plan 09):"
row "clientspace/trusted   -> redis"   "$(probe_redis clientspace trusted)"   ok
row "clientspace/untrusted -> redis"   "$(probe_redis clientspace untrusted)" no
row "clientspace/netshoot  -> redis"   "$(probe_redis clientspace netshoot)"  no

log "dataspace postgres:5432 (raw TCP) — ONLY trusted-client (plan 09):"
row "clientspace/trusted   -> postgres" "$(probe_postgres clientspace trusted)"   ok
row "clientspace/untrusted -> postgres" "$(probe_postgres clientspace untrusted)" no
row "clientspace/netshoot  -> postgres" "$(probe_postgres clientspace netshoot)"  no

# ---- plan 06: namespace isolation into bookinfo ------------------------------
log "bookinfo productpage:9080 — clientspace allowed, otherspace denied (plan 06):"
row "clientspace/trusted   -> productpage" "$(probe_http clientspace trusted   productpage.bookinfo:9080/productpage)" ok
row "clientspace/untrusted -> productpage" "$(probe_http clientspace untrusted productpage.bookinfo:9080/productpage)" ok
row "otherspace/netshoot   -> productpage" "$(probe_http otherspace  netshoot  productpage.bookinfo:9080/productpage)" no

# ---- plan 07: ratings restricted -------------------------------------------
log "bookinfo ratings:9080 — external clients: ONLY trusted-client (plan 07 DENY):"
row "clientspace/trusted   -> ratings" "$(probe_http clientspace trusted   ratings.bookinfo:9080/ratings/0)" ok
row "clientspace/untrusted -> ratings" "$(probe_http clientspace untrusted ratings.bookinfo:9080/ratings/0)" no

# ---- plan 10: ingress + strict internal call graph --------------------------
log "bookinfo ingress -> app: only the kgateway ingress identity reaches productpage (plan 10):"
# End-to-end proof the ingress identity works: the public route renders the full page.
icode="$(curl -sS -o /dev/null -m 5 -w '%{http_code}' -H 'host: bookinfo.localhost' \
  'http://localhost:9090/productpage?u=normal' 2>/dev/null || echo 000)"
page="$(curl -sS -m 5 -H 'host: bookinfo.localhost' 'http://localhost:9090/productpage?u=normal' 2>/dev/null || true)"
row "ingress route -> productpage (HTTP 200)" \
  "$([ "$icode" = 200 ] && echo ok || echo no)" ok
row "  details panel populated" \
  "$(printf '%s' "$page" | grep -qi 'Error fetching product details' && echo no || echo ok)" ok
row "  reviews panel populated" \
  "$(printf '%s' "$page" | grep -qi 'Error fetching product reviews' && echo no || echo ok)" ok

log "bookinfo internal call graph — least privilege per identity (plan 10):"
row "productpage -> details"  "$(probe_py_http   productpage-v1 details:9080/details/0)"   ok
row "productpage -> reviews"  "$(probe_py_http   productpage-v1 reviews:9080/reviews/0)"   ok
row "reviews     -> ratings"  "$(probe_curl_http reviews-v1     ratings:9080/ratings/0)"   ok
row "details     -> ratings"  "$(probe_ruby_http details-v1     ratings:9080/ratings/0)"   no
row "details     -> reviews"  "$(probe_ruby_http details-v1     reviews:9080/reviews/0)"   no
row "productpage -> ratings"  "$(probe_py_http   productpage-v1 ratings:9080/ratings/0)"   no

# ---- plan 08: egress via waypoint (per-identity external allow-list) ---------
log "egress tcpbin.com:4242 (raw TCP echo) — ONLY trusted-client (plan 08):"
row "clientspace/trusted   -> tcpbin"   "$(probe_tcp_echo clientspace trusted   tcpbin.com 4242)" ok
row "clientspace/untrusted -> tcpbin"   "$(probe_tcp_echo clientspace untrusted tcpbin.com 4242)" no
row "clientspace/netshoot  -> tcpbin"   "$(probe_tcp_echo clientspace netshoot  tcpbin.com 4242)" no

log "egress example.com:443 (HTTPS) — ONLY trusted-client (plan 08):"
row "clientspace/trusted   -> example.com"   "$(probe_https clientspace trusted   https://example.com)" ok
row "clientspace/untrusted -> example.com"   "$(probe_https clientspace untrusted https://example.com)" no
row "clientspace/netshoot  -> example.com"   "$(probe_https clientspace netshoot  https://example.com)" no

log "egress en.wikipedia.org:443 (HTTPS) — ONLY untrusted-client (plan 08):"
row "clientspace/untrusted -> wikipedia"   "$(probe_https clientspace untrusted https://en.wikipedia.org/wiki/Main_Page)" ok
row "clientspace/trusted   -> wikipedia"   "$(probe_https clientspace trusted   https://en.wikipedia.org/wiki/Main_Page)" no
row "clientspace/netshoot  -> wikipedia"   "$(probe_https clientspace netshoot  https://en.wikipedia.org/wiki/Main_Page)" no

# ---- egress LIMITATION: undeclared hosts are NOT controlled ------------------
# example.org has NO ServiceEntry, so ztunnel does not route it through the egress
# waypoint and NO AuthorizationPolicy applies. In ambient, meshConfig
# outboundTrafficPolicy: REGISTRY_ONLY is NOT enforced by ztunnel (verified — see
# plans/11-investigate-ambient-registry-only.md), so the traffic egresses directly.
# The enforceable guarantee is therefore "for a DECLARED external service, only an
# approved identity may reach it" — NOT "block the rest of the internet". Expect ALL
# three identities to reach an undeclared host. If any of these ever flips to "no",
# an effective egress default-deny landed (REGISTRY_ONLY equivalent) — update this
# section and plan 11.
log "egress example.org:443 (HTTPS, UNDECLARED) — uncontrolled: ALL identities reach it (plan 11 limitation):"
row "clientspace/trusted   -> example.org (undeclared)" "$(probe_https clientspace trusted   https://example.org)" ok
row "clientspace/untrusted -> example.org (undeclared)" "$(probe_https clientspace untrusted https://example.org)" ok
row "clientspace/netshoot  -> example.org (undeclared)" "$(probe_https clientspace netshoot  https://example.org)" ok

if [ "$fail" = 0 ]; then
  log "isolation matrix matches ALL expected policy outcomes."
else
  die "isolation matrix has MISMATCHes (see above) — a policy changed or regressed."
fi
