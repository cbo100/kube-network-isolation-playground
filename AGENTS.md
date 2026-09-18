# AGENTS.md

Guidance for AI agents working in this repo (kube-network-isolation-playground).

## What this repo is
A local, scriptable **kind** cluster demonstrating **Istio ambient mesh** network
isolation/identity features, fronted by **kgateway** (Gateway API) with **Calico** as the
CNI (for enforced `NetworkPolicy`). Everything is version-pinned and driven by idempotent
`scripts/NN-*.sh` + declarative `manifests/NN-*/`. Plans live in `plans/`.

- Verify the whole isolation matrix any time with `./scripts/verify-isolation.sh`
  (exits non-zero on any mismatch; safe to re-run / `watch`).
- Istioctl is pinned via `mise`; run it as `mise exec -- istioctl ...` from the repo root
  (see `scripts/lib.sh`).

## Operational notes / gotchas

### Recovering after the cluster has been idle/suspended for a while (expired mTLS)
**Symptom:** `bookinfo.localhost:9090` returns **503**, and `verify-isolation.sh` shows many
mismatches that **flap between runs** (same identity/policy, different result per pod). All
in-mesh traffic resets while non-mesh egress (e.g. `netshoot -> example.org`) still works.

**Root cause:** ztunnel mints **short-lived workload SVIDs**. If the laptop/VM was suspended
longer than the cert lifetime, the certs expire and rotation stalls. ztunnel logs show:
`error="... certificate expired ..."` and `tls handshake error: AlertReceived(CertificateExpired)`.
After a node restart, identity re-issuance can be **partial** — some pods come up with **no
`src.identity`** in ztunnel logs and get `explicitly denied by istio_converted_static_strict`.
That per-pod inconsistency is why the matrix looks "swapped"/random.

**Fix (no manifest changes needed):**
1. Restart the kind node containers (Podman here):
   `podman restart cluster-worker cluster-worker2 cluster-control-plane`
   then wait for the apiserver + `istiod`/`ztunnel` rollouts.
2. Recreate the **workloads** so ztunnel re-provisions fresh SVIDs cleanly:
   ```sh
   kubectl -n bookinfo rollout restart deploy
   kubectl -n dataspace rollout restart deploy
   # the clientspace trusted/untrusted/netshoot are bare Pods, not Deployments:
   kubectl -n clientspace delete pod trusted untrusted netshoot
   kubectl apply -f manifests/04-apps/clients.yaml
   ```
3. Confirm: ztunnel has **zero** errors in the last 60s
   (`kubectl -n istio-system logs ds/ztunnel --since=60s | grep -c error`), ingress returns
   **200**, and `./scripts/verify-isolation.sh` passes all cells.

**Debugging tip:** the deciding signal is the ztunnel access log. A rejected connection with
**no `src.identity`** = missing/expired workload cert (recreate the pod). A rejection with
`RBAC`/`policy rejection` but a present identity = an actual AuthorizationPolicy decision.

**Don't** chase individual flapping cells or change policies/manifests to "fix" this — it's a
cert-lifecycle artifact of a suspended local cluster, not a regression.
