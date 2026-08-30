[← Docs index](../README.md) · **Operation Long Haul v5**

_(start)_  ·  [ADRs →](01-adrs.md)

---

# Operation Long Haul v5 — Production-Grade Homelab Foundation

> **How to use this document:** Work through tiers sequentially. Each tier has a clear purpose, internal phasing, and verification gates. Do not advance to the next tier until verification passes. The tier structure mirrors the architecture itself — Tier 0 is the substrate everything else stands on.
>
> **What changed from v4 (this revision):**
> - **Management plane migrated RKE2 → Talos Linux.** `homelab-mgmt` is now a 3-node immutable, API-managed (no SSH, no shell, no package manager) Talos cluster. Workload clusters (`homelab-prod`, `homelab-dev`) stay on RKE2 with the CIS profile — they remain the hardening/compliance rehearsal surface. See ADR-001.
> - **GitOps consolidated on Flux.** ArgoCD, ApplicationSets, and Argo Rollouts are removed. Flux (GitRepository + Kustomization + HelmRelease) reconciles every cluster; **Flagger** provides canary/blue-green progressive delivery in place of Argo Rollouts. **Argo Workflows and Argo Events are retained only inside Tier 5 MLOps** for event-driven pipelines — they are decoupled from GitOps, which is the rule for keeping any Argo component. See ADR-002 and ADR-003.
> - **Zarf added** for declarative air-gapped package delivery (image + manifest + Helm bundles deployed via `zarf package deploy`). It complements the existing Harbor pull-through mirror and is exercised hard by the new ephemeral air-gap drills. See ADR-005.
> - **Ephemeral environments introduced** — GitOps-driven and on-demand: in-cluster PR-preview namespaces (Flux) *and* disposable Talos clusters provisioned on the new NUC capacity via OpenTofu, bootstrapped by Flux, fed by Zarf. Stood up for a drill, torn down after. See ADR-004 and the new "Ephemeral Environments" section.
> - **Terraform → OpenTofu everywhere** *(v5.1 revision)*. The `tofu` CLI executes all environments, not just ephemeral — repo name, HCL, state, and providers unchanged. See ADR-007.
> - **HashiCorp Vault → OpenBao** *(v5.1 revision)*. The secrets substrate now runs **OpenBao 2.6.x** — the Linux Foundation, API-compatible OSS fork of Vault. Hostnames, DNS, and `pass` paths keep the `vault-*` naming; the CLI is `bao`, the service is `openbao`. GCP KMS auto-unseal unchanged (with a hard seal-plugin migration gate before 2.7 — see Phase 0.6 and Future Upgrades). See ADR-006.
> - **Hardware inventory reconciled** to current reality: 2× NUC added as `pve-03`/`pve-04` (ephemeral capacity); the M920q workers and second M920x enumerated. *(v5.2 subsequently virtualizes the M920q/M920x #2 — see the Proxmox-on-every-node bullet below.)*
> - **Proxmox on every physical node** *(v5.2 revision)*. The three M920q homelab-prod workers and M920x #2 no longer run bare-metal Ubuntu — **every physical machine runs Proxmox VE, and every Kubernetes node is an OpenTofu-provisioned VM.** M920x #2 is assigned as `pve-05`; the M920q trio become `pve-06`/`pve-07`/`pve-08`, each hosting one homelab-prod node VM. This deletes the last manual OS install (the old baremetal Phase 1.4), makes the whole fleet reproducible and snapshottable, and gives noVNC console access to every node. See ADR-008.
> - **Project tracking bootstrapped on Huly** *(v5.2)*. A single Docker-Compose Huly VM is stood up right after Proxmox + the management VLAN (Tier 0 Phase 0.1–0.2) and **before** OpenBao — a deliberate second manual-provisioning exception (sibling to the Vault VMs) — so the whole build is tracked as Milestones/Epics/Stories from phase one. See [`../bootstrap/huly-bootstrap.md`](../bootstrap/huly-bootstrap.md) and the Tier 0 interstitial.
> - **A new "Architecture Decision Records" section** captures the reasoning behind each change above.
>
> **What changed from v3:**
> - **Naming standardized.** LOTR-themed names retired for functional names (`fellowship` → `homelab-prod`, `gandalf` → `prod-cp-01`, etc.). See `naming-conventions.md` for the canonical schema and rename table.
> - **k3s → RKE2** with CIS profile, encryption-at-rest, audit policy (production hardening)
> - **Two workload clusters** (homelab-prod, homelab-dev) on physically separate hypervisors
> - **homelab-mgmt upgraded from single-node to 3-node** for real HA of platform services
> - **L2 announcements → BGP** with redundant VyOS speakers (bgp-01, bgp-02)
> - **Vault promoted from workload pod to platform substrate** — 3-VM HA cluster outside Kubernetes, auto-unsealed via GCP KMS, owns PKI/Transit/SSH/Database engines from day one
> - **`ansible-vault` retired entirely** — Ansible authenticates to Vault via AppRole; secret_id stored in `pass`
> - **Harbor as the platform registry** with Cosign signing keys in Vault Transit
> - **Air-gapped patterns** for workload clusters (all pulls via Harbor; no direct internet from prod/dev nodes)
> - **Argo Rollouts + ApplicationSets** for real progressive delivery across environments *(superseded in v5 → Flagger + Flux overlays; see ADR-002)*
> - **Renovate Bot, Kyverno (audit→enforce), Falco+Tetragon, CloudNativePG, Tempo, k6-operator, Chaos Mesh** all promoted from "upgrades" to first-class foundation
> - **Production hygiene additions (v4 revision):** etcd snapshot off-host replication with Object Lock (1.11), ExternalDNS (2.7), SBOM via Syft + Cosign attestation (2.15), Alloy on substrate VMs (3.5), audit log immutable retention (3.12), OpenCost cost attribution (3.15), Argo Events (4.3 — removed in v5, see ADR-003)
> - **MLOps platform** added as Tier 5 (see separate doc); five core personal apps (Vaultwarden, n8n, NetBox, Forgejo, Immich) deferred to post-Tier-5
>
> **Repos involved (unchanged from v3):**
> - `homelab-gitops` — All Kubernetes manifests, Helm values, Flux config (GitRepository, Kustomization, HelmRelease, Flagger Canary)
> - `homelab-ansible` — OS-level configuration for all nodes and VMs
> - `homelab-terraform` — Proxmox VM provisioning via bpg/proxmox provider
>
> **Project tracking:** Huly (bootstrap VM → later migrated to `homelab-mgmt`) — see [`../bootstrap/huly-bootstrap.md`](../bootstrap/huly-bootstrap.md) and [`../../huly/work-breakdown.md`](../../huly/work-breakdown.md).
>
> **Cluster & host naming:**
> - **homelab-prod** (prod) — prod-cp-01 (CP), prod-w-01 (W1), prod-w-02 (W2), prod-w-03 (W3 — VM)
> - **homelab-dev** (dev/staging) — dev-cp-01 (CP), dev-w-01 (W1), dev-w-02 (W2) — all VMs on the new M920x
> - **homelab-mgmt** — 3-node HA **Talos** cluster: mgmt-01, mgmt-02, mgmt-03 (VMs; API-managed via `talosctl`, no SSH)
> - **Vault HA** — vault-01, vault-02, vault-03 (dedicated VMs running **OpenBao**, outside Kubernetes; hostnames keep `vault-*` naming — ADR-006)
> - **BGP routers** — bgp-01, bgp-02 (VyOS VMs, one per hypervisor)
> - **Storage** — nfs-01 (VM), garage-01 (LXC container)
> - **Ephemeral** — `eph-<purpose>-<n>` (disposable Talos clusters, OpenTofu-provisioned on pve-03/pve-04, no standing footprint)
>
> **Hypervisor inventory (v5.2 — Proxmox on every physical node):**
> - **pve-01** — ThinkCentre M920 SFF (64GB / 1TB) — platform-adjacent (mgmt + prod-adjacent VMs)
> - **pve-02** — ThinkCentre M920x #1 (32GB / 1TB) — dev/staging
> - **pve-03 / pve-04** — 2× NUC *(v5)* — ephemeral-env capacity (normally idle)
> - **pve-05** — ThinkCentre M920x #2 (32GB / 1TB) *(v5.2 — role assigned)* — spare capacity + quorum redistribution target (see the single-hypervisor-failure note below)
> - **pve-06 / pve-07 / pve-08** — 3× ThinkCentre M920q (16GB / 512GB each) *(v5.2 — were bare-metal Ubuntu)* — each hosts exactly one homelab-prod node VM (prod-cp-01, prod-w-01, prod-w-02)
>
> *(v5.2: the M920q trio and M920x #2 now run Proxmox VE rather than bare-metal Ubuntu — every Kubernetes node is a VM. See ADR-008.)*

---

## Architecture at a Glance

```
                          ┌─────────────────────────────────┐
                          │       Edge Router (existing)    │
                          │   Static routes → bgp-vrrp-ip   │
                          └────────────────┬────────────────┘
                                           │
                          ┌────────────────┴────────────────┐
                          │   bgp-01 / bgp-02 (VyOS, VRRP)  │
                          │  BGP speakers — iBGP between    │
                          │  themselves, eBGP to clusters   │
                          └────────────────┬────────────────┘
                                           │
            ┌──────────────────┬───────────┴───────────┬──────────────────┐
            │                  │                       │                  │
   ┌────────┴────────┐ ┌───────┴────────┐    ┌─────────┴────────┐ ┌───────┴────────┐
   │  homelab-prod   │ │  homelab-dev   │    │   homelab-mgmt   │ │ vault-01/02/03 │
   │   (prod RKE2)   │ │ (dev/stg RKE2) │    │  (3-node Talos)  │ │  (OpenBao HA)  │
   │  4 VMs, M920q+  │ │  3 VMs, M920x  │    │  Obs + Keycloak  │ │ Raft + GCP KMS │
   └─────────────────┘ └────────────────┘    └──────────────────┘ └────────────────┘
            │                  │                       │                  │
            └──────────────────┴───────────┬───────────┴──────────────────┘
                                           │
                          ┌────────────────┴────────────────┐
                          │   Shared storage tier (VLAN 40) │
                          │   nfs-01 (ZFS) + garage-01 S3   │
                          └─────────────────────────────────┘
```

> **v5 topology notes:** `homelab-mgmt` runs **Talos** (immutable, API-managed); workload clusters stay **RKE2**. **Flux** reconciles all three from `homelab-gitops` (no ArgoCD). Disposable **ephemeral Talos clusters** spin up on pve-03/pve-04 on demand (OpenTofu + Flux + Zarf) and are not shown above because they have no standing footprint. **Flagger** handles progressive delivery on the workload clusters.
>
> **v5.2 note:** every physical box now runs Proxmox — the homelab-prod nodes shown as "4 VMs" are OpenTofu-provisioned VMs (one per M920q on pve-06/07/08, plus prod-w-03 on pve-01), not bare metal. See ADR-008.

---

## Pre-Flight: Decisions Locked In

Confirm alignment before starting:

- [ ] **Hypervisors:** every physical box runs Proxmox VE — pve-01 (M920 SFF, 64GB/1TB) + pve-02 (M920x #1, 32GB/1TB) + pve-03/pve-04 (2× NUC, ephemeral capacity) + pve-05 (M920x #2, 32GB/1TB) + pve-06/pve-07/pve-08 (3× M920q, 16GB/512GB, one homelab-prod node VM each). No clustering between any of them (clean failure boundary). *(v5.2: M920q + M920x #2 moved from bare-metal Ubuntu to Proxmox — every K8s node is now a VM. See ADR-008.)*
- [ ] **CNI:** Cilium on both workload clusters, BGP control plane enabled, kube-proxy replacement, Gateway API
- [ ] **K8s distribution (workloads):** RKE2 with `profile: cis`, secrets encryption-at-rest, audit policy enabled (homelab-prod, homelab-dev)
- [ ] **K8s distribution (management):** **Talos Linux** — immutable, API-managed (no SSH/shell/package manager), 3-node HA (homelab-mgmt). *(v5 change — ADR-001)*
- [ ] **Load balancing:** Cilium BGP advertising LB IPs to VyOS (replaces v3's L2 announcements)
- [ ] **Ingress:** Cilium Gateway API
- [ ] **GitOps (all clusters):** **Flux** (GitRepository + Kustomization + HelmRelease). Env promotion via kustomize overlays + per-cluster Kustomizations. *(v5: consolidated from ArgoCD — ADR-002)*
- [ ] **Progressive delivery:** **Flagger** (Flux-native canary / blue-green), replacing Argo Rollouts. *(v5 change — ADR-002)*
- [ ] **Storage (file):** NFS backed by ZFS on dedicated VM, CSI via `csi-driver-nfs`
- [ ] **Storage (object):** Garage (S3-compatible) in LXC
- [ ] **Secrets substrate:** **OpenBao** HA cluster (3 VMs, Raft, GCP KMS auto-unseal), pinned 2.6.x — PKI, Transit, SSH OTP, Database, KV v2 engines configured at bootstrap *(v5.1: HashiCorp Vault → OpenBao — ADR-006)*
- [ ] **Secrets delivery into K8s:** ESO pointed at Vault on every cluster
- [ ] **Workstation credentials:** `pass` (GPG-encrypted Git store) for kubeconfigs and Vault AppRole `secret_id`. No `ansible-vault`. No GCP SM for application secrets.
- [ ] **Workstation toolchain:** pinned per-repo via **mise** — a `.mise.toml` committed to each of the three repos locks the tool versions this doc was written against (talosctl, kubectl, flux, tofu, bao, zarf, helm, cosign, syft, k6, ansible, ...). A months-long build with fifteen CLIs drifts otherwise. Nix is deliberately deferred to a future spike (see Future Upgrades) — mise already covers per-project version pinning. *(v5.1)*
- [ ] **Version pins:** every version in this doc (`--version` flags, HelmRelease `version:` fields, chart/app pins) was current at writing (Aug 2026) — **verify the latest stable at build time for each phase** and update the pin then. The only deliberate ceiling is OpenBao 2.6.x (seal-plugin gate — ADR-006). *(v5.1)*
- [ ] **TLS (internal):** Vault PKI issuer via cert-manager, short-lived certs (≤24h)
- [ ] **TLS (public):** cert-manager + Let's Encrypt + Cloudflare DNS-01
- [ ] **Tunnel:** Cloudflared
- [ ] **Registry:** Harbor on homelab-prod, Cosign signing keys in Vault Transit
- [ ] **Policy:** Kyverno from Tier 2, audit mode initially, enforce after stabilization
- [ ] **Observability:** Prometheus + Loki + Grafana + Tempo + Alertmanager on homelab-mgmt (HA)
- [ ] **Runtime security:** Falco + Cilium Tetragon, events to homelab-mgmt Loki
- [ ] **Identity:** Keycloak on homelab-mgmt; OIDC for Grafana, Vault UI, Harbor, and the Flux UI (Weave GitOps / Capacitor); break-glass admin retained on every integration. *(v5: ArgoCD OIDC removed)*
- [ ] **Delivery:** Flagger for canary releases, k6-operator + Chaos Mesh for load/chaos testing. *(v5: Argo Rollouts → Flagger)*
- [ ] **Database:** CloudNativePG operator; dynamic credentials via Vault Database engine
- [ ] **DR:** Velero to Garage S3, scheduled + tested restore procedures
- [ ] **Air-gap muscle:** workload clusters (homelab-prod, homelab-dev) pull only from Harbor; homelab-mgmt permitted upstream pulls for bootstrap simplicity
- [ ] **Air-gap delivery:** **Zarf** for declarative offline package bundles (`zarf package create` / `deploy`), layered on top of the Harbor mirror; primary tool for the ephemeral air-gap drills. *(v5 new — ADR-005)*
- [ ] **Ephemeral environments:** GitOps-driven, on-demand — in-cluster PR-preview namespaces (Flux) + disposable Talos clusters on pve-03/pve-04 (OpenTofu + Flux + Zarf), torn down after each drill. *(v5 new — ADR-004)*

---

