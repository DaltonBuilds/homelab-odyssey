# Operation Long Haul v5 — Huly Work Breakdown

[← Docs index](../docs/README.md) · companion to [Huly bootstrap](../docs/bootstrap/huly-bootstrap.md)

This document translates the build docs into Huly work items. It is the source you type (or import) into the `Operation Long Haul` workspace after the [Huly bootstrap](../docs/bootstrap/huly-bootstrap.md) is up.

**Scope discipline (per the bootstrap doc):** don't over-invest before building. **Tier 0 is fully broken down** below — that is what you enter first. Tiers 1–5 are intentionally left at **milestone + epic** granularity; explode each tier's stories at the start of that tier, when the detail is real and stable.

---

## Conventions

**Hierarchy (maps the build doc onto Huly's model):**

| Build doc | Huly | Notes |
|-----------|------|-------|
| Tier | **Milestone** | 6 milestones: Tier 0–5 |
| Thematic group of phases | **Capability** | optional grouping layer inside a milestone |
| Phase (e.g. `0.5`) | **Epic** | title = phase title; ID prefix = phase number |
| Phase sub-step / checklist item | **Story** or **Task** | Story if it has its own acceptance check; Task if it's a step of a Story |
| "Verification / gate" phase | **Story** (type `Gate`, blocks the next milestone) | each tier ends with one |
| Future-Upgrades item, Nix, vLLM, etc. | **Spike** | time-boxed investigation, own backlog below |

**Issue types / labels:** `Epic`, `Story`, `Task`, `Spike`, `Gate`. Component labels reuse the platform vocabulary: `proxmox`, `network`, `openbao`, `k8s-prod`, `k8s-dev`, `k8s-mgmt`, `gitops`, `security`, `observability`, `identity`, `storage`, `dr`, `supply-chain`.

**Statuses:** `Backlog → Todo → In Progress → In Review → Done` (+ `Blocked`). A tier's **Gate** story stays `Blocked` until every epic in the milestone is `Done`; it blocks the next milestone.

**IDs:** keep the phase number in the title (`[0.5] Initialize OpenBao HA cluster`) so a Huly item always round-trips to a build-doc section.

**Estimation:** size in half-days (`0.5, 1, 2, 3`) — this is a solo build; velocity is the point of tracking, not story points.

> **TODO (do at bootstrap time):** check whether the current `huly-selfhost` release supports **CSV/bulk issue import**. If it does, generate a CSV from this file (columns: `type,identifier,title,parent,component,estimate`) and import rather than hand-entering ~40 Tier 0 items. If not, enter Tier 0 by hand (it's ~13 epics) and only skeleton the rest. Confirm against the upstream README — do not assume.

---

## Milestone: Tier 0 — Foundation *(fully broken down)*

> **Epic 0.0 — Huly bootstrap** *(pre-work; you're reading its output)*
> Stories: create `huly-bootstrap` VM · install Docker + Compose · deploy pinned Huly self-host · create `Operation Long Haul` workspace + Tier 0–5 milestones · first off-VM backup. Acceptance = the bootstrap doc's §7 exit criteria. Component: `proxmox`. → Then create the items below.

### Capability: Hypervisor & Network Fabric

**Epic [0.1] Proxmox on all physical hypervisors** — `proxmox`
- Story: Install Proxmox VE (ext4 root) on pve-01, pve-02, pve-03, pve-04, pve-05, and pve-06. Tasks: one per host (pve-03 M920x #2; pve-04/05/06 M920q).
- Story: Set management IPs + hostnames + `apt dist-upgrade` on all hosts.
- Story: Configure `vmbr0` VLAN trunks per host (VLAN 50 on pve-04/05/06 **+ pve-07**; VLAN 70 on a capacity-checked existing host).
- Story: Create `homelab-pve` on pve-01 and join the other six empty hosts before guest creation; reconcile node-local storage and cluster-wide guest IDs. Follow the [day-one checklist](../docs/build/proxmox-day-one.md).
- Story: Configure UniFi native VLAN 40 on host ports and tagged guest VLANs per the day-one matrix; preserve existing gateway/DNS access.
- Story: Upload Ubuntu 24.04 cloud image + VyOS/Talos ISOs to the relevant pools.
- Story (verify): all seven web UIs reachable; all seven members visible from one UI; quorum healthy; no HA-managed guests.

**Epic [0.1b] pve-07 — tower onboarding** — `proxmox`, `gpu` *(v5.4, ADR-011)*
- Story: Pre-install hardware checks — matching NVMe models/capacity; both M.2 slots at full lanes with the 5070 populated; IOMMU/AMD-Vi + SVM enabled in UEFI; note NIC link speed. *(No data rescue needed — confirmed at planning time.)*
- Story: Install Proxmox VE with **ZFS RAID1 mirror** across both 1TB NVMe (~900GB usable); IP `192.168.40.66`; hostname `pve-07`. Plan the space budget before provisioning VMs — the pool is adequate, not roomy.
- Story: Cap `zfs_arc_max` (~10GB) via `/etc/modprobe.d/zfs.conf` + `update-initramfs -u`; reboot. **The one step easiest to forget and most annoying to diagnose.**
- Story: `vmbr0` trunk VLANs 40 + 50; upload Ubuntu cloud image **and** Talos `metal-amd64.iso`.
- Story: GPU passthrough prep — `amd_iommu=on iommu=pt`, verify isolated IOMMU group, blacklist `nouveau`/`nvidia`, bind `vfio-pci`. **Do not install NVIDIA drivers on the host.**
- Story (verify): `zpool status` healthy 2-way mirror; `arc_summary` shows the cap; `lspci -nnk` shows `vfio-pci` on the GPU.
- Note: the GPU is *prepared* here and *consumed* in Tier 5. Do not block Tier 0 on it.

**Epic [0.2] Switch / VLAN configuration** — `network`
- Story: Trunk VLANs 10/40/50/60 (+70 to ephemeral hosts) to every hypervisor uplink + workstation, **on both UniFi switches**.
- Story: Confirm the inter-switch link carries all four VLANs tagged — the office jacks (incl. pve-07) sit downstream of it. *(v5.4)*
- Story: Edge-router VLAN interfaces + temporary DHCP scopes on 50/60.
- Story: Static routes for the three LB pools → planned VyOS VIP `192.168.40.12` (verify unused first); UniFi remains the host gateway at `192.168.40.1`.
- Story (verify): tagged test VM on pve-01(VLAN50)/pve-02(VLAN60)/**pve-07(VLAN50)** reaches edge + internet; delete test VMs. **The pve-07 case is the one that proves the office-jack trunk.**

**Epic [0.3] VyOS BGP fabric** — `network`
- Story: Provision bgp-01 (pve-01) + bgp-02 (pve-02) from VyOS ISO (UI, not Terraform); snapshot after install.
- Story: Configure VRRP (VLAN 40 gateway `.1`), iBGP peering between the pair, pre-staged eBGP peers for cluster VLANs.
- Story: Repoint pve-02 gateway to the VRRP IP.
- Story (verify): iBGP `Established`; VRRP failover < 3s; gateway ping survives bgp-01 power-off.

### Capability: Secrets Substrate (OpenBao)

**Epic [0.4] OpenBao VM provisioning (bootstrap mode)** — `openbao`
- Story: Hand-create vault-01 (pve-01) + **vault-02 (pve-03)** + vault-03 (pve-02) from Ubuntu ISO, cloud-init (static IP, SSH key, no password auth). *(v5.4: vault-02 moved off pve-01 per ADR-011 — no hypervisor hosts two Raft nodes.)*
- Story: Baseline hardening — disable swap, sshd hardening, chrony, host firewall (SSH + Vault API from VLAN 40 only).
- Story: Install pinned OpenBao 2.6.x `.deb` on all three; service present, not yet enabled.

**Epic [0.5] OpenBao HA cluster initialization** — `openbao`
- Story: Write `openbao.hcl` (Raft storage, TLS listener) per node; enable service.
- Story: `bao operator init` on vault-01; store Shamir keys — GPG-encrypted in `pass` + paper copy of 3 keys in the safe.
- Story: Join vault-02/03 to Raft; enable cluster-wide file audit device on all nodes.
- Story (verify): `raft list-peers` = 3 voters; all unsealed; audit log rotating.

**Epic [0.6] Migrate to GCP KMS auto-unseal** — `openbao`, `security`
- Story: Create KMS keyring + key; scoped service account (encrypt/decrypt on the one key only); JSON key onto each VM.
- Story: Add `seal "gcpckms"` stanza; migrate with `-migrate` on vault-01; restart vault-02/03.
- Story (verify): cold-restart all three → auto-unseal, no human; `Recovery Seal Type: gcpckms`. Archive Shamir keys.

**Epic [0.7] PKI engine — root + intermediate CA** — `openbao`, `security`
- Story: Mount root PKI (10y), generate self-signed root, set issuing/CRL URLs.
- Story: Mount intermediate, CSR → sign with root → import; set URLs; define `internal-services` role + allowed domains.
- Story: Issue the OpenBao cluster's own TLS cert (SAN-covered); distribute; roll each node.
- Story (verify): test issuance for `test.homelab.internal` returns a valid cert; cluster listener on Vault-signed TLS.

**Epic [0.8] Transit engine (encryption as a service)** — `openbao`
- Story: Create `cosign-harbor` + `app-data-encryption` keys; encrypt/decrypt smoke test.

**Epic [0.9] SSH OTP engine** — `openbao`, `security`
- Story: Enable `ssh` secrets engine; create `otp-baremetal` role (`default_user=dalton`, allowed CIDRs). *(name kept per ADR-008; nodes are VMs.)*

**Epic [0.10] Database engine — enabled & pre-staged** — `openbao`
- Story: Enable the database secrets engine (no connections yet — expected).

### Capability: Automation Identity & Workstation Credentials

**Epic [0.11] AppRole auth for Terraform & Ansible** — `openbao`, `security`
- Story: Write `terraform-provisioner` + `ansible-orchestrator` policies (least-privilege).
- Story: Enable AppRole; create both roles; enable KV v2 at `secret/`.
- Story: Fetch `role_id`s; generate `secret_id`s.
- Story (verify): each AppRole logs in and returns a token scoped to only its policy.

**Epic [0.12] `pass` store updated with Vault credentials** — `security`
- Story: Store both `role_id`/`secret_id` pairs, root CA cert, and kubeconfig slots in `pass`; paper recovery keys in the safe.

### Capability: Gate

**Story (Gate) [0.13] Tier 0 verification gate** — `Gate`, blocks Milestone Tier 1
- Runs the full Phase 0.13 checklist (hypervisor/network, BGP, OpenBao HA, engines, auth, hygiene). Stays `Blocked` until every Tier 0 epic is `Done`.

---

## Milestone: Tier 1 — Platform Provisioning *(skeleton — explode at Tier 1 start)*

Epics (title = phase): [1.1] Terraform Vault-auth refactor · [1.2] Ansible Vault-auth refactor · [1.3] VM provisioning via Terraform (storage, mgmt, dev, **all 4 prod nodes**) · ~~[1.4] Baremetal prep~~ *(removed — ADR-008; do not create)* · [1.5] OS hardening playbook · [1.6] Vault SSH OTP enrollment · [1.7] Storage tier (NFS+ZFS VM, Garage LXC) · [1.8] RKE2 — homelab-prod · [1.9] RKE2 — homelab-dev · [1.10] Talos — homelab-mgmt · [1.11] Etcd + OpenBao snapshot off-host replication · [1.12] Kubeconfig management · **[1.13] Tier 1 gate**.

## Milestone: Tier 2 — Platform Services *(skeleton)*

Epics: [2.1] Cilium BGP + internal DNS · [2.2] Vault K8s auth · [2.3] External Secrets Operator · [2.4] cert-manager + two issuers · [2.5] OpenBao listener cert via cert-manager · [2.6] Cilium Gateway API · [2.7] ExternalDNS · [2.8] CloudNativePG operator · [2.9] Harbor · [2.10] Air-gap pivot for workload clusters · [2.11] Zarf air-gapped delivery · [2.12] Flux on workload clusters · [2.13] Flux on mgmt (Talos) · [2.14] Kyverno (audit) · [2.15] Renovate · [2.16] SBOMs via Syft + Cosign · **[2.17] Tier 2 gate**.

## Milestone: Tier 3 — Observability & Identity *(skeleton)*

Epics: [3.1] kube-prometheus-stack · [3.2] Loki · [3.3] Tempo · [3.4] Alloy on all clusters · [3.5] Alloy on substrate VMs · [3.6] Cross-cluster wiring verify · [3.7] Falco · [3.8] Tetragon export · [3.9] Alertmanager routing · [3.10] Sloth SLOs · [3.11] CloudNativePG on mgmt · [3.12] Audit-log immutable retention · [3.13] Keycloak *(Operator + declarative realm — ADR-010)* · [3.14] OIDC integrations **+ oauth2-proxy forward-auth (3.14e)** · [3.15] OpenCost · **[3.16] Tier 3 gate**.

> **Identity epics changed in v5.3 (ADR-009 / ADR-010).** When you explode Tier 3, note that [3.13] is no longer "install the Bitnami chart, click through the realm in the UI":
> - **[3.13] Keycloak** — `identity`. Stories: CNPG Postgres cluster · **Keycloak Operator** install (pinned, image via Harbor) · `Keycloak` CR with capped JVM heap + `instances: 1` · **`KeycloakRealmImport` committed to Git** (realm, groups, 5 clients, flat-`groups` mapper) · client secrets → Vault → ESO (never inlined) · idempotency check on re-apply · break-glass runbook. Acceptance = the Phase 3.13 verification list, including the decoded-token claim-shape check.
> - **[3.14] OIDC integrations** — `identity`. Stories: Flux UI · Grafana · Harbor · Vault UI · **[3.14e] oauth2-proxy forward-auth** (new) · group-demotion test · break-glass failure test per integration.
> - Add a `Task` on [3.14]: **verify the ADR-009 portability contract** — no integration reads a non-standard claim, one documented issuer URL. This is a recurring check, not a one-off; re-run it whenever an app is added.

## Milestone: Tier 4 — Workloads & Delivery *(skeleton)*

Epics: [4.1] Flagger · [4.2] Kustomize overlays + Flux Kustomizations · ~~[4.3] Argo Events~~ *(relocated to Tier 5 — ADR-003; do not create here)* · [4.4] Keycloak realm — declarative-model boundary *(rescoped v5.3 — ADR-010; the realm is already code from [3.13], so this epic is "decide CR-vs-Terraform ownership", **not** a UI→code migration, and the `tofu import` stories are gone)* · [4.5] Custom OTel app (end-to-end) · [4.6] ARC · [4.7–4.11] Application suite — Vaultwarden/n8n/NetBox/Forgejo/Immich *(spec only; build post-Tier-5)* · [4.12] k6-operator · [4.13] Chaos Mesh + combined chaos/load · [4.14] Velero + DR drill · [4.15] Kyverno audit→enforce · [4.16] Carryover items · **[4.17] Tier 4 gate** · [4.18] Closing reflections.

## Milestone: Tier 5 — MLOps *(skeleton — external doc)*

Detailed in a separate document (see [tier-5-mlops.md](../docs/build/tier-5-mlops.md)). Create the milestone now; add epics when that doc lands. Argo Workflows/Events live here only.

---

## Cross-cutting epic: Ephemeral Environments

Not a milestone — a cross-cutting epic (tag onto Tier 2/4 once Flux + Zarf exist). Stories: [A] In-cluster PR-preview namespaces (Flux, homelab-dev) · [B] Disposable Talos clusters on a capacity-checked existing host (OpenTofu + Flux + Zarf) with per-drill teardown. See [ephemeral-environments.md](../docs/build/ephemeral-environments.md).

## Spike backlog (from Future Upgrades)

Time-boxed `Spike` items — schedule opportunistically, not gated:

- **[Spike] OpenBao 2.7+ seal-plugin migration** — `openbao`, **required gate before any 2.7 upgrade** (not truly optional; link as a blocker on any OpenBao-upgrade epic).
- **[Spike] SPIFFE/SPIRE workload identity** — `identity`, `security`. **Highest-priority spike on this list**; the only one advancing both missions at once. Gate on the Tier 3 gate being `Done`. Break into: SPIRE server + agent → one attested workload → **replace one long-lived AWS credential with SVID→OIDC federation** → SPIRE as an OpenBao JWT auth method. Estimate 4–6 half-days.
- [Spike] OpenBao namespaces exploration
- [Spike] OpenTofu state encryption
- [Spike] Nix reproducible CI toolchain on ARC *(deferred by design)*
- [Spike] vLLM serving runtime for KServe *(Tier 5-adjacent)* — **now has real hardware** (`prod-gpu-01`, RTX 5070 12GB on pve-07); scope it to quantized 7B–14B serving, and keep the `g5.xlarge` burst path for anything larger.
- [Spike] **NAS / storage-tier relocation** — `storage`. Conditional. With the quorum concentration resolved in v5.4, the unreplicated `nfs-01` + `garage-01` on pve-01 is the **largest remaining single-host blast radius**. Two independently valuable smaller steps before a NAS exists: (a) Garage replica onto pve-07's mirror (an evening); (b) relocate `nfs-01` to pve-07. Gate the full relocation on the Tier 1 DR runbooks having been exercised once.
- [Spike] Papermill parameterized notebooks *(Tier 5-adjacent)*
- [Spike] Backstage developer portal
- [Spike] **IdP re-evaluation (authentik)** — `identity`. **Conditional — create the item but leave it `Backlog` with no estimate.** Only pull it forward if an ADR-009 trigger actually fires (day job leaves the defense path · Keycloak leaves CNCF or relicenses · oauth2-proxy toil outgrows a native proxy provider). First story is always "verify the portability contract held," which usually removes the urgency.

---

## Template (copy for each new item)

```text
Type:        Epic | Story | Task | Spike | Gate
Title:       [<phase#>] <concise imperative>
Parent:      <milestone / capability / epic>
Component:   <label>
Estimate:    <half-days>
Acceptance:  <the build doc's verification bullet(s) for this item>
Doc link:    docs/build/<file>.md#<anchor>
```
