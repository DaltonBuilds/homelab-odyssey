[← Docs index](../README.md) · **Operation Long Haul v5**

[← Tier 5 · MLOps](tier-5-mlops.md)  ·  [Future Upgrades →](future-upgrades.md)

---

# Ephemeral Environments (GitOps-Driven)

Two complementary patterns, both reconciled by Flux and both built to be created on demand and destroyed without ceremony (ADR-004). This is the under-practiced production muscle — especially the air-gapped bring-up — using spare fleet capacity rather than dedicated machines (ADR-012).

## Pattern A — In-cluster PR-preview namespaces (homelab-dev)

**What:** every open PR against an app gets its own namespace on homelab-dev, deployed by Flux, reaped when the PR merges or closes. No new cluster — just isolated namespaces.

**How:**
- A small GitHub Action, on `pull_request`, writes `apps/<app>/previews/pr-<n>/` (a kustomization overlaying `base` with `namespace: <app>-pr-<n>` and the PR's image tag) and commits a Flux `Kustomization` under `clusters/homelab-dev/previews/`.
- Flux reconciles the new path within its interval; the preview is live at `https://<app>-pr-<n>.homelab-dev.homelab.internal` (ExternalDNS + Gateway API wildcard from Phases 2.6/2.7).
- On `closed`, the Action deletes the directory; Flux prunes the namespace (`prune: true`).

**Guardrails:** previews are dev-only, get a tight `ResourceQuota` + `LimitRange`, a max-TTL janitor CronJob (deletes preview namespaces older than N days as a backstop for abandoned PRs), and a Kyverno policy keeps them off prod nodes.

```yaml
# clusters/homelab-dev/previews/pr-417.yaml  (written by CI, reconciled by Flux)
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata: { name: hello-otel-pr-417, namespace: flux-system }
spec:
  interval: 2m
  path: ./apps/hello-otel/previews/pr-417
  prune: true
  sourceRef: { kind: GitRepository, name: flux-system }
  targetNamespace: hello-pr-417
  wait: true
  timeout: 5m
```

## Pattern B — Disposable Talos clusters on available fleet capacity (air-gap drills)

**What:** a whole throwaway Kubernetes cluster — its own Talos control plane — provisioned on a capacity-checked existing host for a specific exercise (an air-gap rehearsal, a Talos/Cilium upgrade test, a Big Bang bring-up), then `tofu destroy`-ed. Nothing about it is permanent.

**Capacity gate:** select an existing host only after checking CPU, RAM, disk, and standing workload headroom; add VLAN 70 along its network path. Do not disrupt platform quorum workloads for a drill. Defer if no capacity is available.

**Provisioning loop:**

1. **OpenTofu** stands up the VM(s) on a capacity-checked existing host from the Talos image and applies a machine config (the same talosctl pattern as Phase 1.10, parameterized). One control-plane node is fine for a disposable cluster; add workers only if the drill needs them.

```hcl
# homelab-terraform/environments/ephemeral/main.tf
module "eph_cluster" {
  source         = "../../modules/talos-cluster"   # v5.1: NOT YET WRITTEN — Tier 1 only defines
                                                   # modules/proxmox-vm. Factor the Phase 1.10
                                                   # talosctl bring-up into this module first.
  cluster_name   = var.eph_name             # e.g. "eph-airgap-01"
  hypervisor     = var.eph_host             # confirmed host with spare capacity; never an unowned NUC
  vlan_id        = 70                        # ephemeral VLAN
  control_planes = 1
  workers        = var.eph_workers
  talos_secrets  = data.vault_kv_secret_v2.eph.data   # generated per-cluster, discarded on destroy
}
```

2. **Bootstrap + Flux.** `talosctl bootstrap`, pull the kubeconfig, then point Flux at a dedicated path (`clusters/ephemeral/<name>/`). For a *connected* drill, Flux pulls from GitHub as usual.

3. **Air-gap variant — Zarf.** For an air-gap drill the disposable cluster gets **no internet**. A Zarf package built earlier (`zarf package create`, carrying Cilium + Flux + a local Forgejo mirror + the workload) is delivered by `zarf package deploy` from a USB stick or a Garage-hosted tarball. After deploy, Flux reconciles from the *local* Forgejo mirror — the cluster is fully GitOps-managed and has never touched the internet. This is the DoD/Platform One workflow in miniature (ADR-005).

4. **Teardown.** `tofu destroy` removes the VMs; the per-cluster Talos secrets in Vault are deleted; the `clusters/ephemeral/<name>/` path is removed so Flux forgets it. No residue.

**Why this is worth building:** the skills that *don't* transfer from standing-cluster experience are exactly here — generating throwaway PKI, bringing a cluster up with zero internet, validating that a Zarf bundle actually contains everything it needs, and tearing down cleanly so the next drill starts from nothing. Run it as a timed exercise: "from `tofu apply` to a working air-gapped app, how long?"

### Verification (run per drill)

- [ ] `tofu apply` brings up the ephemeral Talos cluster on a capacity-checked existing host; `talosctl health` passes
- [ ] Connected variant: Flux reconciles from GitHub; the app is live on the ephemeral VLAN
- [ ] Air-gap variant: with egress blocked, `zarf package deploy` brings up Cilium + Flux + app, and Flux then reconciles from the local Forgejo mirror with zero internet pulls
- [ ] `tofu destroy` leaves no VMs, no Vault secrets, and no lingering Flux Kustomization
- [ ] PR-preview: opening a PR creates the `<app>-pr-<n>` namespace on homelab-dev; closing it prunes the namespace

---

