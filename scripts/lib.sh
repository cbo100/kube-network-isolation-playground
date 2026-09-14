#!/usr/bin/env bash
# Shared helpers for kubesandboxing bootstrap scripts.
# Source this file: `. "$(dirname "$0")/lib.sh"`
set -euo pipefail

# ---- pinned versions ---------------------------------------------------------
export CLUSTER_NAME="cluster"                 # kind name (context: kind-cluster)
export KIND_CONTEXT="kind-${CLUSTER_NAME}"
# Highest Kubernetes version pre-built for kind v0.33.0, digest-pinned for reproducibility
# (per the v0.33.0 release notes). Override by exporting K8S_NODE_IMAGE before running.
# Other pre-built options for kind v0.33.0:
#   v1.36.4  @sha256:099e049362a1526b2db71494e1947aae99bd16290d7c895f2b7ea312e3cbfaed
#   v1.35.8  @sha256:07b2536e30b803ed61d1677a79df6115f798ce64c80f9e22f6ed45afd09323c0
#   v1.34.11 @sha256:44e222ee2132dab25ff87301682f89eb82c7880ea3a1bf543bfe9708fd08d67d
export K8S_NODE_IMAGE="${K8S_NODE_IMAGE:-kindest/node:v1.37.0@sha256:a1ed56cfb0e7b93589bdf97c8cd566405a265939e3620fc4f5de89adff580ae5}"
export GATEWAY_API_VERSION="v1.6.1"
export KGATEWAY_VERSION="2.4.4"
export ISTIO_VERSION="1.31.0"

# ---- pretty logging ----------------------------------------------------------
_c() { printf '\033[%sm' "$1"; }
log()  { printf '%s[+]%s %s\n' "$(_c '1;32')" "$(_c 0)" "$*"; }
warn() { printf '%s[!]%s %s\n' "$(_c '1;33')" "$(_c 0)" "$*" >&2; }
err()  { printf '%s[x]%s %s\n' "$(_c '1;31')" "$(_c 0)" "$*" >&2; }
die()  { err "$*"; exit 1; }

# ---- guards ------------------------------------------------------------------
need() { command -v "$1" >/dev/null 2>&1 || die "required tool not found: $1"; }

# repo root regardless of where the script is invoked from
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT

# ---- local tooling via mise --------------------------------------------------
# Tool versions are pinned in mise.toml at the repo root. `mise_ensure` installs
# them; `istioctl` runs the pinned istioctl regardless of what's on PATH.
mise_ensure() {
  need mise
  ( cd "$REPO_ROOT" && mise install )
}
istioctl() { ( cd "$REPO_ROOT" && mise exec -- istioctl "$@" ); }

# ---- idempotent wait helpers -------------------------------------------------
# retry <attempts> <sleep_seconds> <cmd...>
retry() {
  local attempts=$1 sleep_s=$2; shift 2
  local i=1
  until "$@"; do
    if (( i >= attempts )); then return 1; fi
    warn "attempt $i/$attempts failed: $* (retry in ${sleep_s}s)"
    sleep "$sleep_s"; i=$((i+1))
  done
}

# wait_rollout <ns> <resource> — idempotent, tolerates not-yet-created
wait_rollout() {
  local ns=$1 res=$2
  retry 30 5 kubectl -n "$ns" rollout status "$res" --timeout=20s
}
