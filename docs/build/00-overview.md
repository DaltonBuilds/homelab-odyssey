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
> - **Ephemeral environments introduced** — GitOps-driven and on-demand: in-cluster PR-preview namespaces (Flux) *and* disposable Talos clusters provisioned on available capacity in the confirmed fleet via OpenTofu, bootstrapped by Flux, fed by Zarf. Stood up for a drill, torn down after. See ADR-004 and the new "Ephemeral Environments" section.
> - **Terraform → OpenTofu everywhere** *(v5.1 revision)*. The `tofu` CLI executes all environments, not just ephemeral — repo name, HCL, state, and providers unchanged. See ADR-007.
> - **HashiCorp Vault → OpenBao** *(v5.1 revision)*. The secrets substrate now runs **OpenBao 2.6.x** — the Linux Foundation, API-compatible OSS fork of Vault. Hostnames, DNS, and `pass` paths keep the `vault-*` naming; the CLI is `bao`, the service is `openbao`. GCP KMS auto-unseal unchanged (with a hard seal-plugin migration gate before 2.7 — see Phase 0.6 and Future Upgrades). See ADR-006.
> - **Inventory correction (2026-09-12, ADR-012):** the earlier v5 NUC entries were erroneous. The owner confirmed seven machines, including the tower. The owner’s installed numbering is now pve-01 through pve-07 (2026-09-13); IPs stay with their physical machines.
> - **Proxmox on every physical node** *(v5.2 revision)*. The three M920q homelab-prod workers and M920x #2 no longer run bare-metal Ubuntu — **every physical machine runs Proxmox VE, and every Kubernetes node is an OpenTofu-provisioned VM.** M920x #2 is assigned as `pve-03`; the M920q trio become `pve-04`/`pve-05`/`pve-06`, each hosting one homelab-prod node VM. This deletes the last manual OS install (the old baremetal Phase 1.4), makes the whole fleet reproducible and snapshottable, and gives noVNC console access to every node. See ADR-008.
> - **Project tracking:** YouTrack Cloud project `Homelab` (`HOMELAB`); the YouTrack MCP integration is connected. See [work breakdown](work-breakdown.md).
> - **Identity tier re-litigated and retained** *(v5.3 revision)*. A proposal to replace Keycloak with **ZITADEL** was evaluated against both of the lab's missions and **rejected**; **authentik** was evaluated as the stronger challenger and also rejected, on governance longevity (Keycloak is CNCF/Apache 2.0; ZITADEL relicensed to AGPL-3.0 in 2025) and claim-shape portability. The ergonomic wins that motivated the challenge are recovered in place: **Keycloak Operator** instead of the now-unmaintained Bitnami chart, the realm **declarative from first apply** (deleting the old UI-bootstrap → `tofu import` dance), a capped JVM heap, and **oauth2-proxy** for forward-auth. A binding **identity portability contract** makes the decision cheap to revisit. See ADR-009 and ADR-010.
> - **A "Purpose & Mandate" section added** *(v5.3)* — the lab serves two missions (near-term defense-skills ramp; permanent personal dojo) and only the first had ever been written down, which was silently biasing decisions. See below.
> - **The workstation tower joins the fleet as `pve-07`; the MacBook Pro becomes the sole workstation** *(v5.4 revision)*. The seventh confirmed machine (Ryzen 9 7900X / 64GB / 2× 2TB WD_BLACK SN850X NVMe / **RTX 5070**) that had been sitting idle as a home-office daily driver is reassigned to the lab. This does four things at once: collapses the build to the **one** workstation its credential design always assumed, puts the **first GPU** in the fleet (deleting the "rent a `g5.xlarge` later" placeholder from Tier 5 and the vLLM spike), gives the fleet a native **amd64 build host** for ARC/Zarf work that would otherwise be emulated on an arm64 laptop, and **resolves the `pve-01` quorum concentration** that has been flagged as "needs your decision" since v5.1. See ADR-011.
> - **The quorum layout is now decided** *(v5.4)*: `vault-03` → `pve-03` and `mgmt-02` → `pve-07` *(renumbered 2026-10-28: vault-0N now lives on pve-0N)* — split across two *different* new hosts, so no single hypervisor loss can break either quorum. The failure-domain warning in the Network Reference is resolved rather than deferred.
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
> **Project tracking:** YouTrack Cloud, with self-hosting to be evaluated after the build. See [work breakdown](work-breakdown.md).
>
> **Cluster & host naming:**
> - **homelab-prod** (prod) — prod-cp-01 (CP), prod-w-01 (W1), prod-w-02 (W2), prod-w-03 (W3 — VM), **prod-gpu-01** (GPU worker, tainted — VM on pve-07) *(v5.4)*
> - **homelab-dev** (dev/staging) — dev-cp-01 (CP), dev-w-01 (W1), dev-w-02 (W2) — all VMs on the new M920x
> - **homelab-mgmt** — 3-node HA **Talos** cluster: mgmt-01, mgmt-02, mgmt-03 (VMs; API-managed via `talosctl`, no SSH). *(v5.4: mgmt-02 relocated pve-01 → pve-07.)*
> - **Vault HA** — vault-01, vault-02, vault-03 (dedicated VMs running **OpenBao**, outside Kubernetes; hostnames keep `vault-*` naming — ADR-006). *(v5.4: one node relocated off pve-01 to pve-03; renumbered 2026-10-28 so vault-01/02/03 live on pve-01/02/03.)*
> - **BGP routers** — bgp-01, bgp-02 (VyOS VMs, one per hypervisor)
> - **Storage** — nfs-01 (VM), garage-01 (LXC container)
> - **Ephemeral** — `eph-<purpose>-<n>` (disposable Talos clusters, OpenTofu-provisioned on a capacity-checked existing host, no standing footprint)
>
> **Hypervisor inventory (corrected 2026-09-12 — Proxmox on every physical node, seven hosts):**
> - **pve-01** — ThinkCentre M920 SFF (64GB / 2TB NVMe — recovered and rejoined 2026-10-10, HOMELAB-20) — platform-adjacent (mgmt + prod-adjacent VMs)
> - **pve-02** — ThinkCentre M920x #1 (32GB / 1TB) — dev/staging
> - **pve-03** — ThinkCentre M920x #2 (32GB / 1TB) *(v5.2 — role assigned)* — spare capacity; hosts the relocated **vault-03** *(v5.4; renumbered from vault-02 on 2026-10-28)*
> - **pve-04 / pve-05 / pve-06** — 3× ThinkCentre M920q (16GB / 512GB each) *(v5.2 — were bare-metal Ubuntu)* — each hosts exactly one homelab-prod node VM (prod-cp-01, prod-w-01, prod-w-02)
> - **pve-07** — Tower: ASRock AM5 / **Ryzen 9 7900X** (12c/24t) / **64GB** / **2× 2TB WD_BLACK SN850X NVMe (ZFS mirror, ~1.8TiB usable)** / **GeForce RTX 5070 12GB** *(v5.4 — was the home-office workstation)* — the fleet's GPU host (`prod-gpu-01`), native amd64 build host for ARC/Zarf, and home of the relocated **mgmt-02**. See ADR-011.
>
> *(v5.2: the M920q trio and M920x #2 now run Proxmox VE rather than bare-metal Ubuntu — every Kubernetes node is a VM. See ADR-008.)*
> *(v5.4: pve-07 is the only ZFS-root host in the fleet — a documented exception to ADR-008's ext4 pattern, with `zfs_arc_max` capped. It is also the only host with a GPU, and one consumer GPU passes through to exactly one VM: no vGPU, no MIG. See ADR-011.)*

---

## Purpose & Mandate *(v5.3)*

This lab serves **two missions on different timelines**, and every technology choice should be scored against both. Naming them explicitly, because until v5.3 only the first was written down — which quietly biased several decisions.

**Mission 1 — Ramp (now → ~18 months).** Close the gap between "Jr. DevOps Engineer" and "confident platform engineer at a space defense company." The lab is a rehearsal rig for the day job: DISA STIG, FIPS, Iron Bank, RKE2 CIS, air-gap delivery, Platform One patterns. This is why ADR-001, -005, -006, and -008 read the way they do.

**Mission 2 — Dojo (permanent).** Once the baseline is established, this becomes the long-term home for personal infrastructure, exploration, and side ventures. Its users are me and a handful of friends; its lifetime is measured in years, not sprints. Requirements shift from "mirror DoD production" to "durable, low-toil, and pleasant to operate."

**The day job stays on the defense path**, so Mission 1's skill investments do not expire — they compound. But Mission 2 outlives Mission 1, which means:

- **Where the two missions agree, that's the strongest possible signal.** Zero-trust workload identity, supply-chain provenance, GitOps, and observability are all "top-notch defense practice" *and* "things I want running in ten years." Prioritize these.
- **Where they diverge, name the trade in an ADR** rather than letting one mission silently win.
- **Match the innovation budget to the blast radius of the layer.** Identity, secrets, and networking are foundational: everything depends on them, switching costs are high, and an outage locks you out of your own platform. There, prefer *boring and durably governed* — a CNCF or Linux Foundation project over a promising single-vendor one. Spend the appetite for novelty in layers where churn is cheap and reversible: delivery, observability, MLOps, ephemeral environments.
- **Prefer reversibility over prediction.** Rather than trying to pick the tool that will still be correct in 2036, keep integration surfaces standards-only so the choice stays cheap to revisit. ADR-009 is the worked example of this principle.

> **Reading guide:** where a phase exists primarily to rehearse a defense pattern with no long-term homelab payoff, it is tagged *(Mission 1)*. Everything untagged serves both.

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
   │ 5 VMs, +GPU node│ │  3 VMs, M920x  │    │  Obs + Keycloak  │ │ Raft + GCP KMS │
   └─────────────────┘ └────────────────┘    └──────────────────┘ └────────────────┘
            │                  │                       │                  │
            └──────────────────┴───────────┬───────────┴──────────────────┘
                                           │
                          ┌────────────────┴────────────────┐
                          │   Shared storage tier (VLAN 40) │
                          │   nfs-01 (ZFS) + garage-01 S3   │
                          └─────────────────────────────────┘
```

> **v5 topology notes:** `homelab-mgmt` runs **Talos** (immutable, API-managed); workload clusters stay **RKE2**. **Flux** reconciles all three from `homelab-gitops` (no ArgoCD). Disposable **ephemeral Talos clusters** spin up on a capacity-checked existing host on demand (OpenTofu + Flux + Zarf) and are not shown above because they have no standing footprint. **Flagger** handles progressive delivery on the workload clusters.
>
> **v5.2 note:** every physical box now runs Proxmox — the homelab-prod nodes shown as "4 VMs" are OpenTofu-provisioned VMs (one per M920q on pve-04/05/06, plus prod-w-03 on pve-01), not bare metal. See ADR-008.
>
> **v5.4 note:** homelab-prod is now **5 VMs** — `prod-gpu-01` on pve-07 joins as a tainted GPU worker, making Tier 5's node pool real rather than rented. pve-07 also hosts `mgmt-02` (relocated off pve-01) and the amd64 build host. See ADR-011.

---

## Pre-Flight: Decisions Locked In

Confirm alignment before starting:

- [ ] **Hypervisors:** every physical box runs Proxmox VE — pve-01 (M920 SFF, 64GB/2TB NVMe; recovered 2026-10-10) + pve-02 (M920x #1, 32GB/1TB) + pve-03 (M920x #2, 32GB/1TB) + pve-04/pve-05/pve-06 (3× M920q, 16GB/512GB, one homelab-prod node VM each) + **pve-07 (tower: Ryzen 9 7900X, 64GB, 2× 2TB WD_BLACK SN850X NVMe ZFS mirror ≈1.8TiB usable, RTX 5070)**. One seven-member Proxmox cluster, `homelab-pve`, with no HA-managed guests initially (ADR-012). *(v5.2: M920q + M920x #2 moved from bare-metal Ubuntu to Proxmox — every K8s node is now a VM. See ADR-008. v5.4: pve-07 added — see ADR-011.)*
- [ ] **Single workstation:** the MacBook Pro (M2 Max, arm64) is the *only* workstation. The former Fedora tower is now pve-07; no workstation VM is retained on it. This is load-bearing — `pass`, the root CA trust store, the fleet-wide cloud-init SSH key, and Vault SSH OTP all assume exactly one trusted endpoint. *(v5.4 — ADR-011)*
- [ ] **GPU capacity:** one RTX 5070 on pve-07, passed through to a single VM (`prod-gpu-01`, tainted, joined to homelab-prod). No vGPU, no MIG — in-cluster sharing is device-plugin time-slicing only, with no memory or fault isolation. 12GB VRAM ceiling; >12GB workloads still burst to AWS `g5.xlarge`. *(v5.4 — ADR-011)*
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
- [ ] **Identity:** **Keycloak** on homelab-mgmt, deployed via the **Keycloak Operator** with the realm declarative from day one; OIDC for Grafana, Vault UI, Harbor, and the Flux UI (Weave GitOps / Capacitor); break-glass admin retained on every integration. *(v5: ArgoCD OIDC removed; v5.3: ZITADEL/authentik evaluated and rejected — ADR-009; Bitnami chart → Operator — ADR-010)*
- [ ] **Identity portability contract** *(v5.3 — ADR-009)*: every integration consumes only standards-shaped claims (`sub`, `email`, `preferred_username`, and a **flat `groups` array of strings**). No IdP-proprietary claim shapes, no vendor SDKs. One documented issuer URL. This is what keeps the IdP choice reversible.
- [ ] **Forward-auth:** **oauth2-proxy** in front of apps with no usable native OIDC support, brokering to Keycloak. *(v5.3 — ADR-010)*
- [ ] **Delivery:** Flagger for canary releases, k6-operator + Chaos Mesh for load/chaos testing. *(v5: Argo Rollouts → Flagger)*
- [ ] **Database:** CloudNativePG operator; dynamic credentials via Vault Database engine
- [ ] **DR:** Velero to Garage S3, scheduled + tested restore procedures
- [ ] **Air-gap muscle:** workload clusters (homelab-prod, homelab-dev) pull only from Harbor; homelab-mgmt permitted upstream pulls for bootstrap simplicity
- [ ] **Air-gap delivery:** **Zarf** for declarative offline package bundles (`zarf package create` / `deploy`), layered on top of the Harbor mirror; primary tool for the ephemeral air-gap drills. *(v5 new — ADR-005)*
- [ ] **Ephemeral environments:** GitOps-driven, on-demand — in-cluster PR-preview namespaces (Flux) + disposable Talos clusters on a capacity-checked existing host (OpenTofu + Flux + Zarf), torn down after each drill. *(v5 new — ADR-004)*

---

