# homelab-build-v4

# Operation Long Haul v4 — Production-Grade Homelab Foundation

> **How to use this document:** Work through tiers sequentially. Each tier has a clear purpose, internal phasing, and verification gates. Do not advance to the next tier until verification passes. The tier structure mirrors the architecture itself — Tier 0 is the substrate everything else stands on.
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
> - **Argo Rollouts + ApplicationSets** for real progressive delivery across environments
> - **Renovate Bot, Kyverno (audit→enforce), Falco+Tetragon, CloudNativePG, Tempo, k6-operator, Chaos Mesh** all promoted from "upgrades" to first-class foundation
> - **Production hygiene additions (v4 revision):** etcd snapshot off-host replication with Object Lock (1.11), ExternalDNS (2.7), SBOM via Syft + Cosign attestation (2.15), Alloy on substrate VMs (3.5), audit log immutable retention (3.12), OpenCost cost attribution (3.15), Argo Events (4.3)
> - **MLOps platform** added as Tier 5 (see separate doc); five core personal apps (Vaultwarden, n8n, NetBox, Forgejo, Immich) deferred to post-Tier-5
> - **Planning addendum added (v4 final pass):** explicit non-goals / accepted risks, execution discipline, ADR + compliance evidence folders, Big Bang comparison track, Grafana Operator future migration, hybrid-cloud extension track, GitHub Actions supply-chain hardening, rebuild drills, and service-identity / developer-portal future upgrades
>
> **Repos involved (unchanged from v3):**
> - `homelab-gitops` — All Kubernetes manifests, Helm values, ArgoCD apps, Flux config
> - `homelab-ansible` — OS-level configuration for all nodes and VMs
> - `homelab-terraform` — Proxmox VM provisioning via bpg/proxmox provider
>
> **Cluster & host naming:**
> - **homelab-prod** (prod) — prod-cp-01 (CP), prod-w-01 (W1), prod-w-02 (W2), prod-w-03 (W3 — VM)
> - **homelab-dev** (dev/staging) — dev-cp-01 (CP), dev-w-01 (W1), dev-w-02 (W2) — all VMs on the new M920x
> - **homelab-mgmt** — 3-node HA cluster: mgmt-01, mgmt-02, mgmt-03 (VMs)
> - **Vault HA** — vault-01, vault-02, vault-03 (dedicated VMs, outside Kubernetes)
> - **BGP routers** — bgp-01, bgp-02 (VyOS VMs, one per hypervisor)
> - **Storage** — nfs-01 (VM), garage-01 (LXC container)

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
   │   (prod RKE2)   │ │ (dev/stg RKE2) │    │  (3-node RKE2)   │ │   (Vault HA)   │
   │  4 nodes, BM+VM │ │  3 VMs, M920x  │    │  Obs + Keycloak  │ │ Raft + GCP KMS │
   └─────────────────┘ └────────────────┘    └──────────────────┘ └────────────────┘
            │                  │                       │                  │
            └──────────────────┴───────────┬───────────┴──────────────────┘
                                           │
                          ┌────────────────┴────────────────┐
                          │   Shared storage tier (VLAN 40) │
                          │   nfs-01 (ZFS) + garage-01 S3   │
                          └─────────────────────────────────┘
```

---

## Pre-Flight: Decisions Locked In

Confirm alignment before starting:

- [ ] **Hypervisors:** Existing Proxmox host (64GB RAM, 1TB SSD) + new M920x (32GB RAM, 1TB SSD), no clustering between them (clean failure boundary)
- [ ] **CNI:** Cilium on both workload clusters, BGP control plane enabled, kube-proxy replacement, Gateway API
- [ ] **K8s distribution:** RKE2 with `profile: cis`, secrets encryption-at-rest, audit policy enabled
- [ ] **Load balancing:** Cilium BGP advertising LB IPs to VyOS (replaces v3's L2 announcements)
- [ ] **Ingress:** Cilium Gateway API
- [ ] **GitOps (workload clusters):** ArgoCD with ApplicationSets for env promotion
- [ ] **GitOps (mgmt):** Flux
- [ ] **Storage (file):** NFS backed by ZFS on dedicated VM, CSI via `csi-driver-nfs`
- [ ] **Storage (object):** Garage (S3-compatible) in LXC
- [ ] **Secrets substrate:** Vault HA cluster (3 VMs, Raft, GCP KMS auto-unseal) — PKI, Transit, SSH OTP, Database, KV v2 engines configured at bootstrap
- [ ] **Secrets delivery into K8s:** ESO pointed at Vault on every cluster
- [ ] **Workstation credentials:** `pass` (GPG-encrypted Git store) for kubeconfigs and Vault AppRole `secret_id`. No `ansible-vault`. No GCP SM for application secrets.
- [ ] **TLS (internal):** Vault PKI issuer via cert-manager, short-lived certs (≤24h)
- [ ] **TLS (public):** cert-manager + Let's Encrypt + Cloudflare DNS-01
- [ ] **Tunnel:** Cloudflared
- [ ] **Registry:** Harbor on homelab-prod, Cosign signing keys in Vault Transit
- [ ] **Policy:** Kyverno from Tier 2, audit mode initially, enforce after stabilization
- [ ] **Observability:** Prometheus + Loki + Grafana + Tempo + Alertmanager on homelab-mgmt (HA)
- [ ] **Runtime security:** Falco + Cilium Tetragon, events to homelab-mgmt Loki
- [ ] **Identity:** Keycloak on homelab-mgmt; OIDC for ArgoCD, Grafana, Vault UI, Harbor; break-glass admin retained on every integration
- [ ] **Delivery:** Argo Rollouts for canary releases, k6-operator + Chaos Mesh for load/chaos testing
- [ ] **Database:** CloudNativePG operator; dynamic credentials via Vault Database engine
- [ ] **DR:** Velero to Garage S3, scheduled + tested restore procedures
- [ ] **Air-gap muscle:** workload clusters (homelab-prod, homelab-dev) pull only from Harbor; homelab-mgmt permitted upstream pulls for bootstrap simplicity

---

## Execution Discipline, Non-Goals, and Accepted Risks

This build is intentionally production-shaped, but it is still a homelab. The goal is not to pretend the environment has enterprise failure domains; the goal is to practice enterprise patterns, document tradeoffs honestly, and build operational muscle without letting every advanced idea block the first useful platform.

### Execution discipline

- **Build in slices, not as one giant platform cutover.** A usable baseline is more valuable than a perfect design that never gets deployed.
- **Do not promote deferred upgrades into blockers.** Big Bang alignment, Grafana Operator, Backstage, SPIFFE/SPIRE, full marketplace-action mirroring, and cloud GPU burst are valuable tracks, but they do not block Tier 0–3.
- **Every tier must produce evidence.** Verification gates are not checkbox theater; each gate should leave behind commands, screenshots, logs, or runbook notes proving the platform behaves as expected.
- **Prefer reversible decisions early.** Use audit mode before enforcement, break-glass accounts before OIDC-only access, Harbor pull-through before full egress lockdown, and manual cert rotation before automating cross-boundary certificate sync.
- **Document why something is skipped.** Skipping a control is acceptable when the residual risk is understood. Undocumented skipping is not.

### Initial non-goals

- **Not true enterprise HA.** Two Proxmox hosts are useful failure domains, but this is not multi-rack, multi-site, multi-power-domain infrastructure.
- **Not enterprise-grade storage HA.** NFS on ZFS plus snapshots is pragmatic and observable, but it is not Ceph, NetApp, Portworx, or a replicated SAN.
- **Not a fully disconnected air-gap on day one.** The initial goal is Harbor-mediated pulls and supply-chain discipline. Full egress lockdown and marketplace mirroring become later hardening tracks.
- **Not a service mesh baseline.** Cilium Gateway API, NetworkPolicy, Hubble, WireGuard, and Tetragon provide substantial value without adding Istio/ambient mesh initially.
- **Not Big Bang as the primary installer.** Big Bang is a reference architecture and future comparison lab, not the install mechanism for this platform baseline.
- **Not production MLOps capacity.** The MLOps tier is for platform learning, inference demos, experiment tracking, and hybrid burst patterns — not sustained enterprise-scale model training.

### Accepted risks to document as ADRs

| Risk / Tradeoff | Accepted For Now Because | Mitigation / Future Path |
| --- | --- | --- |
| pve-01 remains a major dependency for storage and several platform services | Hardware budget and operational simplicity | Explicit failure drills, Garage/AWS backups, later evaluate replicated storage |
| NFS uses `no_root_squash` for Kubernetes PV compatibility | Many Kubernetes workloads require predictable UID/GID behavior | NetworkPolicy, namespace controls, restricted egress, ZFS snapshots, storage VLAN firewalling |
| Harbor pull-through does not itself enforce air-gap | It proves the cache/mirror pattern first | Later VyOS/proxy egress enforcement and CI policy checks |
| Vault listener cert rotation starts manual | Cross-boundary cert automation is integration glue, not a Tier 0 blocker | Add systemd pull-based rotation after cert-manager is stable |
| Keycloak/OIDC may be integrated after break-glass access works | Avoid locking yourself out during early platform instability | Keep local admin accounts and documented break-glass paths |
| Multiple platform tools increase operational surface area | The purpose is production-pattern learning | Strict tier gates, ADRs, and rebuild drills |

---

## Documentation Artifacts to Maintain Alongside the Build

These docs are part of the platform. They are not optional polish. They turn a homelab into a defensible engineering portfolio.

### Architecture Decision Records

Create `docs/adr/` and write a short ADR for every major decision or deferral:

```text
homelab-gitops/docs/adr/
  0001-rke2-over-k3s.md
  0002-vault-outside-kubernetes.md
  0003-cilium-bgp-over-metallb.md
  0004-harbor-as-registry.md
  0005-kyverno-over-gatekeeper.md
  0006-no-service-mesh-initially.md
  0007-grafana-operator-deferred.md
  0008-big-bang-reference-not-adopted.md
  0009-harbor-pull-through-before-egress-lockdown.md
  0010-keycloak-after-break-glass-access.md
```

Recommended ADR format:

```md
# ADR-000X — Title

## Status
Accepted | Deferred | Superseded

## Context
What problem forced the decision?

## Decision
What was chosen?

## Alternatives Considered
What else was evaluated?

## Consequences
What gets easier, what gets harder, and what risks remain?

## Verification
How do we prove the decision works operationally?
```

### Compliance-style evidence folder

Create `docs/compliance-evidence/` to collect control evidence without pretending the homelab is formally certified.

```text
homelab-gitops/docs/compliance-evidence/
  access-control.md
  audit-logging.md
  backup-restore.md
  encryption-at-rest.md
  encryption-in-transit.md
  identity-and-break-glass.md
  supply-chain-security.md
  vulnerability-management.md
  incident-response.md
  network-segmentation.md
```

Each file should answer:

- What control or risk area does this cover?
- Which components implement it?
- Where is the config stored?
- How is it verified?
- What evidence proves it?
- What risk remains?

### Threat model

Create `docs/security/threat-model.md` and track realistic threats:

| Threat | Prevention | Detection | Recovery |
| --- | --- | --- | --- |
| Stolen kubeconfig | `pass`, least privilege, short-lived tokens later | Audit logs, unusual API activity | Rotate kubeconfig, revoke account, re-issue |
| Compromised CI runner | Ephemeral runners, no static cloud keys, Vault token TTLs | Runner logs, Vault audit, Harbor push anomalies | Destroy runner, revoke token, rotate signing policy |
| Malicious container image | Harbor, Cosign, SBOM, Kyverno | Admission audit/enforce, Trivy findings | Block image, roll back, rotate affected secret |
| Compromised workload pod | NetworkPolicy, non-root, restricted PSS | Falco, Tetragon, Loki queries | Kill pod, rotate namespace secrets, inspect image |
| NFS abuse from pod root | Namespace isolation, storage VLAN controls | NFS logs, ZFS diff/snapshots | Restore snapshot, tighten policy |
| Vault AppRole secret leak | `pass`, limited policies, token TTLs | Vault audit log | Rotate SecretID, revoke tokens |
| Expired internal cert | cert-manager, alerting | Certificate expiration alerts | Re-issue cert, restart affected service |
| Rogue Git commit | branch protection, signed commits, PR review | Git audit, Argo drift | Revert, rotate deploy keys if needed |

### Rebuild and failure drills

Create `docs/runbooks/drills/` and execute these intentionally:

- Rebuild one RKE2 worker from scratch and rejoin it.
- Restore one namespace from Velero.
- Restore homelab-dev from an etcd snapshot.
- Rotate Vault recovery keys.
- Rotate the Cosign signing key and update Kyverno trust policy.
- Kill bgp-01 and confirm BGP/VRRP failover.
- Stop one mgmt control-plane node and confirm quorum survives.
- Simulate NFS data loss and restore from a ZFS snapshot.
- Simulate Garage outage and restore an etcd snapshot from AWS S3 Object Lock.
- Expire or replace a cert intentionally and verify alerting + recovery.

---

## Future Upgrade Tracks

These are valuable, but intentionally deferred unless explicitly promoted by an ADR. They should not block the initial platform baseline.

### Track A — Big Bang Alignment Lab

**Goal:** Understand Platform One / Big Bang architecture without replacing this platform's hand-built learning path.

- Deploy Big Bang on a disposable RKE2 cluster.
- Compare package model, GitOps flow, identity, registry, policy, observability, runtime security, and air-gap assumptions.
- Write `docs/adr/0008-big-bang-reference-not-adopted.md`.
- Outcome: Big Bang literacy plus a clear explanation of where this platform aligns or diverges.

**Do not adopt Big Bang wholesale in v4.** The current platform teaches more because the decisions are explicit and personally implemented.

### Track B — Grafana Operator / Dashboard-as-Code

**Goal:** Move Grafana folders, dashboards, and datasources into Kubernetes CRs managed by GitOps.

- Keep `kube-prometheus-stack` Grafana for the first observability baseline.
- Later install Grafana Operator on homelab-mgmt.
- Convert critical dashboards into `GrafanaDashboard` CRs.
- Convert folders into `GrafanaFolder` CRs.
- Convert datasources into `GrafanaDatasource` CRs.
- Store dashboard JSON in Git.
- Outcome: Grafana state is reconstructable from Git, not UI memory.

### Track C — Hybrid Cloud DR

**Goal:** Use AWS as an off-prem, tamper-resistant disaster recovery tier.

- Replicate RKE2 etcd snapshots to AWS S3 with Object Lock.
- Replicate Velero backups for critical namespaces.
- Store restore runbooks in Git.
- Run a restore drill where Garage is treated as unavailable and AWS is the recovery source.
- Outcome: credible hybrid DR story with immutable backup evidence.

### Track D — Hybrid Cloud CI / ARC Runners

**Goal:** Use Kubernetes-native ephemeral CI runners for image builds, tests, signing, and deployment automation.

- Deploy Actions Runner Controller after Harbor, Vault, and Kyverno are stable.
- Create separate runner scale sets:
  - `runner-general`
  - `runner-buildkit`
  - `runner-privileged-isolated`
  - `runner-mlops`
- Push images to Harbor.
- Sign with Cosign via Vault Transit.
- Generate SBOMs via Syft.
- Use short-lived Vault and cloud credentials only.
- Outcome: production-like CI/CD substrate with isolated, ephemeral runners.

### Track E — Cloud GPU Burst for MLOps

**Goal:** Keep the MLOps control plane on-prem while using AWS GPU capacity only when needed.

- Use Terraform to provision temporary GPU instances.
- Pull datasets from S3 or Garage-backed replicated storage.
- Push models/artifacts to the MLOps registry.
- Track experiments through the on-prem MLOps stack.
- Tear GPU resources down aggressively.
- Outcome: hybrid MLOps pattern: on-prem orchestration, cloud burst compute.

### Track F — GitHub Actions Supply-Chain Hardening

**Goal:** Reduce CI/CD supply-chain risk before moving to fully mirrored internal actions.

Maturity path:

1. Pin all third-party actions to full commit SHAs.
2. Set workflow permissions explicitly with least privilege.
3. Add action allowlists.
4. Use Renovate to update pinned SHAs via PRs.
5. Mirror critical marketplace actions into an internal GitHub org or Forgejo.
6. Eventually block direct external marketplace usage for sensitive workflows.

Critical actions to consider mirroring later:

- `actions/checkout`
- `actions/setup-node`
- `docker/login-action`
- `docker/build-push-action`
- `sigstore/cosign-installer`
- `anchore/syft-action`
- `hashicorp/setup-terraform`

### Track G — Internal Git / Forgejo Software Factory

**Goal:** Simulate an air-gapped or controlled software factory.

- Deploy Forgejo after the core platform and MLOps track are stable.
- Mirror GitHub repos into Forgejo.
- Evaluate Forgejo Actions or internal runners.
- Push packages/images to Harbor.
- Deploy from internal Git with ArgoCD.
- Outcome: internal source-control and delivery loop independent of GitHub SaaS.

### Track H — Developer Portal / Backstage

**Goal:** Add discoverability after there are enough services to justify a portal.

Backstage should catalog:

- services
- owners
- repos
- dashboards
- SLOs
- runbooks
- ArgoCD apps
- APIs
- cluster ownership
- MLOps projects

**Do not deploy Backstage before there are multiple real workloads.** It becomes valuable once platform sprawl exists.

### Track I — Service Identity / SPIFFE-SPIRE

**Goal:** Compare Vault PKI + cert-manager against SPIFFE/SPIRE workload identity.

- Deploy SPIRE on a disposable or dev cluster first.
- Issue SPIFFE IDs for workloads.
- Compare against cert-manager-issued service certs.
- Evaluate whether SPIFFE replaces, complements, or complicates the existing PKI model.
- Outcome: service identity ADR.

### Track J — Service Mesh / Istio Ambient Evaluation

**Goal:** Evaluate service mesh after Cilium Gateway API and NetworkPolicy are fully understood.

- Do not add Istio to the initial baseline.
- Later compare Cilium-only vs Istio ambient for mTLS, traffic policy, telemetry, and authorization.
- Especially compare against Big Bang package expectations.
- Outcome: ADR explaining whether a mesh earns its operational cost.

---

## Final Pre-Build Additions Worth Capturing

These are small enough to document now and valuable enough not to forget.

### Secrets lifecycle and rotation schedule

Create a recurring rotation plan for:

- Vault AppRole SecretIDs
- Cloudflare DNS API token
- Proxmox API tokens
- Harbor robot accounts
- Cosign signing keys
- Keycloak client secrets
- Garage access keys
- AWS IAM access keys, where static keys still exist
- break-glass admin passwords

Track rotation dates in `docs/security/rotation-schedule.md`.

### Vulnerability management loop

Document the vulnerability workflow:

1. Trivy/Harbor scans images.
2. Renovate proposes dependency updates.
3. Kyverno blocks or audits risky deployments.
4. Grafana/Alertmanager reports critical findings.
5. Exceptions require an ADR or time-boxed waiver.

Add `docs/security/vulnerability-management.md`.

### Cloud credential posture

For AWS integrations, prefer:

- GitHub OIDC to AWS IAM for GitHub-hosted workflows.
- Vault AWS secrets engine or short-lived STS credentials for internal automation.
- Static IAM users only as a temporary bootstrap exception.
- No long-lived AWS keys in Git, CI variables, or unencrypted workstation files.

### Asset inventory

NetBox is already planned as a later personal/platform app. When it lands, use it as a real source of truth for:

- VLANs
- subnets
- VM inventory
- physical hosts
- IP assignments
- service ownership
- rack/location metadata, even if simple
- cable/switch-port mapping

Until NetBox is live, keep `docs/inventory/ip-plan.md` and `docs/inventory/host-inventory.md` current.

### Release and promotion model

Before deploying many apps, define the promotion path:

```text
feature branch → dev namespace / homelab-dev → signed image in Harbor → homelab-prod canary → homelab-prod stable
```

This connects GitOps, Harbor, Kyverno, Argo Rollouts, k6, and observability into one coherent delivery story.

### Break-glass access

Every critical system must have:

- normal OIDC access path
- local break-glass admin
- credential location in `pass`
- rotation schedule
- tested login procedure
- audit note after use

Critical systems:

- Vault
- Proxmox
- ArgoCD
- Grafana
- Harbor
- Keycloak
- UniFi / edge router
- cloud accounts

---

## Network Architecture (Reference)

### VLAN plan

| VLAN | Subnet            | Purpose                                          |
| ---- | ----------------- | ------------------------------------------------ |
| 10   | 192.168.10.0/24   | Workstation / management                         |
| 40   | 192.168.40.0/24   | Platform tier (Proxmox, Vault, homelab-mgmt, NFS, Garage, BGP routers) |
| 50   | 192.168.50.0/24   | homelab-prod cluster (prod nodes + LB pool)        |
| 60   | 192.168.60.0/24   | homelab-dev cluster (dev/staging nodes + LB pool)      |

> **Note on VLAN expansion:** v3 used a single workload VLAN (40). v4 separates platform from prod from dev/staging, mirroring how real shops carve impact-level / tenancy boundaries at L2. Your switch must support VLAN trunks to both Proxmox hosts. Configure trunks before starting Tier 0.

### BGP ASN plan

| ASN    | Speaker             | Notes                                            |
| ------ | ------------------- | ------------------------------------------------ |
| 65000  | bgp-01, bgp-02 (VyOS) | iBGP between the two routers (full mesh, 2 peers) |
| 65001  | homelab-prod Cilium   | eBGP to bgp-01 and bgp-02                          |
| 65002  | homelab-dev Cilium        | eBGP to bgp-01 and bgp-02                          |

> **Why these ASNs:** Private ASN range is 64512–65534. Using 65000 as the routing-infrastructure ASN and incrementing for each cluster keeps the topology readable. iBGP within VyOS pair = same ASN; eBGP to clusters = different ASN.

### IP allocation

| Host / Component       | IP              | VLAN | Role                                    | Location           |
| ---------------------- | --------------- | ---- | --------------------------------------- | ------------------ |
| Workstation            | 192.168.10.77   | 10   | Daily driver                            | Physical           |
| pve-01 (M920 SFF)   | 192.168.40.50   | 40   | Hypervisor 1 (64GB, prod-adjacent)      | Physical           |
| pve-02 (M920x new)  | 192.168.40.55   | 40   | Hypervisor 2 (32GB, dev/staging)        | Physical           |
| bgp-01 (VyOS)           | 192.168.40.10   | 40   | BGP router, VRRP master                 | VM on pve-01    |
| bgp-02 (VyOS)           | 192.168.40.11   | 40   | BGP router, VRRP backup                 | VM on pve-02    |
| bgp-vrrp (virtual)     | 192.168.40.1    | 40   | VRRP virtual IP — VLAN 40 gateway       | Floats bgp-01↔bgp-02 |
| vault-01 (Vault)       | 192.168.40.20   | 40   | Vault HA node 1 (Raft leader candidate) | VM on pve-01    |
| vault-02 (Vault)       | 192.168.40.21   | 40   | Vault HA node 2                         | VM on pve-01    |
| vault-03 (Vault)       | 192.168.40.22   | 40   | Vault HA node 3                         | VM on pve-02    |
| nfs-01             | 192.168.40.51   | 40   | NFS + ZFS persistent storage            | VM on pve-01    |
| garage-01              | 192.168.40.53   | 40   | S3-compatible object storage            | LXC on pve-01   |
| mgmt-01 (mgmt CP)       | 192.168.40.60   | 40   | homelab-mgmt control plane                | VM on pve-01    |
| mgmt-02 (mgmt CP)    | 192.168.40.61   | 40   | homelab-mgmt control plane                | VM on pve-01    |
| mgmt-03 (mgmt CP)     | 192.168.40.62   | 40   | homelab-mgmt control plane                | VM on pve-02    |
| prod-cp-01 (homelab-prod)   | 192.168.50.30   | 50   | homelab-prod control plane                | Physical (M920q)   |
| prod-w-01 (homelab-prod)   | 192.168.50.31   | 50   | homelab-prod worker 1                     | Physical (M920q)   |
| prod-w-02 (homelab-prod)   | 192.168.50.32   | 50   | homelab-prod worker 2                     | Physical (M920q)   |
| prod-w-03 (homelab-prod)     | 192.168.50.33   | 50   | homelab-prod worker 3                     | VM on pve-01    |
| dev-cp-01 (homelab-dev)        | 192.168.60.30   | 60   | homelab-dev control plane                     | VM on pve-02    |
| dev-w-01 (homelab-dev)          | 192.168.60.31   | 60   | homelab-dev worker 1                          | VM on pve-02    |
| dev-w-02 (homelab-dev)          | 192.168.60.32   | 60   | homelab-dev worker 2                          | VM on pve-02    |

### LoadBalancer pools (BGP-advertised)

| Pool                    | Range                            | Advertised by      | Consumer               |
| ----------------------- | -------------------------------- | ------------------ | ---------------------- |
| homelab-prod-lb-pool      | 192.168.50.240 – 192.168.50.250  | Cilium (homelab-prod) | homelab-prod services    |
| homelab-dev-lb-pool           | 192.168.60.240 – 192.168.60.250  | Cilium (homelab-dev)      | homelab-dev services         |
| mgmt-lb-pool            | 192.168.40.240 – 192.168.40.250  | Cilium (homelab-mgmt) | homelab-mgmt services    |

> **Edge router static routes:** Because most consumer/prosumer edge routers don't speak BGP, the edge gets static routes pointing each LB pool to `192.168.40.1` (the VRRP virtual IP). VyOS handles the rest. This keeps the BGP topology entirely internal.

---

## Tier 0 — Foundation

**Purpose:** Establish the substrate everything else depends on. By the end of Tier 0, you have two operational hypervisors, a redundant BGP routing fabric, and a fully-configured Vault HA cluster with PKI, Transit, SSH OTP, and Database engines ready to issue credentials. **No Kubernetes exists yet.** Nothing in higher tiers can begin until Tier 0 verification passes.

**Why this tier exists separately:** v3 treated Vault as an application — Phase 6, after the cluster existed. That created a circular dependency (Ansible needed secrets to build the cluster; Vault lived in the cluster Ansible built). v4 inverts this: Vault is foundation, every later tier consumes it.

### Tier 0 Phases

- **0.1** — Proxmox installation on both hypervisors
- **0.2** — Switch / VLAN configuration verification
- **0.3** — VyOS deployment and BGP fabric
- **0.4** — Vault VM provisioning (bootstrap-mode, manual)
- **0.5** — Vault HA cluster initialization (Shamir → migrate to GCP KMS)
- **0.6** — Vault auto-unseal via GCP KMS
- **0.7** — PKI engine: internal root + intermediate CA
- **0.8** — Transit engine: encryption-as-a-service
- **0.9** — SSH OTP engine: ephemeral host access
- **0.10** — Database engine: enabled, connection definitions deferred to Tier 4
- **0.11** — AppRole authentication for Terraform and Ansible
- **0.12** — Workstation `pass` store updated with Vault AppRole `secret_id`
- **0.13** — Tier 0 verification gate

---

### Phase 0.1: Proxmox Installation (Both Hypervisors)

**Goal:** Both M920-class machines running Proxmox VE, accessible from workstation, ready to host VMs.

#### pve-01 (existing M920 SFF, 64GB / 1TB)

If already installed from v3, skip to verification. Otherwise follow the v3 Phase 0 procedure.

- [ ] Confirm pve-01 reachable at `192.168.40.50`
- [ ] Update Proxmox to latest stable patch release: `apt update && apt dist-upgrade`
- [ ] Verify `vmbr0` bridge accepts trunked VLANs 40, 50 (add VLAN 50 if v3 didn't include it)

#### pve-02 (new M920x, 32GB / 1TB)

- [ ] Download latest stable Proxmox VE ISO, flash to USB
- [ ] Install Proxmox on the 1TB SSD, ext4 root filesystem (not ZFS — ZFS lives in the NFS VM only)
- [ ] Set management IP: `192.168.40.55`, gateway `192.168.40.1` (this will be the VyOS VRRP IP once routers are up — temporarily set to existing gateway, fix later)
- [ ] Hostname: `pve-02`
- [ ] Complete installation, reboot
- [ ] Access UI from workstation: `https://192.168.40.55:8006`
- [ ] Apt update + dist-upgrade
- [ ] Configure `vmbr0` to accept trunked VLANs 40, 60
- [ ] Set DHCP reservation on edge router for `192.168.40.55`
- [ ] Upload Ubuntu Server 24.04 ISO and VyOS LTS ISO to local storage

#### Verification

- [ ] Both Proxmox web UIs load from workstation
- [ ] `ping 192.168.40.50` and `ping 192.168.40.55` both succeed
- [ ] Ubuntu 24.04 + VyOS ISOs visible in both Proxmox storage pools
- [ ] No clustering configured between the two hosts (verify in Datacenter view — each shows only itself)

---

### Phase 0.2: Switch / VLAN Configuration

**Goal:** Managed switch trunks all required VLANs to both Proxmox hosts and your workstation.

This is the most boring and most critical phase. BGP, cluster separation, everything downstream assumes VLAN trunking is correct.

- [ ] Identify your switch's port assignments for pve-01, pve-02, workstation, and uplink to edge router
- [ ] Configure each port as a trunk carrying VLANs 10, 40, 50, 60 (PVID 10 for workstation; tagged everywhere on hypervisor uplinks)
- [ ] Create VLAN interfaces on the edge router for VLANs 50 and 60 (if not already present for 10/40)
- [ ] Add temporary DHCP scopes on VLANs 50 and 60 (you'll replace with static cloud-init later; useful for first-boot testing)
- [ ] Add static routes on edge router (these point at VyOS VRRP IP once it's up; for now, you can defer until Phase 0.3 is complete):
  - `192.168.50.240/28 → 192.168.40.1`
  - `192.168.60.240/28 → 192.168.40.1`
  - `192.168.40.240/28 → 192.168.40.1`

#### Verification

- [ ] From a test VM on pve-01 tagged to VLAN 50, can reach the edge router and the internet
- [ ] From a test VM on pve-02 tagged to VLAN 60, same
- [ ] Delete test VMs

> **Blog note:** This phase rarely makes it into homelab writeups but is exactly the kind of L2 hygiene that breaks "production-grade" claims when skipped. Document your switch model and config — the next time you replace it, future-you will thank you.

---

### Phase 0.3: VyOS BGP Fabric

**Goal:** Two VyOS routers running, peered with each other via iBGP, providing VRRP-managed gateway service for VLAN 40, ready to peer with Cilium speakers in Tier 2.

#### 0.3a — Provision both VyOS VMs

For each VyOS VM, use the Proxmox UI for this one (Terraform won't manage Tier 0 infrastructure — that would create the same circular dependency we're eliminating with Vault):

- [ ] **bgp-01** on pve-01: 1 vCPU, 1GB RAM, 8GB disk, network on `vmbr0` with VLAN 40 (no tag — let VyOS handle sub-interfaces), boot from VyOS ISO
- [ ] **bgp-02** on pve-02: same specs
- [ ] Install VyOS to disk on both (`install image` in the live ISO console)
- [ ] On first reboot, set initial credentials and a known SSH key
- [ ] Snapshot both VMs in Proxmox immediately after fresh install — gives you a clean restore point

#### 0.3b — Base VyOS configuration

On each VyOS router, apply the base config. **bgp-01 example** (`bgp-02` is symmetric with priority lowered):

```bash
configure

# Hostname
set system host-name bgp-01

# Management interface on VLAN 40 (untagged on this trunk for simplicity,
# or use a VLAN sub-interface if your trunk requires tagging)
set interfaces ethernet eth0 vif 40 address '192.168.40.10/24'
set interfaces ethernet eth0 vif 50 address '192.168.50.2/24'
set interfaces ethernet eth0 vif 60 address '192.168.60.2/24'

# VRRP — shared virtual IP per VLAN, bgp-01 is master (priority 200), bgp-02 backup (priority 100)
set high-availability vrrp group VLAN40 interface eth0.40
set high-availability vrrp group VLAN40 vrid 40
set high-availability vrrp group VLAN40 priority 200
set high-availability vrrp group VLAN40 address 192.168.40.1/24

set high-availability vrrp group VLAN50 interface eth0.50
set high-availability vrrp group VLAN50 vrid 50
set high-availability vrrp group VLAN50 priority 200
set high-availability vrrp group VLAN50 address 192.168.50.1/24

set high-availability vrrp group VLAN60 interface eth0.60
set high-availability vrrp group VLAN60 vrid 60
set high-availability vrrp group VLAN60 priority 200
set high-availability vrrp group VLAN60 address 192.168.60.1/24

# Default route to edge router (replace 192.168.40.254 with your actual edge IP)
set protocols static route 0.0.0.0/0 next-hop 192.168.40.254

# BGP — own ASN 65000, iBGP peer to the other VyOS router
set protocols bgp system-as 65000
set protocols bgp neighbor 192.168.40.11 remote-as 65000
set protocols bgp neighbor 192.168.40.11 description 'iBGP to bgp-02'

# eBGP peers (placeholder — actual Cilium speakers come in Tier 2; pre-stage the config)
# homelab-prod cluster nodes (will peer from 192.168.50.30-33)
set protocols bgp neighbor-group homelab-prod remote-as 65001
set protocols bgp neighbor-group homelab-prod description 'homelab-prod cluster Cilium'
# homelab-dev cluster nodes (will peer from 192.168.60.30-32)
set protocols bgp neighbor-group homelab-dev remote-as 65002
set protocols bgp neighbor-group homelab-dev description 'homelab-dev cluster Cilium'

# SSH access
set service ssh port '22'
set service ssh listen-address '192.168.40.10'

commit
save
exit
```

For **bgp-02**, identical config but:
- `set system host-name bgp-02`
- All VRRP priorities `100` instead of `200`
- All interface IPs ending in `.11`, `.3`, `.3` respectively
- iBGP peer to `192.168.40.10`

#### 0.3c — Verify BGP fabric

- [ ] SSH to bgp-01: `show ip bgp summary` — confirms iBGP session to bgp-02 is `Established`
- [ ] SSH to bgp-02: same
- [ ] `show vrrp` on both — confirms bgp-01 is master, bgp-02 is backup for all three VRRP groups
- [ ] From your workstation, `ping 192.168.40.1` succeeds (you're hitting the VRRP virtual IP)
- [ ] Test failover: power off bgp-01 in Proxmox → bgp-02 becomes VRRP master within ~3 seconds → `ping 192.168.40.1` continues working. Power bgp-01 back on, master role returns to it.
- [ ] Update pve-02's gateway from temporary edge IP to `192.168.40.1` (the VRRP IP)

> **Blog note — VRRP vs ECMP:** A more sophisticated production setup uses ECMP with both routers active simultaneously rather than VRRP active/passive. For homelab scale, VRRP is dramatically simpler to reason about and the failover latency is acceptable. Document this tradeoff in an ADR — it's exactly the kind of "I considered X but chose Y because" reasoning interviewers probe.

---

### Phase 0.4: Vault VM Provisioning (Bootstrap Mode)

**Goal:** Three Vault VMs (vault-01/02/03) running Ubuntu Server 24.04, hardened baseline, Vault binary installed, ready to initialize.

> **Bootstrap pragmatism:** We're going to hand-provision these three VMs in the Proxmox UI rather than via Terraform. Reason: Terraform will be Vault-authenticated starting in Tier 1, and the Vault that authenticates it has to exist first. After Tier 0 completes, all future infrastructure provisioning (including replacing or scaling these Vault VMs) goes through Terraform-with-Vault. This is the *only* manual provisioning in the entire build.

#### 0.4a — Create the three Vault VMs

For each (specs are identical):

| VM         | Hypervisor | vCPU | RAM | Disk | IP             |
| ---------- | ---------- | ---- | --- | ---- | -------------- |
| vault-01   | pve-01  | 2    | 2GB | 20GB | 192.168.40.20  |
| vault-02   | pve-01  | 2    | 2GB | 20GB | 192.168.40.21  |
| vault-03   | pve-02  | 2    | 2GB | 20GB | 192.168.40.22  |

- [ ] Create each VM in Proxmox UI from Ubuntu 24.04 ISO
- [ ] Configure cloud-init with hostname, static IP on VLAN 40, your SSH key, `dalton` user with sudo, password auth disabled
- [ ] Boot, complete initial Ubuntu install
- [ ] On first SSH login, apt update + dist-upgrade, install `qemu-guest-agent`, reboot

#### 0.4b — Baseline OS hardening

This is what Ansible would do later — for Tier 0, run by hand on each Vault VM:

```bash
# Hostname (already set via cloud-init, verify)
hostnamectl

# Disable swap (Vault recommendation — prevent secrets paging to disk)
sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab

# SSH hardening (already mostly done by cloud-init; verify)
sudo sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sudo sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo systemctl restart sshd

# Time sync (Vault TLS + Raft consensus is time-sensitive)
sudo timedatectl set-timezone America/Denver
sudo systemctl enable --now chrony

# Firewall — Vault VMs only accept SSH from VLAN 40, Vault API/cluster from VLAN 40
# (Note: this is OK to use on Vault VMs because they're NOT k8s nodes; Cilium eBPF
# conflict only applies inside the cluster. Defense-in-depth on the Vault tier is appropriate.)
sudo apt install -y ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow from 192.168.40.0/24 to any port 22 proto tcp
sudo ufw allow from 192.168.10.0/24 to any port 22 proto tcp
sudo ufw allow from 192.168.40.0/24 to any port 8200 proto tcp  # Vault API
sudo ufw allow from 192.168.50.0/24 to any port 8200 proto tcp  # homelab-prod → Vault
sudo ufw allow from 192.168.60.0/24 to any port 8200 proto tcp  # homelab-dev → Vault
sudo ufw allow from 192.168.40.20,192.168.40.21,192.168.40.22 to any port 8201 proto tcp  # Raft cluster (inter-node)
sudo ufw enable
```

#### 0.4c — Install Vault binary

On each Vault VM:

```bash
# Official HashiCorp APT repository
wget -O - https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list

sudo apt update
sudo apt install -y vault

# Vault service is installed but not enabled yet — we need to write config first
sudo systemctl disable vault
```

#### Verification

- [ ] All three Vault VMs reachable via SSH from workstation
- [ ] `vault version` on each shows the same version (≥ 1.17 — current stable)
- [ ] `ufw status` on each shows the expected rules
- [ ] `timedatectl` shows synced clocks within a few hundred ms across all three

---

### Phase 0.5: Vault HA Cluster Initialization

**Goal:** Vault HA cluster operational with Raft storage and Shamir-key unseal. We migrate to GCP KMS auto-unseal in Phase 0.6 — initialize with Shamir first so the migration is exercised, not assumed.

> **Why Shamir first, then migrate to auto-unseal:** Practicing the migration is the whole point. Going straight to auto-unseal hides the failure modes and the recovery procedure. The migration from Shamir → auto-unseal is the same operation you'd run to *change* KMS providers in the future (e.g., GCP KMS → AWS KMS for a disaster scenario, or rotating the KMS key). It's a high-value rehearsal.

#### 0.5a — Vault configuration file (each node)

Create `/etc/vault.d/vault.hcl` on each Vault VM. Substitute `NODE_HOSTNAME` and `NODE_IP` per node:

```hcl
# /etc/vault.d/vault.hcl  (vault-01 example)

ui            = true
cluster_addr  = "https://192.168.40.20:8201"
api_addr      = "https://192.168.40.20:8200"
disable_mlock = false

listener "tcp" {
  address       = "0.0.0.0:8200"
  cluster_address = "0.0.0.0:8201"
  # TLS will be added after PKI is bootstrapped (Phase 0.7).
  # For initial cluster bring-up we run TLS-disabled inside the trusted VLAN 40,
  # then rotate to TLS using Vault's own PKI as one of the first PKI operations.
  tls_disable = 1
}

storage "raft" {
  path    = "/opt/vault/data"
  node_id = "vault-01"

  retry_join {
    leader_api_addr = "http://192.168.40.20:8200"
  }
  retry_join {
    leader_api_addr = "http://192.168.40.21:8200"
  }
  retry_join {
    leader_api_addr = "http://192.168.40.22:8200"
  }
}

telemetry {
  prometheus_retention_time = "30s"
  disable_hostname           = true
}

log_level = "info"
```

On vault-02 and vault-03, change `cluster_addr`, `api_addr`, and `node_id` to match the host. The `retry_join` block stays identical on all three (each node joins via the other two — order-independent).

- [ ] Create `/opt/vault/data` on each node, owned by the `vault` user:
  ```bash
  sudo install -d -o vault -g vault -m 0750 /opt/vault/data
  ```
- [ ] Enable and start Vault on **vault-01 first**, then vault-02, then vault-03:
  ```bash
  sudo systemctl enable --now vault
  sudo systemctl status vault   # should show running
  ```

#### 0.5b — Initialize the cluster (vault-01 only)

```bash
export VAULT_ADDR=http://127.0.0.1:8200

vault operator init \
  -key-shares=5 \
  -key-threshold=3 \
  -format=json > ~/vault-init.json

chmod 600 ~/vault-init.json
```

> **CRITICAL — secure `vault-init.json` immediately:** This file contains 5 unseal keys + the initial root token. Until Phase 0.6 migrates to auto-unseal, these unseal keys are the *only* way to bring Vault back up after a restart.
>
> **Storage plan:** (1) Encrypt with your GPG key and store in `pass` under `homelab/vault-init-shamir`. (2) Print a paper copy of unseal keys 1, 2, 3 and store in a physical safe. (3) After Phase 0.6 migration, archive — these Shamir keys are superseded by the auto-unseal recovery keys.

#### 0.5c — Unseal all three nodes

```bash
# On each Vault VM in turn — vault-01, vault-02, vault-03
export VAULT_ADDR=http://127.0.0.1:8200

vault operator unseal <unseal-key-1>
vault operator unseal <unseal-key-2>
vault operator unseal <unseal-key-3>

vault status
# Expect: Sealed=false, HA Enabled=true, Raft Applied Index increasing
```

#### 0.5d — Verify Raft cluster health

```bash
# Log in as root to inspect
export VAULT_ADDR=http://192.168.40.20:8200
vault login <initial-root-token>

vault operator raft list-peers
# Expect three nodes: vault-01 (leader), vault-02 (follower), vault-03 (follower)
```

#### Verification

- [ ] `vault status` on all three nodes: unsealed, HA enabled
- [ ] `vault operator raft list-peers`: 3 voters listed
- [ ] Kill the Raft leader (e.g., `sudo systemctl stop vault` on vault-01) — a new leader is elected within ~5 seconds. Restart vault on vault-01 and confirm it rejoins as a follower.
- [ ] `vault-init.json` encrypted in `pass` AND a paper copy of 3 unseal keys exists physically

---

### Phase 0.6: Migrate to GCP KMS Auto-Unseal

**Goal:** Vault no longer requires manual unseal after restarts. Unseal happens automatically using a GCP KMS key. Recovery keys replace Shamir keys.

#### 0.6a — Create the GCP KMS resources

In your GCP project (the same one used for Secret Manager in v3, or a new dedicated project — see note below):

```bash
# Set these
export GCP_PROJECT="homelab-vault"      # or your existing project
export GCP_REGION="us-central1"

# Enable KMS
gcloud services enable cloudkms.googleapis.com --project="$GCP_PROJECT"

# Create keyring + key
gcloud kms keyrings create vault-unseal \
  --location="$GCP_REGION" \
  --project="$GCP_PROJECT"

gcloud kms keys create vault-unseal-key \
  --location="$GCP_REGION" \
  --keyring=vault-unseal \
  --purpose=encryption \
  --rotation-period=90d \
  --next-rotation-time=$(date -u -d '+90 days' +%Y-%m-%dT%H:%M:%SZ) \
  --project="$GCP_PROJECT"
```

> **Dedicated project recommendation:** If you used `homelab-forge` (or similar) for GCP SM in v3, consider creating a separate `homelab-vault` project. Smaller blast radius if the KMS service account is compromised — it can't accidentally have IAM grants on other resources. This is the same principle behind separating prod/dev hypervisors.

#### 0.6b — Create the Vault KMS service account (least privilege)

```bash
# Service account that ONLY has permission to encrypt/decrypt with this one key
gcloud iam service-accounts create vault-unseal-sa \
  --display-name="Vault Auto-Unseal" \
  --project="$GCP_PROJECT"

# Grant only the specific role on the specific key — not project-wide
gcloud kms keys add-iam-policy-binding vault-unseal-key \
  --location="$GCP_REGION" \
  --keyring=vault-unseal \
  --member="serviceAccount:vault-unseal-sa@${GCP_PROJECT}.iam.gserviceaccount.com" \
  --role="roles/cloudkms.cryptoKeyEncrypterDecrypter" \
  --project="$GCP_PROJECT"

# Generate JSON key (this is the one credential that has to live on disk on each Vault VM)
gcloud iam service-accounts keys create ~/vault-unseal-sa.json \
  --iam-account=vault-unseal-sa@${GCP_PROJECT}.iam.gserviceaccount.com \
  --project="$GCP_PROJECT"
```

> **Defense-relevant note:** This service account has *exactly one* permission scoped to *exactly one* key. If the JSON key leaks, an attacker can encrypt/decrypt blobs using your KMS key but cannot list other resources, escalate privileges, or pivot. Document this scoping decision in your eventual ADR — it's the kind of least-privilege practice that maps directly to FedRAMP/DoD IL requirements.

#### 0.6c — Distribute the SA key to all Vault VMs

```bash
# From your workstation
for HOST in 192.168.40.20 192.168.40.21 192.168.40.22; do
  scp ~/vault-unseal-sa.json dalton@${HOST}:/tmp/vault-unseal-sa.json
  ssh dalton@${HOST} 'sudo install -o vault -g vault -m 0400 /tmp/vault-unseal-sa.json /etc/vault.d/gcp-kms.json && rm /tmp/vault-unseal-sa.json'
done

# Securely delete from your workstation
shred -u ~/vault-unseal-sa.json
```

#### 0.6d — Update Vault config with `seal` stanza

On each Vault VM, edit `/etc/vault.d/vault.hcl` and add:

```hcl
seal "gcpckms" {
  credentials = "/etc/vault.d/gcp-kms.json"
  project     = "homelab-vault"
  region      = "us-central1"
  key_ring    = "vault-unseal"
  crypto_key  = "vault-unseal-key"
}
```

> **DO NOT** restart Vault yet. The seal stanza alone doesn't migrate — it sets up the new seal mechanism. The migration is a one-time command.

#### 0.6e — Perform the seal migration

```bash
# On vault-01, with Vault still running under Shamir keys
export VAULT_ADDR=http://127.0.0.1:8200

# Restart Vault to load the new seal stanza (it will come up sealed — expected)
sudo systemctl restart vault

# Provide unseal keys with -migrate flag
vault operator unseal -migrate <unseal-key-1>
vault operator unseal -migrate <unseal-key-2>
vault operator unseal -migrate <unseal-key-3>

# Vault is now unsealed AND migrated. From this point forward, restarts auto-unseal.
vault status
# Look for: Recovery Seal Type: gcpckms

# Repeat the restart on vault-02 and vault-03 (they don't need the -migrate flag since
# the cluster state already migrated; they just need to pick up the new seal config)
sudo systemctl restart vault   # on vault-02 — auto-unseals
sudo systemctl restart vault   # on vault-03 — auto-unseals
```

> **What happens during migration:** Vault rewraps its master key with the GCP KMS key. The Shamir unseal keys are retired and replaced by *recovery keys*. Recovery keys are still required for operations like `vault operator generate-root` — keep them safe — but they aren't needed for routine unseal.

#### 0.6f — Generate new recovery keys output

After migration, Vault generated 5 new recovery keys (printed during the migrate operation). Save them:

- [ ] Capture the recovery keys from the migration output
- [ ] Store the recovery keys encrypted in `pass` under `homelab/vault-recovery-keys`
- [ ] Print a paper copy of recovery keys 1, 2, 3 for the physical safe
- [ ] Archive the old `vault-init.json` Shamir entry — it's now historical

#### Verification

- [ ] Power off all three Vault VMs simultaneously, wait 30 seconds, power them back on. They auto-unseal without any manual intervention. `vault status` from your workstation against each shows unsealed.
- [ ] `vault status` shows `Recovery Seal Type: gcpckms`
- [ ] Recovery keys safely stored in two places (encrypted digital + physical paper)

---

### Phase 0.7: PKI Engine — Internal Root + Intermediate CA

**Goal:** Vault becomes the internal certificate authority. cert-manager will use this CA (via the Vault issuer) to issue short-lived certs to internal services starting in Tier 2.

> **Two-tier CA pattern:** A root CA signs an intermediate CA; the intermediate signs leaf certificates. The root stays offline-style (we'll generate it, use it once, then disable the mount until rotation time). The intermediate handles day-to-day issuance. This matches the X.509 best practice that "root keys are precious; intermediates are operational."

#### 0.7a — Enable and configure the root PKI

```bash
export VAULT_ADDR=http://192.168.40.20:8200
vault login <root-token>

# Mount the root PKI with a 10-year max lease
vault secrets enable -path=pki_root pki
vault secrets tune -max-lease-ttl=87600h pki_root

# Generate the self-signed root certificate (returns the public cert; private key never leaves Vault)
vault write -field=certificate pki_root/root/generate/internal \
  common_name="Homelab Root CA" \
  ttl=87600h \
  key_type=ed25519 \
  > ~/homelab-root-ca.crt

# Configure URLs (where consumers fetch the cert and check revocation)
vault write pki_root/config/urls \
  issuing_certificates="http://192.168.40.20:8200/v1/pki_root/ca" \
  crl_distribution_points="http://192.168.40.20:8200/v1/pki_root/crl"
```

#### 0.7b — Enable and configure the intermediate PKI

```bash
# Mount the intermediate at a separate path
vault secrets enable -path=pki_int pki
vault secrets tune -max-lease-ttl=43800h pki_int   # 5 years max

# Generate a CSR — private key stays in Vault
vault write -format=json pki_int/intermediate/generate/internal \
  common_name="Homelab Intermediate CA" \
  key_type=ed25519 \
  | jq -r '.data.csr' > ~/pki_int.csr

# Sign the CSR using the root
vault write -format=json pki_root/root/sign-intermediate \
  csr=@~/pki_int.csr \
  format=pem_bundle \
  ttl=43800h \
  | jq -r '.data.certificate' > ~/pki_int.cert.pem

# Import the signed cert back into the intermediate mount
vault write pki_int/intermediate/set-signed certificate=@~/pki_int.cert.pem

# Configure URLs for the intermediate
vault write pki_int/config/urls \
  issuing_certificates="http://192.168.40.20:8200/v1/pki_int/ca" \
  crl_distribution_points="http://192.168.40.20:8200/v1/pki_int/crl"
```

#### 0.7c — Create issuance roles

These define what certs the intermediate is allowed to sign. We start with one role for internal services; add more later as needs emerge.

```bash
vault write pki_int/roles/internal-services \
  allowed_domains="homelab.internal,svc.cluster.local,homelab-prod.homelab.internal,homelab-dev.homelab.internal,mgmt.homelab.internal" \
  allow_subdomains=true \
  allow_glob_domains=true \
  max_ttl="24h" \
  ttl="24h" \
  key_type="ed25519" \
  require_cn=false
```

> **Short-lived certs by design:** 24-hour TTL means even a compromised cert is useless within a day. cert-manager will renew well before expiry (typically at 2/3 of lifetime). This is *the* defense-industry pattern for service identity and the v3 → v4 upgrade that produces the strongest interview talking point: "I run a two-tier internal PKI with 24-hour leaf certificates rotated by cert-manager."

#### 0.7d — Rotate Vault's own listener to TLS (using its own PKI)

Vault has been running with `tls_disable = 1` since Phase 0.5. Now that PKI exists, generate a cert for Vault and switch to TLS:

```bash
# Issue a cert for the Vault cluster (covers all three nodes via SANs)
vault write -format=json pki_int/issue/internal-services \
  common_name="vault.homelab.internal" \
  alt_names="vault-01.homelab.internal,vault-02.homelab.internal,vault-03.homelab.internal" \
  ip_sans="192.168.40.20,192.168.40.21,192.168.40.22" \
  ttl="720h" \
  > ~/vault-tls.json
# Note: 30-day TTL here because Vault hasn't bootstrapped its own cert-manager rotation yet.
# Plan to rotate manually until cert-manager exists; then automate via a Tier 2 cronjob.

jq -r '.data.certificate' ~/vault-tls.json > /tmp/vault.crt
jq -r '.data.private_key' ~/vault-tls.json > /tmp/vault.key
jq -r '.data.issuing_ca' ~/vault-tls.json > /tmp/vault-ca.crt
cat /tmp/vault.crt /tmp/vault-ca.crt > /tmp/vault-bundle.crt
```

Distribute to all three Vault VMs and update config:

```bash
# Distribute (repeat for each Vault VM)
for HOST in 192.168.40.20 192.168.40.21 192.168.40.22; do
  scp /tmp/vault-bundle.crt /tmp/vault.key dalton@${HOST}:/tmp/
  ssh dalton@${HOST} '
    sudo install -o vault -g vault -m 0444 /tmp/vault-bundle.crt /etc/vault.d/vault.crt &&
    sudo install -o vault -g vault -m 0400 /tmp/vault.key /etc/vault.d/vault.key &&
    rm /tmp/vault-bundle.crt /tmp/vault.key
  '
done

# Securely clean workstation tempfiles
shred -u /tmp/vault.crt /tmp/vault.key /tmp/vault-ca.crt /tmp/vault-bundle.crt ~/vault-tls.json
```

Update `/etc/vault.d/vault.hcl` on each node — change the listener block:

```hcl
listener "tcp" {
  address          = "0.0.0.0:8200"
  cluster_address  = "0.0.0.0:8201"
  tls_cert_file    = "/etc/vault.d/vault.crt"
  tls_key_file     = "/etc/vault.d/vault.key"
  tls_min_version  = "tls13"
}
```

Restart Vault on each node, one at a time (rolling, so the cluster stays available):

```bash
sudo systemctl restart vault
# Wait for auto-unseal and rejoin, verify with: vault status (should show unsealed, HA active)
# Then move to next node
```

Update `api_addr` and `cluster_addr` in each node's config from `http://` to `https://`. One more rolling restart applies the change.

From your workstation:

```bash
export VAULT_ADDR=https://192.168.40.20:8200
export VAULT_CACERT=~/homelab-root-ca.crt   # the file from Phase 0.7a
vault status
# Should connect over TLS, show all three nodes healthy
```

#### Verification

- [ ] `curl --cacert ~/homelab-root-ca.crt https://192.168.40.20:8200/v1/sys/health` returns 200 OK
- [ ] `vault read pki_int/cert/ca` returns the intermediate cert chain
- [ ] Test issuance: `vault write pki_int/issue/internal-services common_name=test.homelab.internal ttl=1h` returns a valid cert
- [ ] Distribute `~/homelab-root-ca.crt` to your workstation's trust store and `~/.config/vault/ca.crt` — future commands can drop the `--cacert` flag
- [ ] Back up the root CA cert file to `pass` under `homelab/vault-root-ca-cert`

---

### Phase 0.8: Transit Engine — Encryption as a Service

**Goal:** Applications can encrypt and decrypt arbitrary blobs using Vault-managed keys without ever holding the key material themselves. Will be used in Tier 4 by your custom OTel-instrumented app (and notably by Harbor for Cosign signing key storage).

```bash
vault secrets enable -path=transit transit

# Create one key per use case rather than reusing a single key
vault write -f transit/keys/cosign-harbor \
  type=ecdsa-p256 \
  exportable=false \
  allow_plaintext_backup=false

vault write -f transit/keys/app-data-encryption \
  type=aes256-gcm96 \
  exportable=false

# Smoke test
echo -n "hello" | base64 | xargs -I {} vault write transit/encrypt/app-data-encryption plaintext={}
# Returns: ciphertext = vault:v1:...
```

> **Why `exportable=false`:** The key material never leaves Vault. Apps make API calls to encrypt/decrypt — they can't snapshot the key, persist it, or leak it via a memory dump. The encryption operation itself becomes auditable.

#### Verification

- [ ] `vault list transit/keys` returns `cosign-harbor` and `app-data-encryption`
- [ ] Round-trip encrypt → decrypt of a test string succeeds

---

### Phase 0.9: SSH OTP Engine — Ephemeral Host Access

**Goal:** Replace static SSH key access for sudo operations on baremetal and platform VMs with one-time passwords issued by Vault. Every privileged SSH session is audited.

> **Scope clarification:** We're enabling the SSH OTP engine in Vault and pre-staging the configuration. Actually *enrolling* hosts (installing `vault-ssh-helper` on each, setting up PAM) happens in Tier 1 alongside the rest of OS hardening — it requires Ansible to be Vault-authenticated, which needs Phase 0.11 done first. This phase just gets the engine ready.

```bash
vault secrets enable -path=ssh ssh

# Create the OTP role — defines who can request OTPs for which hosts
vault write ssh/roles/otp-baremetal \
  key_type=otp \
  default_user=dalton \
  cidr_list=192.168.40.0/24,192.168.50.0/24,192.168.60.0/24
```

#### Verification

- [ ] `vault read ssh/roles/otp-baremetal` returns the role config
- [ ] (Full end-to-end OTP test deferred to Tier 1 after vault-ssh-helper is installed)

---

### Phase 0.10: Database Engine — Enabled and Pre-Staged

**Goal:** The database secrets engine is mounted and ready. Specific Postgres connection definitions land in Tier 4 when CloudNativePG creates the actual databases.

```bash
vault secrets enable -path=database database
```

That's all for this phase — no connections to configure yet. The engine is ready to accept connection definitions when CloudNativePG instances exist in Tier 4.

---

### Phase 0.11: AppRole Authentication for Terraform & Ansible

**Goal:** Terraform and Ansible can authenticate to Vault using AppRole. The `secret_id` for each lives in `pass` on your workstation. No more `ansible-vault`, no more credentials in `terraform.tfvars`.

#### 0.11a — Enable AppRole and create policies

```bash
vault auth enable approle

# Policy for Terraform — needs to read SSH keys, cloud-init secrets, GCP credentials, etc.
vault policy write terraform-provisioner - <<EOF
path "secret/data/terraform/*" {
  capabilities = ["read"]
}
path "ssh/creds/otp-baremetal" {
  capabilities = ["create", "read", "update"]
}
EOF

# Policy for Ansible — broader read access for OS-level secrets, plus SSH OTP for privileged ops
vault policy write ansible-orchestrator - <<EOF
path "secret/data/ansible/*" {
  capabilities = ["read"]
}
path "ssh/creds/otp-baremetal" {
  capabilities = ["create", "read", "update"]
}
path "pki_int/issue/internal-services" {
  capabilities = ["create", "update"]
}
EOF

# Enable the KV v2 engine for general secrets (Terraform + Ansible consume from here)
vault secrets enable -version=2 -path=secret kv
```

#### 0.11b — Create AppRoles

```bash
vault write auth/approle/role/terraform \
  token_policies="terraform-provisioner" \
  token_ttl=1h \
  token_max_ttl=4h \
  secret_id_ttl=0 \
  secret_id_num_uses=0

vault write auth/approle/role/ansible \
  token_policies="ansible-orchestrator" \
  token_ttl=1h \
  token_max_ttl=4h \
  secret_id_ttl=0 \
  secret_id_num_uses=0

# Fetch the role IDs (these are not secret — they identify which AppRole you're authenticating as)
vault read -field=role_id auth/approle/role/terraform/role-id > ~/terraform-role-id.txt
vault read -field=role_id auth/approle/role/ansible/role-id   > ~/ansible-role-id.txt

# Generate secret IDs (these ARE secret — the AppRole "password")
vault write -force -field=secret_id auth/approle/role/terraform/secret-id > ~/terraform-secret-id.txt
vault write -force -field=secret_id auth/approle/role/ansible/secret-id   > ~/ansible-secret-id.txt
```

> **`secret_id_ttl=0` and `secret_id_num_uses=0`:** Long-lived secret IDs that don't expire and have no use count limit. Appropriate for workstation-resident automation credentials. For *workload* AppRoles (issued to ESO running inside clusters), use short TTLs and require periodic re-issuance — but that's a Tier 2 concern.

#### Verification

- [ ] Test Terraform AppRole login:
  ```bash
  ROLE_ID=$(cat ~/terraform-role-id.txt)
  SECRET_ID=$(cat ~/terraform-secret-id.txt)
  vault write auth/approle/login role_id="$ROLE_ID" secret_id="$SECRET_ID"
  # Returns a token. That token has only the terraform-provisioner policy.
  ```
- [ ] Test Ansible AppRole login: same procedure with ansible IDs

---

### Phase 0.12: `pass` Store Updated With Vault Credentials

**Goal:** AppRole credentials live in `pass`, accessible from any workstation with your GPG key. The v3 `pass`/Chezmoi flow is unchanged — we're just adding new entries.

- [ ] Insert into pass:
  ```bash
  pass insert -m homelab/vault/terraform-role-id     < ~/terraform-role-id.txt
  pass insert -m homelab/vault/terraform-secret-id   < ~/terraform-secret-id.txt
  pass insert -m homelab/vault/ansible-role-id       < ~/ansible-role-id.txt
  pass insert -m homelab/vault/ansible-secret-id     < ~/ansible-secret-id.txt
  pass insert -m homelab/vault/recovery-keys         # paste recovery keys 1-5 from Phase 0.6f
  pass insert -m homelab/vault/root-ca-cert          < ~/homelab-root-ca.crt
  pass git push
  ```
- [ ] Securely wipe the workstation copies:
  ```bash
  shred -u ~/terraform-role-id.txt ~/terraform-secret-id.txt ~/ansible-role-id.txt ~/ansible-secret-id.txt
  ```
- [ ] Update Chezmoi to deploy these as files when needed (templates live under `private_dot_config/homelab-secrets/`)

> **Workflow going forward:** Terraform and Ansible read the AppRole credentials from `pass` at runtime, exchange them with Vault for short-lived tokens, and use those tokens for all secret access. Nothing sensitive is ever written to disk persistently outside of `pass`. This is the *exact* pattern you'd see in a mature production shop.

---

### Phase 0.13: Tier 0 Verification Gate

You may not advance to Tier 1 until **every** item below passes.

#### Hypervisor & network

- [ ] Both Proxmox hosts operational, accessible from workstation, no clustering between them
- [ ] Switch trunks VLANs 10, 40, 50, 60 to both hypervisor uplinks
- [ ] `ping 192.168.40.1` from workstation succeeds (VRRP virtual IP responds)

#### BGP fabric

- [ ] bgp-01 and bgp-02 both running on separate hypervisors
- [ ] iBGP session between them is `Established`
- [ ] VRRP failover test passes (kill master → backup takes over within 5 seconds → restore master → role returns)
- [ ] Edge router has static routes for all three LB pools pointing to `192.168.40.1`

#### Vault HA

- [ ] All three Vault VMs healthy: `vault status` from each shows unsealed, HA enabled, Raft index advancing
- [ ] `vault operator raft list-peers` shows three voters
- [ ] Cold-restart test passes (power off all three, power on, all auto-unseal without intervention)
- [ ] Raft leader-loss test passes (stop leader, new leader elected within ~5s, old leader rejoins as follower on restart)
- [ ] Vault listener is on TLS with cert issued by Vault's own intermediate CA (`https://`, not `http://`)

#### Engines configured

- [ ] PKI: `vault list pki_int/roles` shows `internal-services`
- [ ] Transit: `vault list transit/keys` shows `cosign-harbor` and `app-data-encryption`
- [ ] SSH: `vault read ssh/roles/otp-baremetal` returns the role
- [ ] Database: engine is enabled (no connections yet — expected)
- [ ] KV v2: `vault secrets list` shows `secret/` at version 2

#### Authentication

- [ ] AppRole login for `terraform` succeeds and returns a token with only `terraform-provisioner` policy
- [ ] AppRole login for `ansible` succeeds and returns a token with only `ansible-orchestrator` policy
- [ ] Both `role_id`s and `secret_id`s stored in `pass`, paper recovery keys in physical safe, root CA cert in `pass`

#### Hygiene

- [ ] No plaintext Vault credentials anywhere on workstation (`shred -u` confirmed on all generated key files)
- [ ] GCP KMS service account has *only* `roles/cloudkms.cryptoKeyEncrypterDecrypter` on *only* the `vault-unseal-key` resource (verify in GCP IAM Policy Analyzer or `gcloud projects get-iam-policy`)
- [ ] Vault VM firewalls (`ufw`) restrict API access to the three workload VLANs only

When all of the above pass: **Tier 0 is complete.** The substrate exists. Everything from Tier 1 onward stands on it.

---

## Tier 1 — Platform Provisioning  *(coming next)*

[Placeholder — to be drafted after Tier 0 review. Will cover: Terraform with Vault auth, Ansible with Vault auth, all remaining VM provisioning, OS hardening, RKE2 installation on homelab-prod + homelab-dev + homelab-mgmt with CIS profile and encryption-at-rest, NFS+ZFS storage VM, Garage object storage LXC.]

## Tier 2 — Platform Services  *(coming next)*

## Tier 3 — Observability & Identity  *(coming next)*

## Tier 4 — Workloads & Delivery  *(coming next)*
# Tier 1 — Platform Provisioning

**Purpose:** With Vault as substrate, build out every remaining piece of infrastructure declaratively. By the end of Tier 1, you have all VMs provisioned via Terraform (Vault-authenticated), all hosts configured via Ansible (Vault-authenticated, zero `ansible-vault`), three RKE2 clusters operational with CIS profile + encryption-at-rest + audit logging, and storage tier (NFS+ZFS, Garage) online.

**Why this tier exists separately from Tier 0:** Tier 0 was about *the substrate that secrets management itself depends on*. Tier 1 is the first tier that *consumes* Tier 0. Everything in Tier 1 demonstrates the right way to use Vault from the very tools that provision infrastructure.

**What changes from v3:**
- Terraform reads its provider credentials from Vault at runtime — no `terraform.tfvars` with secrets, no env vars set by hand
- Ansible authenticates to Vault via AppRole — no `ansible-vault` encrypted files, no `--ask-vault-pass`
- RKE2 replaces k3s with CIS profile mode enabled, secrets encryption-at-rest in etcd, and a real audit policy
- Three clusters instead of two: **homelab-prod** (prod, mostly baremetal), **homelab-dev** (dev/staging, all VMs on M920x), **homelab-mgmt** upgraded from 1-node k3s to 3-node RKE2 HA
- Hosts enroll with Vault SSH OTP for privileged operations (deferred config from Phase 0.9 lands here)

## Tier 1 Phases

- **1.1** — Terraform refactor: Vault-authenticated provider chain
- **1.2** — Ansible refactor: Vault lookups replace `ansible-vault`
- **1.3** — VM provisioning via Terraform (all workload + mgmt VMs)
- **1.4** — Baremetal preparation (3 prod nodes — Ansible-driven)
- **1.5** — OS hardening playbook (CIS-adjacent baseline, all hosts)
- **1.6** — Vault SSH OTP enrollment (`vault-ssh-helper` everywhere)
- **1.7** — Storage tier: NFS+ZFS VM, Garage S3 LXC
- **1.8** — RKE2 installation: homelab-prod (prod, 4 nodes)
- **1.9** — RKE2 installation: homelab-dev (dev/staging, 3 nodes, all VMs)
- **1.10** — RKE2 installation: homelab-mgmt (3 nodes HA, all VMs)
- **1.11** — Etcd snapshot off-host replication (Garage + AWS S3 with Object Lock)
- **1.12** — kubeconfig collection, `pass` integration, context labels
- **1.13** — Tier 1 verification gate

---

### Phase 1.1: Terraform Refactor for Vault Authentication

**Goal:** Terraform reads every secret it needs from Vault at runtime, authenticating via the AppRole created in Tier 0. No long-lived credentials on disk, no `terraform.tfvars` with sensitive values.

#### 1.1a — Repo structure (`homelab-terraform`)

```
homelab-terraform/
├── README.md
├── .gitignore                          # excludes *.tfvars, .terraform/, *.tfstate*
├── envrc.example                       # template, no secrets
├── scripts/
│   └── vault-login.sh                  # exchanges AppRole creds for a token
├── modules/
│   ├── proxmox-vm/                     # reusable VM module
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   └── proxmox-lxc/
│       └── ...
└── environments/
    ├── platform/                        # vault-01/02/03 handled in Tier 0; this dir starts empty in Tier 1
    ├── homelab-prod/                      # prod-w-03 (worker VM on pve-01)
    │   ├── main.tf
    │   ├── variables.tf
    │   └── backend.tf
    ├── homelab-dev/                           # dev-cp-01, dev-w-01, dev-w-02 on pve-02
    │   └── ...
    ├── mgmt/                            # mgmt-01, mgmt-02, mgmt-03
    │   └── ...
    └── storage/                         # nfs-01, garage-01
        └── ...
```

> **State backend note:** v3 used local state. v4 keeps local state with explicit backup discipline (committed encrypted state snapshots, or eventual migration to Garage S3 backend in Tier 2 once Garage exists). For Tier 1, local state is fine — we'll add the S3 backend once Garage is online in Phase 1.7.

#### 1.1b — Vault provider configuration

Top-level `provider.tf` shared by all environments via symlinks or a root module:

```hcl
# provider.tf
terraform {
  required_version = ">= 1.9"
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.66"
    }
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.4"
    }
  }
}

# Vault provider authenticates via AppRole.
# role_id and secret_id come from env vars set by scripts/vault-login.sh,
# which sources them from `pass`. Nothing sensitive in this file.
provider "vault" {
  address = "https://192.168.40.20:8200"
  # CA cert is the homelab root CA, installed to workstation trust store in Tier 0.
  # No further config needed because the cert is trusted system-wide.

  auth_login {
    path = "auth/approle/login"
    parameters = {
      role_id   = var.vault_role_id
      secret_id = var.vault_secret_id
    }
  }
}

# Read Proxmox API credentials from Vault rather than the user's env or tfvars.
data "vault_kv_secret_v2" "proxmox" {
  mount = "secret"
  name  = "terraform/proxmox"
}

provider "proxmox" {
  endpoint = data.vault_kv_secret_v2.proxmox.data["endpoint"]
  api_token = data.vault_kv_secret_v2.proxmox.data["api_token"]
  insecure  = false   # Proxmox cert is signed by Vault PKI starting in Tier 2

  ssh {
    agent    = true
    username = "root"
  }
}

variable "vault_role_id"   { type = string  sensitive = true }
variable "vault_secret_id" { type = string  sensitive = true }
```

#### 1.1c — Seed required secrets into Vault

Before Terraform can run, the secrets it expects to read must exist in Vault. One-time:

```bash
# Create API tokens in Proxmox first (in the Proxmox UI: Datacenter → Permissions → API Tokens)
# Generate one token per Proxmox host with PVE-VM-Admin role.

# Then write them into Vault under the path the Terraform provider expects
vault kv put secret/terraform/proxmox \
  endpoint="https://192.168.40.50:8006/" \
  api_token="root@pam!terraform=<the-token-secret>"

vault kv put secret/terraform/pve-02 \
  endpoint="https://192.168.40.55:8006/" \
  api_token="root@pam!terraform=<the-token-secret>"

# Cloud-init SSH key for new VMs (your workstation's public key)
vault kv put secret/terraform/cloud-init \
  ssh_authorized_keys="$(cat ~/.ssh/id_ed25519.pub)"
```

#### 1.1d — Helper script: `scripts/vault-login.sh`

```bash
#!/usr/bin/env bash
# scripts/vault-login.sh — exports Vault AppRole creds for Terraform.
# Sourced (not executed) into the shell, never writes to disk.
set -euo pipefail

export VAULT_ADDR="https://192.168.40.20:8200"

# Pull AppRole credentials from `pass` (GPG-protected)
export TF_VAR_vault_role_id="$(pass show homelab/vault/terraform-role-id)"
export TF_VAR_vault_secret_id="$(pass show homelab/vault/terraform-secret-id)"

echo "Vault credentials loaded into current shell. Run 'unset TF_VAR_vault_role_id TF_VAR_vault_secret_id' when done."
```

Usage from your workstation:

```bash
# At the start of a Terraform session
source scripts/vault-login.sh

# Now Terraform can authenticate without anything sensitive on disk
terraform plan
terraform apply
```

#### Verification

- [ ] `terraform init` in any environment directory succeeds
- [ ] `terraform plan` after `source scripts/vault-login.sh` shows the provider authenticating to Vault and reading the Proxmox token without error
- [ ] No `.tfvars` files contain secrets (grep for `api_token`, `password`, `secret` — should match nothing)
- [ ] `.gitignore` excludes `*.tfvars`, `*.tfstate*`, `.terraform/`

---

### Phase 1.2: Ansible Refactor for Vault Authentication

**Goal:** Ansible authenticates to Vault via AppRole and pulls every secret it needs (host passwords, SSH user passwords for sudo, GPG keys, GitHub tokens, etc.) from KV v2. The v3 pattern of `ansible-vault` encrypted YAMLs is retired entirely.

#### 1.2a — Repo structure (`homelab-ansible`)

```
homelab-ansible/
├── README.md
├── ansible.cfg
├── inventories/
│   ├── platform/                       # Vault VMs (vault-01/02/03) — already configured in Tier 0
│   ├── storage/                        # nfs-01, garage-01
│   ├── homelab-prod/                     # baremetal: prod-cp-01, prod-w-01, prod-w-02; VM: prod-w-03
│   ├── homelab-dev/                          # VMs: dev-cp-01, dev-w-01, dev-w-02
│   └── mgmt/                           # VMs: mgmt-01, mgmt-02, mgmt-03
├── group_vars/
│   ├── all.yml                         # non-sensitive defaults only
│   └── all_vault.yml                   # NEW: defines lookup tasks against Vault
├── roles/
│   ├── common/                         # base packages, time, sshd
│   ├── hardening/                      # CIS-adjacent OS hardening
│   ├── vault-ssh-helper/               # enrolls host with Vault SSH OTP (Phase 1.6)
│   ├── rke2-control-plane/
│   ├── rke2-worker/
│   ├── nfs-01/
│   ├── garage/
│   └── kubeconfig-collector/
├── playbooks/
│   ├── 00-bootstrap.yml                # initial connection test, gather facts
│   ├── 10-harden.yml                   # OS hardening for all hosts
│   ├── 11-vault-ssh-enroll.yml         # vault-ssh-helper install + PAM config
│   ├── 20-storage-tier.yml             # nfs-01, garage-01
│   ├── 30-rke2-homelab-prod.yml
│   ├── 31-rke2-homelab-dev.yml
│   ├── 32-rke2-mgmt.yml
│   └── 90-kubeconfig-collect.yml
└── requirements.yml                    # community.hashi_vault, etc.
```

#### 1.2b — Ansible collection requirements

```yaml
# requirements.yml
collections:
  - name: community.hashi_vault
    version: ">=6.2.0"
  - name: ansible.posix
  - name: community.general
  - name: kubernetes.core
```

```bash
ansible-galaxy collection install -r requirements.yml
```

#### 1.2c — Vault lookups in inventory and tasks

`group_vars/all.yml` (committed, no secrets):

```yaml
vault_addr: "https://192.168.40.20:8200"
vault_kv_mount: "secret"
ansible_python_interpreter: "/usr/bin/python3"
ansible_user: "dalton"
```

`group_vars/all_vault.yml` (committed, no secrets — just lookup definitions):

```yaml
# These set Ansible vars by reading Vault at task-run time.
# All actual secrets live in Vault, never in this file.
become_password: >-
  {{ lookup('community.hashi_vault.vault_kv2_get',
            'ansible/sudo-password',
            mount_point=vault_kv_mount,
            url=vault_addr) ['secret']['password'] }}

ansible_become_pass: "{{ become_password }}"
```

Ansible itself authenticates to Vault via env vars set by the wrapper script. Each `hashi_vault` lookup automatically uses `VAULT_ADDR`, `VAULT_ROLE_ID`, `VAULT_SECRET_ID` from the environment.

#### 1.2d — Helper script: `scripts/ansible-login.sh`

```bash
#!/usr/bin/env bash
# scripts/ansible-login.sh — load Vault AppRole creds for Ansible
set -euo pipefail

export VAULT_ADDR="https://192.168.40.20:8200"
export ANSIBLE_HASHI_VAULT_AUTH_METHOD="approle"
export ANSIBLE_HASHI_VAULT_ROLE_ID="$(pass show homelab/vault/ansible-role-id)"
export ANSIBLE_HASHI_VAULT_SECRET_ID="$(pass show homelab/vault/ansible-secret-id)"

echo "Ansible Vault credentials loaded. Tokens are short-lived (1h)."
```

#### 1.2e — Seed Ansible secrets into Vault

```bash
# Sudo password for the dalton user across all hosts (same password, kept in Vault, never in .yml)
vault kv put secret/ansible/sudo-password password="<strong-password-generated-here>"

# GitHub deploy keys for cloning gitops repo from inside cluster nodes (used in Tier 2)
vault kv put secret/ansible/github-deploy-key \
  private_key="$(cat ~/.ssh/homelab-deploy-key)"

# Any application-bootstrap secrets that survive cluster rebuild
# (we'll add more in later tiers as needs emerge)
```

#### Verification

- [ ] `source scripts/ansible-login.sh` then `ansible-vault --help` — no errors
- [ ] Test lookup: `ansible-inventory -i inventories/platform --list` (after creating inventory) returns vault-01/02/03 with `ansible_become_pass` populated from Vault, never written to disk
- [ ] grep the repo for `ansible-vault encrypt` or `vault_password_file` — should match nothing (v3 patterns retired)
- [ ] grep for `password:` in committed YAML files — should match only the lookup definitions, never literal values

---

### Phase 1.3: VM Provisioning via Terraform

**Goal:** All Tier 1 VMs (storage, homelab-mgmt, homelab-dev workers, prod-w-03) created via Terraform with cloud-init bootstrap. Reproducible, version-controlled, Vault-authenticated.

#### 1.3a — Reusable VM module (`modules/proxmox-vm`)

```hcl
# modules/proxmox-vm/main.tf
terraform {
  required_providers {
    proxmox = {
      source = "bpg/proxmox"
    }
  }
}

resource "proxmox_virtual_environment_vm" "this" {
  name        = var.name
  description = var.description
  tags        = var.tags
  node_name   = var.proxmox_node

  cpu {
    cores = var.cpu_cores
    type  = "host"
  }

  memory {
    dedicated = var.memory_mb
  }

  disk {
    datastore_id = var.datastore_id
    file_id      = var.cloud_image_id
    interface    = "scsi0"
    size         = var.disk_size_gb
    discard      = "on"
    ssd          = true
  }

  network_device {
    bridge   = "vmbr0"
    vlan_id  = var.vlan_id
  }

  initialization {
    ip_config {
      ipv4 {
        address = "${var.ip_address}/24"
        gateway = var.gateway   # The VRRP virtual IP from Tier 0 — 192.168.40.1, .50.1, etc.
      }
    }

    user_account {
      username = "dalton"
      keys     = [var.ssh_public_key]
    }

    dns {
      servers = var.dns_servers
    }
  }

  agent {
    enabled = true
  }

  operating_system {
    type = "l26"
  }
}
```

`modules/proxmox-vm/variables.tf` defines all inputs (omitted for brevity, but follows the structure above).

#### 1.3b — Environment: homelab-prod (just prod-w-03, the worker VM)

```hcl
# environments/homelab-prod/main.tf
data "vault_kv_secret_v2" "cloud_init" {
  mount = "secret"
  name  = "terraform/cloud-init"
}

module "prod-w-03" {
  source = "../../modules/proxmox-vm"

  name           = "prod-w-03"
  description    = "homelab-prod worker VM (RKE2 agent)"
  tags           = ["homelab-prod", "rke2-worker", "v4"]
  proxmox_node   = "pve-01"
  cpu_cores      = 4
  memory_mb      = 8192
  disk_size_gb   = 80
  datastore_id   = "local-lvm"
  cloud_image_id = "local:iso/ubuntu-24.04-server-cloudimg-amd64.img"
  vlan_id        = 50
  ip_address     = "192.168.50.33"
  gateway        = "192.168.50.1"
  dns_servers    = ["192.168.40.1", "1.1.1.1"]
  ssh_public_key = data.vault_kv_secret_v2.cloud_init.data["ssh_authorized_keys"]
}
```

#### 1.3c — Environment: homelab-dev (all three VMs on pve-02)

```hcl
# environments/homelab-dev/main.tf
locals {
  homelab_dev_nodes = {
    dev-cp-01 = { ip = "192.168.60.30", role = "control-plane", cpu = 4, mem = 8192, disk = 80 }
    dev-w-01   = { ip = "192.168.60.31", role = "worker",        cpu = 4, mem = 6144, disk = 80 }
    dev-w-02   = { ip = "192.168.60.32", role = "worker",        cpu = 4, mem = 6144, disk = 80 }
  }
}

data "vault_kv_secret_v2" "cloud_init" {
  mount = "secret"
  name  = "terraform/cloud-init"
}

module "homelab_dev_node" {
  source   = "../../modules/proxmox-vm"
  for_each = local.homelab_dev_nodes

  name           = each.key
  description    = "homelab-dev ${each.value.role}"
  tags           = ["homelab-dev", "rke2-${each.value.role}", "v4"]
  proxmox_node   = "pve-02"
  cpu_cores      = each.value.cpu
  memory_mb      = each.value.mem
  disk_size_gb   = each.value.disk
  datastore_id   = "local-lvm"
  cloud_image_id = "local:iso/ubuntu-24.04-server-cloudimg-amd64.img"
  vlan_id        = 60
  ip_address     = each.value.ip
  gateway        = "192.168.60.1"
  dns_servers    = ["192.168.40.1", "1.1.1.1"]
  ssh_public_key = data.vault_kv_secret_v2.cloud_init.data["ssh_authorized_keys"]
}
```

> **Resource sanity check for M920x (32GB total):** dev-cp-01 (CP) at 8GB + dev-w-01/dev-w-02 (workers) at 6GB each = 20GB for homelab-dev. Plus vault-03 (2GB) + bgp-02 (1GB) + mgmt-03 (6GB) = 29GB allocated, ~3GB headroom for the host. Tight but workable. CP gets more headroom than workers because etcd is memory-sensitive.

#### 1.3d — Environment: homelab-mgmt (three HA VMs split across hypervisors)

```hcl
# environments/mgmt/main.tf
locals {
  homelab_mgmt_nodes = {
    mgmt-01     = { ip = "192.168.40.60", proxmox = "pve-01", cpu = 4, mem = 6144, disk = 60 }
    mgmt-02  = { ip = "192.168.40.61", proxmox = "pve-01", cpu = 4, mem = 6144, disk = 60 }
    mgmt-03   = { ip = "192.168.40.62", proxmox = "pve-02", cpu = 4, mem = 6144, disk = 60 }
  }
}

module "mgmt_node" {
  source   = "../../modules/proxmox-vm"
  for_each = local.homelab_mgmt_nodes

  name           = each.key
  description    = "homelab-mgmt RKE2 HA node"
  tags           = ["homelab-mgmt", "rke2-server", "v4"]
  proxmox_node   = each.value.proxmox
  cpu_cores      = each.value.cpu
  memory_mb      = each.value.mem
  disk_size_gb   = each.value.disk
  # ... (same pattern as homelab-dev)
  vlan_id        = 40
  ip_address     = each.value.ip
  gateway        = "192.168.40.1"
}
```

> **HA topology choice:** 2 mgmt nodes on pve-01, 1 on pve-02. If pve-02 fails, mgmt cluster keeps quorum (2 of 3 alive). If pve-01 fails, mgmt is down (only 1 of 3 alive). This is asymmetric availability — appropriate because pve-01 is the "prod-adjacent" hypervisor and mgmt is platform tier. The alternative (2 on B) would mean pve-02 host failure takes mgmt down, which is worse since B also hosts dev/staging. Document the reasoning.

#### 1.3e — Environment: storage

```hcl
# environments/storage/main.tf
module "nfs_server" {
  source = "../../modules/proxmox-vm"

  name           = "nfs-01"
  description    = "ZFS-backed NFS for cluster persistent storage"
  tags           = ["storage", "v4"]
  proxmox_node   = "pve-01"
  cpu_cores      = 2
  memory_mb      = 4096
  disk_size_gb   = 200                    # OS + ZFS data pool
  # ... (same pattern)
  vlan_id        = 40
  ip_address     = "192.168.40.51"
  gateway        = "192.168.40.1"
}

# Garage runs in an LXC container — cheaper, fine for object storage
resource "proxmox_virtual_environment_container" "garage" {
  node_name    = "pve-01"
  description  = "Garage S3-compatible object storage"
  tags         = ["storage", "garage", "v4"]

  initialization {
    hostname = "garage-01"
    ip_config {
      ipv4 {
        address = "192.168.40.53/24"
        gateway = "192.168.40.1"
      }
    }
    user_account {
      keys = [data.vault_kv_secret_v2.cloud_init.data["ssh_authorized_keys"]]
    }
  }

  cpu    { cores = 2 }
  memory { dedicated = 2048 }
  disk {
    datastore_id = "local-lvm"
    size         = 100
  }
  operating_system {
    template_file_id = "local:vztmpl/ubuntu-24.04-standard.tar.zst"
    type             = "ubuntu"
  }
}
```

#### Verification

- [ ] `terraform plan` for each environment shows the expected number of resources
- [ ] `terraform apply` succeeds for each environment in this order: `storage` → `mgmt` → `homelab-dev` → `homelab-prod`
- [ ] All VMs reachable via SSH from workstation (`ssh dalton@<ip>` works for every host)
- [ ] No secrets in any tfvars or state file (`grep -r 'api_token\|password' .` returns only the variable declarations and Vault data sources)
- [ ] Tag all VMs with `v4` in Proxmox UI for easy bulk-management

---

### Phase 1.4: Baremetal Preparation (homelab-prod Nodes)

**Goal:** The three baremetal Lenovo M920q machines (prod-cp-01, prod-w-01, prod-w-02) running Ubuntu Server 24.04 with the same baseline as the VMs, ready for Ansible to take over.

> **Why this stays in v4 unchanged from v3:** The baremetal nodes don't need re-imaging. We're upgrading the cluster software (k3s → RKE2), not the OS. If v3 left them in good shape, just verify and proceed. If you're starting fresh on any of them, follow v3 Phase 1.

- [ ] All three baremetal nodes on latest Ubuntu 24.04 LTS, fully patched
- [ ] Static IPs assigned: prod-cp-01 `192.168.50.30`, prod-w-01 `192.168.50.31`, prod-w-02 `192.168.50.32`
- [ ] Each gets a DHCP reservation on the edge router as a belt-and-suspenders
- [ ] SSH access via `dalton` user with key-only auth (no password auth)
- [ ] `qemu-guest-agent` not needed (these aren't VMs), but `chrony` for time sync, `htop`, `vim`, `curl` should be installed

---

### Phase 1.5: OS Hardening Playbook

**Goal:** A single Ansible playbook hardens every host — VMs and baremetal alike — to a CIS-adjacent baseline. Idempotent, re-runnable, drift-correcting.

> **Why "CIS-adjacent" instead of full CIS:** Full DISA STIG or CIS Level 2 hardening on a homelab introduces real toil for things you'll rarely need (mandatory FIPS modules, audit daemon retention, kernel boot parameters that break some hardware). We implement the *useful* portions and document what we skipped and why. That's the same engineering judgment you'd apply in a regulated environment — apply controls where they earn their cost.

#### 1.5a — Hardening role outline (`roles/hardening`)

The role applies, at minimum:

| Control                          | Implementation                                          |
| -------------------------------- | ------------------------------------------------------- |
| Disable root SSH                 | sshd_config: `PermitRootLogin no`                       |
| Disable password auth            | sshd_config: `PasswordAuthentication no`                |
| Restrict SSH ciphers/MACs        | Modern algorithms only (ed25519, chacha20-poly1305)     |
| Kernel hardening sysctls         | `net.ipv4.conf.all.rp_filter=1`, ASLR, ptrace restrictions, etc. |
| Disable unused filesystems       | Blacklist `cramfs`, `freevxfs`, `jffs2`, `hfs`, `udf`   |
| File integrity baseline          | `aide` or `tripwire` (defer to Tier 3 if too heavy)     |
| Audit daemon                     | `auditd` with rules for sudo, user changes, file access on sensitive paths |
| Automatic security updates       | `unattended-upgrades` for security pocket only           |
| `fail2ban` for SSH               | Stops dumb brute-force attempts                          |
| Time sync                        | `chrony` with deterministic time source                  |
| Hostname & FQDN                  | Set per-host via inventory                               |

The role pulls any required secrets (e.g., audit log shipping credentials, when added later) from Vault via the `hashi_vault` lookup pattern from Phase 1.2.

> **Specific control to write down for the ADR:** `fail2ban` on SSH is *belt and suspenders* — public-key-only auth already blocks brute force entirely. But fail2ban gives you a log of attempts and rate-limits them at the firewall, which is observable evidence for the audit story. Keep it; document why it's redundant.

#### 1.5b — Run the hardening playbook

```bash
source scripts/ansible-login.sh

# Hit all hosts at once. The play is idempotent; re-running is safe.
ansible-playbook -i inventories/platform/   playbooks/10-harden.yml
ansible-playbook -i inventories/storage/    playbooks/10-harden.yml
ansible-playbook -i inventories/homelab-prod/ playbooks/10-harden.yml
ansible-playbook -i inventories/homelab-dev/      playbooks/10-harden.yml
ansible-playbook -i inventories/mgmt/       playbooks/10-harden.yml
```

#### Verification

- [ ] `ssh root@<any-host>` is rejected
- [ ] `ssh dalton@<any-host>` with password (try wrong key) is rejected
- [ ] `sudo systemctl status auditd` shows running on all hosts
- [ ] `chronyc tracking` on every host shows sync to a real time source, drift < 50ms
- [ ] `lynis audit system` (optional, but a nice gut-check) shows hardening index > 75

---

### Phase 1.6: Vault SSH OTP Enrollment

**Goal:** Every host enrolled with `vault-ssh-helper` so that the dalton user's SSH password becomes a one-time password issued by Vault on demand. The static sudo password becomes a fallback for emergencies, with auditable normal use going through Vault.

> **What this gives you:** Every privileged session on every host is auditable in Vault. You can answer "who escalated privileges on prod-w-01 between 9am and noon last Tuesday" with a Vault audit log query. That capability alone justifies the complexity, and it's exactly what defense audit teams ask for.

#### 1.6a — Role: `roles/vault-ssh-helper`

The role's tasks (applied to every host):

1. Install `vault-ssh-helper` binary (download from HashiCorp releases, or vendor into Garage S3 once it exists)
2. Drop config to `/etc/vault-ssh-helper.d/config.hcl`:
   ```hcl
   vault_addr      = "https://192.168.40.20:8200"
   ssh_mount_point = "ssh"
   ca_cert         = "/etc/ssl/certs/homelab-root-ca.crt"
   tls_skip_verify = false
   allowed_roles   = "otp-baremetal"
   ```
3. Distribute the homelab root CA cert to `/etc/ssl/certs/homelab-root-ca.crt` (read from Vault via the `pki_root/cert/ca` endpoint)
4. Configure PAM to consult `vault-ssh-helper`:
   ```
   # /etc/pam.d/sshd  — add at the top of "auth" block
   auth required pam_exec.so quiet expose_authtok log=/var/log/vault-ssh.log /usr/local/bin/vault-ssh-helper -dev -config=/etc/vault-ssh-helper.d/config.hcl
   auth optional pam_unix.so not_set_pass use_first_pass nodelay
   ```
5. Configure sshd:
   ```
   # /etc/ssh/sshd_config additions
   ChallengeResponseAuthentication yes
   UsePAM yes
   PasswordAuthentication no   # public-key auth is still required first
   ```
6. Restart `sshd`

#### 1.6b — Workstation usage flow

To get a one-time password and SSH in:

```bash
# Request an OTP from Vault for a specific host
vault write ssh/creds/otp-baremetal ip=192.168.50.30
# Returns: key = abc123-d4e5...

# SSH normally; the OTP is the password
ssh dalton@prod-cp-01
# password prompt: paste the OTP from above

# OTP is single-use. Next session needs a new one.
```

Add a wrapper for ergonomics — `scripts/vault-ssh.sh`:

```bash
#!/usr/bin/env bash
HOST="$1"
IP="$(dig +short "$HOST" 2>/dev/null || echo "$HOST")"

OTP="$(vault write -field=key ssh/creds/otp-baremetal ip="$IP")"
sshpass -p "$OTP" ssh dalton@"$IP"
```

#### Verification

- [ ] OTP issuance via `vault write ssh/creds/otp-baremetal ip=192.168.40.20` returns a key
- [ ] SSH to a host using the OTP as password succeeds
- [ ] Re-using the same OTP fails (single-use enforcement)
- [ ] `vault audit list` shows audit device, and `tail -f /opt/vault/audit.log` shows OTP issuance events with timestamp + requester
- [ ] Public-key SSH still works for normal automation (Terraform, Ansible) — OTP is for *interactive privileged sessions*, not for routine programmatic access

---

### Phase 1.7: Storage Tier

**Goal:** NFS-backed persistent storage available to all clusters, plus S3-compatible object storage via Garage for Velero backups, Harbor blob storage, and Loki long-term retention.

#### 1.7a — NFS server (Ansible role: `roles/nfs-server`)

On `nfs-01` (192.168.40.51), provisioned in Phase 1.3:

1. Attach a second virtual disk in Proxmox if not already present (size to taste — 500GB minimum for v4 with three clusters)
2. Install ZFS: `apt install -y zfsutils-linux`
3. Create a single-disk ZFS pool: `zpool create -o ashift=12 tank /dev/sdb`
4. Filesystems for cluster separation:
   ```bash
   zfs create -o compression=lz4 -o atime=off tank/homelab-prod
   zfs create -o compression=lz4 -o atime=off tank/homelab-dev
   zfs create -o compression=lz4 -o atime=off tank/mgmt
   zfs create -o compression=lz4 -o atime=off tank/garage-meta
   ```
5. Set quotas per environment (e.g., homelab-prod 200G, homelab-dev 100G, mgmt 100G — tune to your workloads)
6. Install NFS: `apt install -y nfs-kernel-server`
7. Export each filesystem to its corresponding cluster's VLAN:
   ```
   /tank/homelab-prod   192.168.50.0/24(rw,sync,no_subtree_check,no_root_squash)
   /tank/homelab-dev        192.168.60.0/24(rw,sync,no_subtree_check,no_root_squash)
   /tank/mgmt         192.168.40.0/24(rw,sync,no_subtree_check,no_root_squash)
   ```
8. `exportfs -ra` && `systemctl enable --now nfs-server`
9. **Snapshot policy**: cron job runs `zfs snapshot -r tank@$(date +%Y%m%d-%H%M)` every 6 hours, retains 28 days. This is your last line of defense against accidental cluster-side deletions.

> **Defense-relevant note:** `no_root_squash` is necessary for K8s PVs to function with proper permissions but creates a real attack vector — root in any pod can write as root on the NFS filer. Mitigations: NFS server is on a separate VLAN, firewalled to accept connections only from the named subnets, hardened OS baseline, and Cilium NetworkPolicy will block egress from non-storage namespaces in Tier 2. Document the residual risk in the ADR. The defense-industry framing is exactly this — "we accepted X risk because Y mitigations bring residual risk below threshold."

#### 1.7b — Garage S3 (Ansible role: `roles/garage`)

On the `garage-01` LXC (192.168.40.53):

1. Install Garage binary
2. Configure layout: single-node deployment with one zone, 100GB capacity
3. Buckets to pre-create:
   - `velero-backups-homelab-prod`
   - `velero-backups-homelab-dev`
   - `velero-backups-mgmt`
   - `harbor-registry` (for Tier 2 Harbor blob storage)
   - `loki-chunks-mgmt` (for Tier 3 Loki object storage)
   - `tempo-traces-mgmt` (for Tier 3 Tempo)
4. Create access keys per bucket consumer (one per Velero instance, one for Harbor, one for Loki, one for Tempo). Store all in Vault:
   ```bash
   vault kv put secret/garage/velero-homelab-prod access_key=... secret_key=...
   vault kv put secret/garage/velero-homelab-dev      access_key=... secret_key=...
   vault kv put secret/garage/harbor            access_key=... secret_key=...
   # ...etc
   ```

#### Verification

- [ ] From any host in VLAN 50: `showmount -e 192.168.40.51` lists `/tank/homelab-prod`
- [ ] Mount test: `mount -t nfs 192.168.40.51:/tank/homelab-prod /mnt && touch /mnt/test && umount /mnt`
- [ ] ZFS snapshot script runs successfully and `zfs list -t snapshot` shows snapshots being created
- [ ] Garage `garage status` shows healthy single-node cluster
- [ ] Garage S3 API reachable: `aws --endpoint http://192.168.40.53:3900 s3 ls` (after configuring `~/.aws/credentials` with one of the keys) shows the pre-created buckets

---

### Phase 1.8: RKE2 Installation — homelab-prod (Prod)

**Goal:** homelab-prod running RKE2 v1.31+ in CIS profile mode with etcd encryption-at-rest, audit logging, and Cilium as the CNI (BGP control plane enabled, replacing kube-proxy).

> **The critical RKE2 advantages over v3's k3s:** CIS profile flag handles ~80% of CIS Kubernetes Benchmark controls automatically. Etcd encryption-at-rest is a config-file flag instead of a manual etcd patch. Audit policy ships built-in. These are real production muscles that k3s makes you build from scratch.

#### 1.8a — RKE2 control plane (prod-cp-01)

The RKE2 server config goes at `/etc/rancher/rke2/config.yaml` on prod-cp-01. Build it in Ansible (`roles/rke2-control-plane`):

```yaml
# /etc/rancher/rke2/config.yaml — prod-cp-01 (homelab-prod CP)
token: "{{ rke2_cluster_token }}"   # from Vault: secret/ansible/rke2-tokens homelab_prod_token

# Hardening
profile: cis                         # auto-applies CIS Kubernetes Benchmark hardening
secrets-encryption: true             # AES-CBC at rest in etcd
write-kubeconfig-mode: "0600"
selinux: true

# Audit logging
audit-policy-file: /etc/rancher/rke2/audit-policy.yaml
kube-apiserver-arg:
  - audit-log-path=/var/log/rke2/audit.log
  - audit-log-maxage=30
  - audit-log-maxbackup=10
  - audit-log-maxsize=100

# Disable RKE2 default ingress/CNI — we install Cilium ourselves
disable:
  - rke2-ingress-nginx
  - rke2-canal
cni: cilium
disable-kube-proxy: true             # Cilium replaces kube-proxy entirely

# TLS SANs — include the BGP virtual IP if we ever front the API with a LB
tls-san:
  - prod-cp-01.homelab.internal
  - 192.168.50.30
  - homelab-prod-api.homelab.internal

# Node name
node-name: prod-cp-01
node-label:
  - "topology.kubernetes.io/zone=homelab-prod-cp"
  - "node-role.kubernetes.io/control-plane=true"
node-taint:
  - "CriticalAddonsOnly=true:NoExecute"   # keep workloads off the CP
```

Audit policy at `/etc/rancher/rke2/audit-policy.yaml`:

```yaml
# /etc/rancher/rke2/audit-policy.yaml — Metadata level for everything,
# RequestResponse for sensitive resources (secrets, RBAC, exec/portforward).
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
  - level: RequestResponse
    resources:
      - group: ""
        resources: ["secrets", "configmaps", "pods/exec", "pods/portforward"]
      - group: "rbac.authorization.k8s.io"
        resources: ["*"]
  - level: Metadata
    omitStages: ["RequestReceived"]
```

#### 1.8b — Cilium HelmChartConfig pre-staged

Drop at `/var/lib/rancher/rke2/server/manifests/cilium-config.yaml` *before* starting RKE2 (this way RKE2's helm-controller applies your config, not the default):

```yaml
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: rke2-cilium
  namespace: kube-system
spec:
  valuesContent: |-
    kubeProxyReplacement: true
    k8sServiceHost: 192.168.50.30
    k8sServicePort: 6443

    # BGP control plane (replaces v3's L2 announcements)
    bgpControlPlane:
      enabled: true

    # Gateway API
    gatewayAPI:
      enabled: true

    # Hubble for observability
    hubble:
      enabled: true
      relay:
        enabled: true
      ui:
        enabled: true
        rollOutPods: true

    # eBPF features
    bpf:
      masquerade: true
    encryption:
      enabled: true                   # WireGuard transparent encryption between pods
      type: wireguard
      nodeEncryption: true

    # Tetragon for runtime security observability (event source — Falco consumes in Tier 3)
    tetragon:
      enabled: true

    # IP allocation
    ipam:
      mode: kubernetes
    ipv4NativeRoutingCIDR: "10.42.0.0/16"
    routingMode: native
    autoDirectNodeRoutes: true
```

> **WireGuard pod-to-pod encryption:** v3 didn't enable this. v4 does. The performance hit is small (~5-10% throughput on a homelab), and "all east-west traffic encrypted at the network layer" is a strong defense-relevant property. Same key principle as TLS-everywhere but at L3.

#### 1.8c — Install RKE2 on prod-cp-01

The `roles/rke2-control-plane` Ansible role:

1. Fetches RKE2 cluster token from Vault: `vault kv get -field=homelab_prod_token secret/ansible/rke2-tokens`
2. Writes `/etc/rancher/rke2/config.yaml`, `audit-policy.yaml`, and the Cilium HelmChartConfig
3. Runs the official RKE2 install script:
   ```bash
   curl -sfL https://get.rke2.io | INSTALL_RKE2_TYPE=server sh -
   ```
4. Enables and starts the systemd service: `systemctl enable --now rke2-server`
5. Waits for `/etc/rancher/rke2/rke2.yaml` to appear and validates the API is responding

> **Air-gap pattern hook:** v3 pulled RKE2 directly from GitHub. v4 prods (homelab-prod, homelab-dev) will pull from your local Garage mirror starting once Harbor exists in Tier 2. For Tier 1 bootstrap, the direct download is acceptable — note it as a known compromise. The dependency will be inverted in Tier 2 once Harbor proxies the RKE2 release artifacts.

#### 1.8d — Install RKE2 on worker nodes (prod-w-01, prod-w-02, prod-w-03)

Workers get a much simpler config — just enough to join the cluster:

```yaml
# /etc/rancher/rke2/config.yaml — worker
server: https://prod-cp-01.homelab.internal:9345
token: "{{ rke2_cluster_token }}"
node-name: prod-w-01  # change per host
profile: cis
selinux: true
node-label:
  - "topology.kubernetes.io/zone=homelab-prod-worker"
```

Install as agent: `curl -sfL https://get.rke2.io | INSTALL_RKE2_TYPE=agent sh -`. Enable `rke2-agent` service.

#### 1.8e — kubeconfig retrieval

The `roles/kubeconfig-collector` role copies `/etc/rancher/rke2/rke2.yaml` from prod-cp-01 to the workstation, rewrites the `server:` field to the external IP, and labels the context:

```bash
# Collected to: ~/.kube/homelab-prod-rke2.yaml
# Context renamed to: homelab-prod
```

Store in `pass`:

```bash
pass insert -m homelab/kubeconfigs/homelab-prod < ~/.kube/homelab-prod-rke2.yaml
```

#### Verification

- [ ] `kubectl --context homelab-prod get nodes` shows 4 nodes, all Ready
- [ ] `kubectl --context homelab-prod get pods -A` shows Cilium pods running, no CrashLoopBackOff
- [ ] `kubectl --context homelab-prod exec -n kube-system ds/cilium -- cilium status` shows all health checks green, kube-proxy replacement = Strict, encryption = Wireguard
- [ ] `kubectl --context homelab-prod get crd | grep -i bgp` shows the Cilium BGP CRDs installed
- [ ] `tail /var/log/rke2/audit.log` on prod-cp-01 shows audit events being written
- [ ] `kubectl --context homelab-prod get secrets -A` works AND `etcdctl get` directly against etcd's data file shows encrypted blobs (not plaintext secret values)

---

### Phase 1.9: RKE2 Installation — homelab-dev (Dev/Staging)

Identical procedure to Phase 1.8 with these changes:

- Control plane: dev-cp-01 (192.168.60.30), workers: dev-w-01 (.31), dev-w-02 (.32)
- VLAN 60, ASN 65002, `topology.kubernetes.io/zone=homelab-dev-*` labels
- Different cluster token from Vault: `secret/ansible/rke2-tokens homelab_dev_token`
- Cilium config: `k8sServiceHost: 192.168.60.30`, BGP ASN matches Tier 0 plan
- Cluster context: `homelab-dev`

> **No CP HA on homelab-dev:** Single control plane is acceptable for dev/staging — losing it just means cluster API unavailable, workloads keep running, and you can restore from Velero. Documenting this asymmetry (homelab-prod has multi-master option later; homelab-dev deliberately doesn't) is a real-world tradeoff worth writing into the ADR.

---

### Phase 1.10: RKE2 Installation — Mgmt-Plane (3-Node HA)

The first place we run an actual HA control plane.

#### 1.10a — Init the cluster on mgmt-01 (first server)

```yaml
# /etc/rancher/rke2/config.yaml — mgmt-01
token: "{{ rke2_mgmt_token }}"
profile: cis
secrets-encryption: true
selinux: true
cni: cilium
disable-kube-proxy: true
disable:
  - rke2-ingress-nginx
  - rke2-canal
audit-policy-file: /etc/rancher/rke2/audit-policy.yaml
# ... (rest as in homelab-prod CP)

# HA-specific
tls-san:
  - mgmt-01.homelab.internal
  - mgmt-02.homelab.internal
  - mgmt-03.homelab.internal
  - mgmt-api.homelab.internal
  - 192.168.40.60
  - 192.168.40.61
  - 192.168.40.62

node-name: mgmt-01
```

#### 1.10b — Join mgmt-02 and mgmt-03 as additional servers

```yaml
# /etc/rancher/rke2/config.yaml — mgmt-02 and mgmt-03
server: https://mgmt-01.homelab.internal:9345
token: "{{ rke2_mgmt_token }}"
profile: cis
secrets-encryption: true
selinux: true
cni: cilium
disable-kube-proxy: true
disable:
  - rke2-ingress-nginx
  - rke2-canal
tls-san:
  - mgmt-api.homelab.internal
node-name: mgmt-02  # or mgmt-03
```

Crucially: these are *server* nodes, not agents. They join the etcd cluster and run the control plane.

> **3-node etcd consideration:** Etcd needs odd-numbered quorum (3, 5, 7). With 3 servers you can lose 1 and stay operational. That's the entire point of the upgrade from v3's single-node homelab-mgmt.

#### Verification

- [ ] `kubectl --context mgmt get nodes` shows 3 nodes, all Ready with role `control-plane,etcd,master`
- [ ] `kubectl --context mgmt get componentstatuses` (deprecated but informative) shows etcd healthy
- [ ] Stop `rke2-server` on mgmt-03 — `kubectl --context mgmt get nodes` shows it NotReady within ~1m, but other operations against the cluster continue working (etcd quorum maintained with 2 of 3)
- [ ] Restart mgmt-03 — rejoins, all 3 nodes Ready again
- [ ] All three nodes show `secrets-encryption=true` and audit log written

---

### Phase 1.11: Etcd Snapshot Off-Host Replication

**Goal:** RKE2 etcd snapshots from all three clusters land in Garage S3 (off-hypervisor) and are replicated to AWS S3 with Object Lock (off-prem, tamper-evident). A hypervisor loss does not take cluster state with it.

> **Why this matters:** RKE2 takes etcd snapshots every 6 hours by default, but writes them to local disk on the same hypervisor as the cluster. If pve-02 dies hard, homelab-dev *and* every snapshot of its state die with it. Velero covers app state and PVCs; it doesn't cover etcd. Without off-host etcd snapshots, your DR posture is "rebuild from scratch and replay GitOps" — survivable but slow.

#### 1.11a — RKE2 S3 snapshot configuration

For each cluster's control planes, add S3 snapshot config under `/etc/rancher/rke2/config.yaml.d/etcd-s3.yaml`:

```yaml
etcd-snapshot-schedule-cron: "0 */6 * * *"
etcd-snapshot-retention: 12
etcd-s3: true
etcd-s3-endpoint: garage-01.homelab.internal:3900
etcd-s3-bucket: rke2-etcd-snapshots
etcd-s3-region: garage
etcd-s3-folder: homelab-prod   # or homelab-dev / homelab-mgmt per cluster
etcd-s3-skip-ssl-verify: false
```

Credentials come from Vault. Ansible role `roles/rke2-server` reads them at config-render time and writes a separate credentials file with `0600` perms:

```yaml
- name: Materialize RKE2 S3 credentials from Vault
  template:
    src: etcd-s3-creds.yml.j2
    dest: /etc/rancher/rke2/config.yaml.d/etcd-s3-creds.yaml
    owner: root
    group: root
    mode: '0600'
  vars:
    s3_access_key: "{{ lookup('community.hashi_vault.vault_read', 'secret/rke2/etcd-snapshots').data.data.access_key }}"
    s3_secret_key: "{{ lookup('community.hashi_vault.vault_read', 'secret/rke2/etcd-snapshots').data.data.secret_key }}"
```

Restart `rke2-server` on one CP at a time, watch the etcd snapshot logs for successful S3 upload.

#### 1.11b — Garage bucket setup

On garage-01:

```bash
garage bucket create rke2-etcd-snapshots
garage key new --name rke2-snapshots
garage bucket allow rke2-etcd-snapshots --read --write --key rke2-snapshots

# Store the key in Vault
vault kv put secret/rke2/etcd-snapshots \
  access_key=<key-id> \
  secret_key=<secret>
```

Folder structure ends up:
```
rke2-etcd-snapshots/
  homelab-prod/<snapshot-name>.zip
  homelab-dev/<snapshot-name>.zip
  homelab-mgmt/<snapshot-name>.zip
```

RKE2 manages retention (keeps the latest 12 per cluster); no Garage lifecycle policy needed on this bucket.

#### 1.11c — AWS S3 DR target with Object Lock

The off-prem, tamper-evident tier. Object Lock enables WORM (write-once-read-many) — objects cannot be deleted or modified before the retention window expires, even by the bucket owner.

```hcl
# homelab-terraform/modules/etcd-snapshot-dr/main.tf
resource "aws_s3_bucket" "etcd_dr" {
  bucket              = "homelab-etcd-snapshots-dr"
  object_lock_enabled = true
}

resource "aws_s3_bucket_versioning" "etcd_dr" {
  bucket = aws_s3_bucket.etcd_dr.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_object_lock_configuration" "etcd_dr" {
  bucket = aws_s3_bucket.etcd_dr.id
  rule {
    default_retention {
      mode = "GOVERNANCE"  # COMPLIANCE if you want even the root user blocked
      days = 30
    }
  }
}
```

#### 1.11d — Replication from Garage to AWS

A CronJob in homelab-mgmt syncs every 6h, 30 minutes after RKE2's snapshot window:

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: etcd-snapshots-to-aws
  namespace: platform-dr
spec:
  schedule: "30 */6 * * *"
  jobTemplate:
    spec:
      template:
        spec:
          containers:
            - name: rclone
              image: harbor.homelab.local/rclone/rclone:latest
              command:
                - rclone
                - sync
                - garage:rke2-etcd-snapshots
                - aws:homelab-etcd-snapshots-dr
                - --transfers=4
                - --immutable
              env:
                - name: RCLONE_S3_PROVIDER_garage
                  value: Other
                - name: RCLONE_S3_ACCESS_KEY_ID_garage
                  valueFrom: { secretKeyRef: { name: garage-snapshot-creds, key: access-key } }
                - name: RCLONE_S3_SECRET_ACCESS_KEY_garage
                  valueFrom: { secretKeyRef: { name: garage-snapshot-creds, key: secret-key } }
                - name: AWS_ACCESS_KEY_ID
                  valueFrom: { secretKeyRef: { name: aws-snapshot-creds, key: access-key } }
                - name: AWS_SECRET_ACCESS_KEY
                  valueFrom: { secretKeyRef: { name: aws-snapshot-creds, key: secret-key } }
```

AWS creds come from Vault AWS secrets engine (provisioned in Tier 5.7) once that exists; until then, a static IAM user with write-only-to-bucket permission, key in Vault.

#### 1.11e — Restoration runbook

Document the recovery path explicitly. Lives in `homelab-gitops/docs/runbooks/etcd-restore.md`:

1. Identify the dead cluster.
2. Retrieve the most recent snapshot from Garage (`s3cmd get s3://rke2-etcd-snapshots/<cluster>/<latest>.zip`). If Garage is also gone, pull from the AWS DR bucket.
3. On a surviving CP node or freshly provisioned VM, run: `rke2 server --cluster-reset --cluster-reset-restore-path=/path/to/snapshot.zip`
4. Re-join workers (`rke2 agent` with the cluster token).
5. Verify with `kubectl get nodes` and smoke-test by triggering an Argo CD sync.

#### Verification

- [ ] All three clusters writing snapshots to `garage:rke2-etcd-snapshots/<cluster>/` every 6 hours
- [ ] AWS S3 DR bucket receives snapshots within 30 minutes of Garage write (CronJob log shows success)
- [ ] Object Lock confirmed: `aws s3api delete-object --bucket homelab-etcd-snapshots-dr --key <snapshot>` returns AccessDenied
- [ ] Restoration runbook executed end-to-end on homelab-dev (controlled test): cluster killed, restored from snapshot, healthy within 15 minutes

---

### Phase 1.12: Kubeconfig Management

`pass`/Chezmoi pattern from v3 carries forward, expanded:

```bash
# Three kubeconfigs, one per cluster
pass insert -m homelab/kubeconfigs/homelab-prod  < ~/.kube/homelab-prod-rke2.yaml
pass insert -m homelab/kubeconfigs/homelab-dev       < ~/.kube/homelab-dev-rke2.yaml
pass insert -m homelab/kubeconfigs/mgmt        < ~/.kube/mgmt-rke2.yaml
pass git push
```

Chezmoi template at `~/.config/chezmoi/dot_config/private_kubeconfigs/kubeconfig.tmpl` merges the three into a single file with three labeled contexts (`homelab-prod`, `homelab-dev`, `mgmt`), set by `kubectx`.

```bash
kubectx homelab-prod   # context for prod
kubectx homelab-dev        # context for dev/staging
kubectx mgmt         # context for observability + identity
```

---

### Phase 1.13: Tier 1 Verification Gate

**Tier 1 is complete when every item below passes.** Tier 2 cannot begin until then.

#### Provisioning automation

- [ ] All VMs created via Terraform — `terraform state list` in each env shows expected resources
- [ ] All hosts (VMs + baremetal) configured via Ansible — every playbook is idempotent (re-run shows no changes)
- [ ] No `ansible-vault` files exist anywhere in the ansible repo
- [ ] No secrets in any `.tfvars` file or Terraform state (grep verified)
- [ ] Vault audit log shows authentication events from both Terraform AppRole and Ansible AppRole

#### Hardening & SSH

- [ ] Every host hardened: root SSH disabled, password auth disabled, auditd running
- [ ] Vault SSH OTP enrollment works on every host — workstation can request OTP, single-use enforced
- [ ] `lynis audit system` index ≥ 75 on every host

#### Storage

- [ ] NFS exports reachable from each cluster's VLAN
- [ ] ZFS snapshot cron runs and creates snapshots every 6h
- [ ] Garage S3 reachable, all pre-staged buckets exist, access keys for each consumer in Vault

#### Etcd disaster recovery

- [ ] All three clusters write etcd snapshots to Garage `rke2-etcd-snapshots/<cluster>/` every 6h
- [ ] CronJob `etcd-snapshots-to-aws` running; AWS DR bucket receives snapshots within 30 min
- [ ] AWS S3 Object Lock verified: deletion attempt on a snapshot returns AccessDenied
- [ ] Etcd restoration runbook executed end-to-end on homelab-dev (controlled drill): cluster restored from snapshot

#### Clusters

- [ ] **homelab-prod** (prod): 4 nodes Ready, Cilium healthy, kube-proxy replacement = Strict, WireGuard encryption on, BGP CP enabled, audit log writing, etcd secrets encryption verified
- [ ] **homelab-dev** (dev/staging): 3 nodes Ready, same Cilium and audit features active
- [ ] **Mgmt-plane**: 3 nodes Ready (HA), etcd quorum tested by stopping 1 node and confirming continued operation, all 3 nodes back online after restart
- [ ] All three kubeconfigs in `pass`, contexts labeled `homelab-prod` / `homelab-dev` / `mgmt`, `kubectx` switches between them cleanly

#### Hygiene

- [ ] No long-lived credentials on workstation outside of `pass`
- [ ] Workstation `~/.bash_history` or `~/.zsh_history` does not contain any unsealed secrets (consider `HISTIGNORE` for `vault*` commands going forward)
- [ ] Every VM tagged `v4` in Proxmox UI for easy bulk-management
- [ ] BGP peers configured in Cilium config but NOT yet established to bgp-01/bgp-02 (that happens in Tier 2 when we deploy the CiliumBGPClusterConfig CRDs)

When all of the above pass: **Tier 1 is complete.** Three operational clusters, fully Vault-authenticated provisioning chain, hardened OS baseline, storage tier ready. Tier 2 layers on the platform services that turn these clusters into a usable platform.
# Tier 2 — Platform Services

**Purpose:** Three operational clusters from Tier 1 become a usable platform. By the end of Tier 2 you have BGP-advertised load balancers, internal DNS resolution, automated certificate issuance (internal + public), a working Vault-to-Kubernetes integration on every cluster, a self-hosted container registry with image signing, the air-gap pattern in place for workload clusters, GitOps tooling installed and ready to manage workloads in Tier 4, policy enforcement in audit mode, and automated dependency updates.

**Why this tier sits between provisioning and workloads:** Tier 1 produced clusters that *exist*. Tier 2 produces clusters that are *consumable* — services can be exposed, secrets can flow in, certs are automatic, images are stored and signed, and GitOps controllers are ready to reconcile manifests. Nothing here is a workload itself; everything is infrastructure that workloads depend on.

**What changes from v3:**
- BGP control plane replaces L2 announcements (v3 used `cilium-l2announcement` CRDs)
- Two PKIs instead of one: internal CA via Vault PKI for service-to-service, Let's Encrypt for public-facing
- ESO authenticates to Vault via Kubernetes auth method (v3 used static tokens)
- Cosign keys for image signing live in Vault Transit, never on disk
- Harbor replaces "pull from Docker Hub directly" as the platform registry
- Air-gap pivot: workload clusters pull only from Harbor; homelab-mgmt keeps upstream access for observability bootstrap
- CloudNativePG operator deployed early as a platform service (v3 ran a single Postgres pod per app)
- Flux on homelab-mgmt keeps observability declarative; ArgoCD on homelab-prod manages all workload deployments across both workload clusters

## Tier 2 Phases

- **2.1** — Cilium BGP activation + internal DNS via VyOS
- **2.2** — Vault Kubernetes auth method (one backend per cluster)
- **2.3** — External Secrets Operator on all three clusters
- **2.4** — cert-manager + Vault PKI issuer + Let's Encrypt issuer
- **2.5** — Vault's own listener cert migrated to cert-manager-managed rotation
- **2.6** — Cilium Gateway API resources (per-cluster Gateway, GatewayClass)
- **2.7** — ExternalDNS (CoreDNS+etcd authoritative; ExternalDNS per cluster)
- **2.8** — CloudNativePG operator on homelab-prod
- **2.9** — Harbor deployment (Postgres via CloudNativePG, blob storage in Garage, Cosign keys in Vault Transit)
- **2.10** — Air-gap pivot: workload clusters pull from Harbor
- **2.11** — ArgoCD on homelab-prod + multi-cluster registration
- **2.12** — Flux on homelab-mgmt
- **2.13** — Kyverno in audit mode with baseline policy seeds
- **2.14** — Renovate Bot via GitHub App
- **2.15** — Supply chain attestation — SBOMs via Syft + Cosign
- **2.16** — Tier 2 verification gate

---

### Phase 2.1: Cilium BGP Activation + Internal DNS

**Goal:** Each cluster's Cilium agents peer with bgp-01/bgp-02 via eBGP and start advertising LoadBalancer IPs. VyOS resolves the `homelab.internal` domain so services have proper names.

#### 2.1a — Internal DNS on VyOS

The BGP routers also serve as the internal DNS authority for `homelab.internal`. Add to both bgp-01 and bgp-02:

```bash
configure

# Forward upstream queries (everything that isn't homelab.internal) to your edge DNS
set service dns forwarding system
set service dns forwarding listen-address 192.168.40.10  # bgp-02 uses .11
set service dns forwarding allow-from 192.168.0.0/16

# Static A records for the platform tier and cluster API endpoints
# These never change, so static records are simpler than running a real DNS daemon
set service dns forwarding host-file
set system static-host-mapping host-name vault.homelab.internal           inet 192.168.40.20
set system static-host-mapping host-name vault.homelab.internal           inet 192.168.40.21
set system static-host-mapping host-name vault.homelab.internal           inet 192.168.40.22
set system static-host-mapping host-name nfs.homelab.internal             inet 192.168.40.51
set system static-host-mapping host-name garage-01.homelab.internal          inet 192.168.40.53
set system static-host-mapping host-name homelab-prod-api.homelab.internal  inet 192.168.50.30
set system static-host-mapping host-name homelab-dev-api.homelab.internal       inet 192.168.60.30
set system static-host-mapping host-name mgmt-api.homelab.internal        inet 192.168.40.60

# Wildcard records pointing at LB IPs will be added per-service in Phase 2.6 (Gateway resources)
# For now, the cluster API endpoints and platform services are enough.

commit
save
```

Configure your UniFi gateway to forward `homelab.internal` queries to `192.168.40.1` (the VRRP virtual IP). Settings → Networks → (your VLAN) → DHCP → DNS Server → add `192.168.40.1`. Or better: add a conditional DNS forwarder in the UniFi controller (Settings → Routing → DNS → conditional forwarding) so the routing happens at the gateway level for all clients.

> **Why static records instead of a proper DNS server (CoreDNS/AdGuard):** Resisting infrastructure sprawl. Two records will change with any frequency (LB IPs for Gateway, added in Phase 2.6), and those go in by hand once per Gateway. If this list grows past ~20 entries, revisit and add CoreDNS as a dedicated platform service. For now, this is the right amount of complexity.

#### 2.1b — Cilium BGP cluster config (homelab-prod example)

The Cilium CRDs that activate BGP. Apply to homelab-prod via a manifest in `homelab-gitops/clusters/homelab-prod/networking/cilium-bgp.yaml` — this will be reconciled by ArgoCD later, but for bootstrap we `kubectl apply` it directly.

```yaml
---
apiVersion: cilium.io/v2alpha1
kind: CiliumBGPClusterConfig
metadata:
  name: homelab-prod-bgp
spec:
  nodeSelector:
    matchLabels:
      topology.kubernetes.io/zone: homelab-prod-cp
      # Plus a second selector for workers — combined via OR via separate instances if needed
  bgpInstances:
    - name: "instance-65001"
      localASN: 65001
      peers:
        - name: "bgp-01"
          peerASN: 65000
          peerAddress: 192.168.40.10
          peerConfigRef:
            name: "default-peer-config"
        - name: "bgp-02"
          peerASN: 65000
          peerAddress: 192.168.40.11
          peerConfigRef:
            name: "default-peer-config"
---
apiVersion: cilium.io/v2alpha1
kind: CiliumBGPPeerConfig
metadata:
  name: default-peer-config
spec:
  timers:
    holdTimeSeconds: 30
    keepAliveTimeSeconds: 10
  gracefulRestart:
    enabled: true
    restartTimeSeconds: 120
  families:
    - afi: ipv4
      safi: unicast
      advertisements:
        matchLabels:
          advertise: "bgp"
---
apiVersion: cilium.io/v2alpha1
kind: CiliumBGPAdvertisement
metadata:
  name: homelab-prod-services
  labels:
    advertise: "bgp"
spec:
  advertisements:
    - advertisementType: "Service"
      service:
        addresses:
          - LoadBalancerIP
      selector:
        matchExpressions:
          - key: "somekey"
            operator: "NotIn"
            values: ["never-match"]   # match all services with LoadBalancer type
---
apiVersion: cilium.io/v2alpha1
kind: CiliumLoadBalancerIPPool
metadata:
  name: homelab-prod-lb-pool
spec:
  blocks:
    - start: "192.168.50.240"
      stop: "192.168.50.250"
  serviceSelector:
    matchLabels:
      io.cilium/lb-pool: homelab-prod
```

Apply identical manifests on homelab-dev (ASN 65002, pool `192.168.60.240–250`, selector label `homelab-dev`) and homelab-mgmt (ASN 65003, pool `192.168.40.240–250`, selector label `mgmt`).

> **ASN choice on homelab-mgmt:** I had 65003 left implicit in Tier 0. Going with that — each cluster gets its own ASN so BGP loop prevention works correctly across the fabric.

#### 2.1c — Activate the second BGP peer on VyOS

In Tier 0 we pre-staged neighbor-groups but didn't bind specific peers. Now bind the cluster nodes as peers. On bgp-01:

```bash
configure

# homelab-prod nodes peer from VLAN 50
set protocols bgp neighbor 192.168.50.30 peer-group homelab-prod
set protocols bgp neighbor 192.168.50.31 peer-group homelab-prod
set protocols bgp neighbor 192.168.50.32 peer-group homelab-prod
set protocols bgp neighbor 192.168.50.33 peer-group homelab-prod

# homelab-dev nodes peer from VLAN 60
set protocols bgp neighbor 192.168.60.30 peer-group homelab-dev
set protocols bgp neighbor 192.168.60.31 peer-group homelab-dev
set protocols bgp neighbor 192.168.60.32 peer-group homelab-dev

# Mgmt-plane peers from VLAN 40
set protocols bgp neighbor-group mgmt remote-as 65003
set protocols bgp neighbor 192.168.40.60 peer-group mgmt
set protocols bgp neighbor 192.168.40.61 peer-group mgmt
set protocols bgp neighbor 192.168.40.62 peer-group mgmt

commit
save
```

Mirror on bgp-02.

#### Verification

- [ ] `dig +short vault.homelab.internal @192.168.40.1` returns all three Vault IPs
- [ ] `dig +short homelab-prod-api.homelab.internal @192.168.40.1` returns `192.168.50.30`
- [ ] On bgp-01, `show ip bgp summary` shows BGP sessions in `Established` state for every cluster node
- [ ] On any homelab-prod node, `kubectl exec -n kube-system ds/cilium -- cilium bgp peers` shows two peers (bgp-01, bgp-02) Established
- [ ] Create a quick test Service with `type: LoadBalancer` and label `io.cilium/lb-pool: homelab-prod`, get an IP from the pool, `ping` that IP from your workstation. Delete the test service.
- [ ] Failover test: stop bgp-01, the LB IP stays reachable via bgp-02 within ~10 seconds. Restart bgp-01.

---

### Phase 2.2: Vault Kubernetes Auth Method

**Goal:** Workloads in any cluster authenticate to Vault by presenting their ServiceAccount JWT. Vault validates the JWT against the cluster's API and issues a Vault token with the policies bound to that role. This is *the* production pattern for K8s ↔ Vault integration.

> **Architecture decision:** Each cluster gets its own auth backend in Vault at `auth/kubernetes-<cluster>/`. This means a compromised JWT signing key on homelab-dev cannot grant access as homelab-prod workloads. Same blast-radius reasoning as separating hypervisors. Some homelabs share one auth backend across clusters — that conflates trust boundaries unnecessarily.

#### 2.2a — Create a TokenReview ServiceAccount on each cluster

Vault needs to call `/apis/authentication.k8s.io/v1/tokenreviews` to validate JWTs. That requires a ServiceAccount with the `system:auth-delegator` ClusterRole. Apply on each cluster (`kubectl --context homelab-prod`, then homelab-dev, then mgmt):

```yaml
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: vault-tokenreview
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: vault-tokenreview-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:auth-delegator
subjects:
  - kind: ServiceAccount
    name: vault-tokenreview
    namespace: kube-system
---
apiVersion: v1
kind: Secret
metadata:
  name: vault-tokenreview-token
  namespace: kube-system
  annotations:
    kubernetes.io/service-account.name: vault-tokenreview
type: kubernetes.io/service-account-token
```

#### 2.2b — Capture cluster info and configure Vault backend

For each cluster, gather three things:

```bash
# Run with the appropriate kubectl context
CLUSTER=homelab-prod   # repeat for homelab-dev, mgmt

K8S_HOST="https://$(kubectl get endpoints kubernetes -o jsonpath='{.subsets[0].addresses[0].ip}'):443"
K8S_CA="$(kubectl get secret vault-tokenreview-token -n kube-system -o jsonpath='{.data.ca\.crt}' | base64 -d)"
K8S_TOKEN="$(kubectl get secret vault-tokenreview-token -n kube-system -o jsonpath='{.data.token}' | base64 -d)"

# Enable per-cluster auth backend in Vault
vault auth enable -path="kubernetes-${CLUSTER}" kubernetes

# Configure the backend with cluster details
vault write "auth/kubernetes-${CLUSTER}/config" \
  kubernetes_host="${K8S_HOST}" \
  kubernetes_ca_cert="${K8S_CA}" \
  token_reviewer_jwt="${K8S_TOKEN}" \
  issuer="https://kubernetes.default.svc.cluster.local"
```

The `issuer` value matters with RKE2 — `kubectl get --raw /.well-known/openid-configuration | jq -r .issuer` from inside the cluster confirms the right value. RKE2 defaults differ from k3s; verify per cluster.

#### 2.2c — Define Vault policies and roles per consumer

The two consumers in Tier 2 are ESO and cert-manager. Create their policies first:

```bash
# ESO — needs to read application secrets per namespace
vault policy write eso-homelab-prod - <<EOF
path "secret/data/homelab-prod/*"   { capabilities = ["read"] }
path "secret/metadata/homelab-prod/*" { capabilities = ["read", "list"] }
EOF

vault policy write eso-homelab-dev - <<EOF
path "secret/data/homelab-dev/*"   { capabilities = ["read"] }
path "secret/metadata/homelab-dev/*" { capabilities = ["read", "list"] }
EOF

vault policy write eso-mgmt - <<EOF
path "secret/data/mgmt/*"   { capabilities = ["read"] }
path "secret/metadata/mgmt/*" { capabilities = ["read", "list"] }
EOF

# cert-manager — needs to sign certs from the internal PKI
vault policy write cert-manager - <<EOF
path "pki_int/sign/internal-services"   { capabilities = ["create", "update"] }
path "pki_int/issue/internal-services"  { capabilities = ["create", "update"] }
EOF
```

Bind ServiceAccounts to policies via roles:

```bash
# ESO role on homelab-prod — only the external-secrets/external-secrets ServiceAccount can use it
vault write auth/kubernetes-homelab-prod/role/eso \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=eso-homelab-prod \
  ttl=1h

# cert-manager role on homelab-prod
vault write auth/kubernetes-homelab-prod/role/cert-manager \
  bound_service_account_names=cert-manager \
  bound_service_account_namespaces=cert-manager \
  policies=cert-manager \
  ttl=1h

# Repeat for homelab-dev and mgmt with the appropriate policy bindings
```

#### Verification

- [ ] On each cluster, kubectl `system:auth-delegator` binding exists for `vault-tokenreview`
- [ ] `vault auth list` shows `kubernetes-homelab-prod/`, `kubernetes-homelab-dev/`, `kubernetes-mgmt/`
- [ ] Manual login test using a real pod's projected token:
  ```bash
  # From inside a pod running with the eso SA (once ESO is deployed in Phase 2.3, this confirms auth works)
  TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
  curl --cacert ca.crt --data "{\"role\":\"eso\",\"jwt\":\"${TOKEN}\"}" \
    https://vault.homelab.internal:8200/v1/auth/kubernetes-homelab-prod/login
  # Returns a client_token with the eso-homelab-prod policy attached
  ```

---

### Phase 2.3: External Secrets Operator (All Clusters)

**Goal:** ESO running in every cluster, authenticating to Vault via Kubernetes auth method, ready to materialize Vault KV secrets into K8s Secrets. From here forward, *no secret is ever committed to Git in any form* — encrypted or otherwise. Everything lives in Vault.

#### 2.3a — Install ESO via Helm

Direct helm install for bootstrap (ArgoCD takes over reconciliation in Phase 2.11):

```bash
# Repeat with each cluster context
kubectl --context homelab-prod create namespace external-secrets

helm --kube-context homelab-prod repo add external-secrets https://charts.external-secrets.io
helm --kube-context homelab-prod upgrade --install external-secrets \
  external-secrets/external-secrets \
  -n external-secrets \
  --version 0.10.x \
  --set installCRDs=true \
  --set serviceAccount.name=external-secrets
```

#### 2.3b — ClusterSecretStore pointing at Vault

```yaml
# Apply to each cluster, adjusting the path: kubernetes-homelab-prod vs kubernetes-homelab-dev etc.
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: vault-backend
spec:
  provider:
    vault:
      server: "https://vault.homelab.internal:8200"
      path: "secret"
      version: "v2"
      caProvider:
        type: ConfigMap
        name: homelab-root-ca
        namespace: external-secrets
        key: ca.crt
      auth:
        kubernetes:
          mountPath: "kubernetes-homelab-prod"   # cluster-specific
          role: "eso"
          serviceAccountRef:
            name: "external-secrets"
            namespace: "external-secrets"
```

The `homelab-root-ca` ConfigMap holds the Vault root CA cert from Tier 0. Pre-populate it on each cluster:

```bash
kubectl --context homelab-prod -n external-secrets create configmap homelab-root-ca \
  --from-file=ca.crt=<(pass show homelab/vault/root-ca-cert)
```

> **Why ClusterSecretStore not SecretStore:** Cluster-scoped resource means any namespace can reference it via ExternalSecret. Avoids per-namespace duplication. Acceptable because the policies are scoped *inside Vault* by path; ESO can only read what its policy allows regardless of which namespace asks.

#### 2.3c — Smoke test ESO

```bash
# Put a test secret in Vault
vault kv put secret/homelab-prod/eso-test username=alice password=test123

# Create an ExternalSecret CR pointing at it
cat <<EOF | kubectl --context homelab-prod apply -f -
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: eso-test
  namespace: default
spec:
  refreshInterval: 30s
  secretStoreRef:
    kind: ClusterSecretStore
    name: vault-backend
  target:
    name: eso-test-secret
  data:
    - secretKey: username
      remoteRef:
        key: homelab-prod/eso-test
        property: username
    - secretKey: password
      remoteRef:
        key: homelab-prod/eso-test
        property: password
EOF

# Verify the K8s Secret materialized
kubectl --context homelab-prod -n default get secret eso-test-secret -o jsonpath='{.data.username}' | base64 -d
# Returns: alice

# Cleanup
kubectl --context homelab-prod delete externalsecret eso-test
vault kv delete secret/homelab-prod/eso-test
```

#### Verification

- [ ] ESO pods Running on all three clusters
- [ ] `kubectl get clustersecretstore` returns `vault-backend` with `Ready: True`
- [ ] Smoke test passes on each cluster
- [ ] ESO logs show no `permission denied` from Vault (would indicate policy/role mismatch)

---

### Phase 2.4: cert-manager + Two Issuers

**Goal:** cert-manager installed on every cluster. Internal services get short-lived certs from Vault PKI. Public services get Let's Encrypt certs via Cloudflare DNS-01.

#### 2.4a — Install cert-manager

```bash
# Repeat per cluster
kubectl --context homelab-prod create namespace cert-manager

helm --kube-context homelab-prod repo add jetstack https://charts.jetstack.io
helm --kube-context homelab-prod upgrade --install cert-manager \
  jetstack/cert-manager \
  -n cert-manager \
  --version v1.15.x \
  --set installCRDs=true \
  --set serviceAccount.name=cert-manager
```

#### 2.4b — Vault PKI ClusterIssuer (internal services)

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: vault-pki
spec:
  vault:
    server: "https://vault.homelab.internal:8200"
    path: "pki_int/sign/internal-services"
    caBundle: |   # the homelab root CA cert, base64-encoded
      LS0tLS1CRUdJTi...
    auth:
      kubernetes:
        mountPath: "/v1/auth/kubernetes-homelab-prod"
        role: "cert-manager"
        serviceAccountRef:
          name: cert-manager
```

The `caBundle` is the base64-encoded contents of `~/homelab-root-ca.crt` (from Tier 0). Same on every cluster.

#### 2.4c — Let's Encrypt ClusterIssuer (public services via Cloudflare DNS-01)

Cloudflare API token stored in Vault, materialized via ESO:

```bash
# Store the Cloudflare API token in Vault (token scoped to Zone:DNS:Edit on your domain only)
vault kv put secret/homelab-prod/cert-manager/cloudflare api-token="<your-cloudflare-api-token>"
```

ExternalSecret to materialize it:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: cloudflare-api-token
  namespace: cert-manager
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: vault-backend
  target:
    name: cloudflare-api-token-secret
  data:
    - secretKey: api-token
      remoteRef:
        key: homelab-prod/cert-manager/cloudflare
        property: api-token
```

The ClusterIssuer itself:

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: you@yourdomain.com
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
      - dns01:
          cloudflare:
            apiTokenSecretRef:
              name: cloudflare-api-token-secret
              key: api-token
        selector:
          dnsZones:
            - yourdomain.com
```

#### Verification

- [ ] cert-manager pods Running on all three clusters
- [ ] `kubectl get clusterissuer` shows both `vault-pki` and `letsencrypt-prod` with `Ready: True`
- [ ] Test internal cert:
  ```yaml
  apiVersion: cert-manager.io/v1
  kind: Certificate
  metadata: { name: cert-test, namespace: default }
  spec:
    secretName: cert-test-tls
    issuerRef: { kind: ClusterIssuer, name: vault-pki }
    commonName: test.homelab.internal
    duration: 24h
    renewBefore: 8h
  ```
  After ~30 seconds: `kubectl get cert cert-test` shows `Ready: True`, the secret contains a cert chain rooted at the homelab root CA, expires in 24h.
- [ ] Delete test cert + secret

---

### Phase 2.5: Vault's Listener Cert Now Managed by cert-manager

**Goal:** Replace the manually-issued 30-day Vault listener cert from Phase 0.7d with cert-manager rotation. This closes the loop — Vault uses its own PKI, automated.

The challenge: cert-manager lives in Kubernetes; Vault lives outside Kubernetes. Two reasonable approaches:

1. **Pull approach (recommended):** A small wrapper script on each Vault VM runs every 12 hours via systemd timer. It reads a Certificate from a designated K8s namespace on homelab-prod via API, copies cert + key to `/etc/vault.d/`, reloads Vault. cert-manager handles renewal; the script just copies.

2. **Push approach:** A K8s CronJob in homelab-prod issues a cert via direct Vault PKI API call (not cert-manager) and SCPs it onto each Vault VM. Bypasses cert-manager and reintroduces SSH-based automation, so the pull approach is cleaner.

Skipping the full implementation in this doc — it's a Tier 2 stretch item rather than a hard requirement. **Action:** Add a calendar reminder to manually rotate Vault's cert every 28 days until the automation is built. Or build the systemd timer + script and reference it from an ADR. Either way, the 30-day TTL means you have time.

> **Honest scope call:** I'm flagging this as a known TODO rather than building it inline because the implementation isn't novel and is exactly the kind of integration glue you'll want to write yourself. The architectural decision (pull vs push, where to run it) is documented; the code is left as exercise.

---

### Phase 2.6: Cilium Gateway API Resources

**Goal:** Each cluster has a Gateway resource that terminates TLS for inbound traffic, with HTTPRoutes mapping hostnames to backend Services. cert-manager auto-provisions certs to the Gateway's TLS listener.

#### 2.6a — GatewayClass

Cilium provides the GatewayClass automatically when Gateway API is enabled (set in Tier 1 Cilium config). Verify:

```bash
kubectl --context homelab-prod get gatewayclass
# Should show: cilium  cilium.io/gateway-controller
```

#### 2.6b — Gateway resource per cluster

Each cluster gets one shared Gateway that serves all internal HTTPS traffic. Define on homelab-prod:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: homelab-prod-gateway
  namespace: gateway-system
spec:
  gatewayClassName: cilium
  listeners:
    - name: https
      protocol: HTTPS
      port: 443
      hostname: "*.homelab-prod.homelab.internal"
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Secret
            name: homelab-prod-wildcard-tls
      allowedRoutes:
        namespaces:
          from: All
    - name: http
      protocol: HTTP
      port: 80
      hostname: "*.homelab-prod.homelab.internal"
      allowedRoutes:
        namespaces:
          from: All
```

Backing Certificate:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: homelab-prod-wildcard
  namespace: gateway-system
spec:
  secretName: homelab-prod-wildcard-tls
  issuerRef:
    kind: ClusterIssuer
    name: vault-pki
  commonName: "*.homelab-prod.homelab.internal"
  dnsNames:
    - "*.homelab-prod.homelab.internal"
  duration: 720h        # 30 days — wildcards are precious, give them more life than service certs
  renewBefore: 240h
```

> **24h for service-specific certs, 30d for wildcards:** Service-specific certs are easy to rotate (one app's cert at a time). Wildcards cover many services — a botched rotation breaks everything. Longer TTL trades faster recovery for less risk of routine churn. Document the tradeoff.

#### 2.6c — DNS for the cluster wildcard

Once the Gateway gets an LB IP from BGP, update VyOS with a wildcard:

```bash
# On bgp-01 and bgp-02 — assuming the Gateway gets 192.168.50.240
set system static-host-mapping host-name homelab-prod-gw.homelab.internal inet 192.168.50.240
```

VyOS doesn't natively serve wildcard DNS, so each consumer service needs a static A record. When you deploy `harbor.homelab-prod.homelab.internal`, add it to VyOS as `inet 192.168.50.240`. Inelegant but explicit — every hostname is documented and grep-able. If this grows beyond ~20 entries, time to deploy CoreDNS as a platform service.

Mirror Gateway resources to homelab-dev (`*.homelab-dev.homelab.internal`, LB pool `192.168.60.240-250`) and homelab-mgmt (`*.mgmt.homelab.internal`).

#### Verification

- [ ] `kubectl get gateway -A` on each cluster shows Gateway `Programmed: True`
- [ ] LB IP allocated (visible in Gateway `.status.addresses`)
- [ ] LB IP is pingable from workstation via BGP route
- [ ] TLS handshake against the Gateway returns a cert chained to the homelab root CA

---

### Phase 2.7: ExternalDNS

**Goal:** DNS records for Kubernetes Services, Gateway API HTTPRoutes, and Ingresses are created automatically. Users and tenants don't touch VyOS static host mappings. DNS for `*.homelab.local` is owned by a programmable backend, with VyOS forwarding to it.

> **Why this matters:** Without ExternalDNS, every new service is a ticket — someone updates VyOS static host mappings, commits, deploys. That doesn't scale to multi-tenant. When the friend creates a KServe InferenceService in Tier 5, the DNS record must appear without an admin in the loop. ExternalDNS watches Gateway API and Service resources and writes records to a backend it owns.

#### 2.7a — Stand up a CoreDNS-with-etcd authority

CoreDNS is in every Kubernetes cluster as the in-cluster DNS. For *homelab-wide* DNS that VyOS forwards to, a separate CoreDNS deployment with a writable backend is needed. The `etcd` plugin makes CoreDNS read records from etcd that ExternalDNS writes to.

Deploy on homelab-mgmt (3 replicas of CoreDNS, 3 replicas of etcd, both in `coredns-homelab` namespace):

```yaml
# Helm values for CoreDNS
servers:
  - zones:
      - zone: homelab.local
    port: 53
    plugins:
      - name: errors
      - name: cache
        parameters: 30
      - name: etcd
        configBlock: |
          path /skydns
          endpoint http://etcd.coredns-homelab.svc.cluster.local:2379
      - name: forward
        parameters: ". /etc/resolv.conf"
      - name: prometheus
        parameters: 0.0.0.0:9153
```

Expose via `LoadBalancer` from `homelab-mgmt-lb-pool`. Assign `192.168.40.245` and `192.168.40.246` (two LBs for HA, both listening UDP/TCP 53).

The etcd cluster here is dedicated to CoreDNS — NOT the Kubernetes etcd, NOT shared with anything else. Bitnami's etcd chart works fine; 3 replicas with PVCs on NFS.

#### 2.7b — VyOS forwarding configuration

On bgp-01 and bgp-02:

```
set service dns forwarding domain homelab.local server 192.168.40.245
set service dns forwarding domain homelab.local server 192.168.40.246
```

VyOS now forwards any query for `*.homelab.local` to the in-cluster CoreDNS, falling back to upstream resolvers for everything else. Test from a non-cluster host: `dig +short anything.homelab.local @bgp-01.homelab.local`.

#### 2.7c — Install ExternalDNS per workload cluster

One ExternalDNS deployment per workload cluster (homelab-prod, homelab-dev), each watching only its own resources. The `txtOwnerId` tag prevents two ExternalDNS instances from fighting over the same records.

```yaml
# homelab-gitops/apps/external-dns/values.yaml
provider: coredns
env:
  - name: ETCD_URLS
    value: "http://etcd.coredns-homelab.svc.cluster.local:2379"
sources:
  - service
  - gateway-httproute
  - ingress
policy: sync  # create, update, AND delete
txtOwnerId: homelab-prod  # or homelab-dev
txtPrefix: "external-dns-"
domainFilters:
  - homelab.local
interval: 30s
```

`policy: sync` is important: ExternalDNS deletes records when their owning Services/Routes are deleted. Without it, you accumulate orphaned records forever.

#### 2.7d — Tenant usage pattern

ExternalDNS reads hostnames from Gateway API `hostnames` directly:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: iris-classifier
  namespace: mlops-user-abc123
spec:
  hostnames:
    - iris-classifier.abc123.kserve.homelab.local
  parentRefs:
    - name: kserve-gateway
      namespace: kserve
```

Create the HTTPRoute → DNS record appears in CoreDNS etcd within ~30s → resolution works immediately after the CoreDNS cache TTL (also 30s).

For Service resources without a Gateway, the annotation pattern:

```yaml
metadata:
  annotations:
    external-dns.alpha.kubernetes.io/hostname: my-service.homelab.local
```

#### 2.7e — Split: keep platform DNS static, tenant DNS programmatic

Platform service records (vault, harbor, argocd, grafana, keycloak, mlflow, etc.) **stay** on VyOS as static host mappings. They're hand-curated, change rarely, and you don't want them dependent on the cluster being up to resolve "where is Vault?" Tenant records (mlops-*, kserve-*, *.user namespaces) live in CoreDNS, programmatically managed.

This split avoids the chicken-and-egg of "Cluster is down because Vault is down, Vault is down because cert-manager can't reach DNS, DNS is down because cluster is down."

#### Verification

- [ ] CoreDNS responding on 192.168.40.245:53 for `homelab.local`: `dig +short test.homelab.local @192.168.40.245` returns NXDOMAIN (no records yet, but not a timeout)
- [ ] VyOS forwarding `*.homelab.local` to CoreDNS (test from workstation: `dig +short anything.homelab.local`)
- [ ] ExternalDNS deployed on both workload clusters, healthy
- [ ] Create a test HTTPRoute with `hostnames: [test-record.homelab.local]` → record appears in CoreDNS within 60s
- [ ] Delete the HTTPRoute → record disappears within 60s
- [ ] Two clusters' ExternalDNS don't conflict: verify with TXT records (`dig TXT external-dns-test-record.homelab.local`)
- [ ] Platform services (`vault.homelab.local`, `harbor.homelab.local`) still resolve correctly through the static VyOS path

---

### Phase 2.8: CloudNativePG Operator (homelab-prod)

**Goal:** The Postgres operator installed on homelab-prod. From this point onward, every app needing Postgres gets a `Cluster` CR — no single-pod Postgres deployments anywhere in v4.

#### 2.8a — Install via Helm

```bash
kubectl --context homelab-prod create namespace cnpg-system

helm --kube-context homelab-prod repo add cnpg https://cloudnative-pg.github.io/charts
helm --kube-context homelab-prod upgrade --install cnpg \
  cnpg/cloudnative-pg \
  -n cnpg-system \
  --version 0.22.x
```

#### 2.8b — Backup destination (Garage S3)

CloudNativePG ships native S3 backup support. Store the Garage credentials for it:

```bash
vault kv put secret/homelab-prod/cnpg/backup-s3 \
  access-key="<garage-cnpg-key>" \
  secret-key="<garage-cnpg-secret>"
```

Materialize via ExternalSecret into the namespace each `Cluster` lives in (each app's database gets backups to its own prefix in the `harbor-registry` bucket — or a dedicated `postgres-backups` bucket, decide and stay consistent).

> **Defense-relevant note:** CloudNativePG supports continuous archiving (WAL shipping) on top of base backups. Configure both. RPO of seconds, RTO of minutes for any Postgres workload, demonstrated and tested. That's a real production capability.

#### Verification

- [ ] `kubectl get pods -n cnpg-system` shows operator Running
- [ ] CRDs installed: `kubectl get crd | grep cnpg` shows `Clusters`, `Backups`, `ScheduledBackups`, `Poolers`

---

### Phase 2.9: Harbor on homelab-prod

**Goal:** Harbor operational at `harbor.homelab-prod.homelab.internal`, using CloudNativePG for its database, Garage for blob storage, with Cosign signing keys stored in Vault Transit (not on disk).

#### 2.9a — Postgres cluster for Harbor

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: harbor-postgres
  namespace: harbor
spec:
  instances: 2                  # primary + standby
  storage:
    size: 20Gi
    storageClass: nfs-csi      # whatever you named the NFS storage class in Tier 1
  backup:
    barmanObjectStore:
      destinationPath: s3://harbor-registry/postgres-backups
      endpointURL: http://garage-01.homelab.internal:3900
      s3Credentials:
        accessKeyId:
          name: garage-cnpg-creds
          key: access-key
        secretAccessKey:
          name: garage-cnpg-creds
          key: secret-key
    retentionPolicy: "14d"
```

#### 2.9b — Harbor values (Helm)

```yaml
# harbor-values.yaml — committed to homelab-gitops
expose:
  type: ingress
  tls:
    enabled: true
    certSource: secret
    secret:
      secretName: homelab-prod-wildcard-tls   # the Gateway wildcard from Phase 2.6
  ingress:
    hosts:
      core: harbor.homelab-prod.homelab.internal
    className: cilium

externalURL: https://harbor.homelab-prod.homelab.internal

# External Postgres via CloudNativePG
database:
  type: external
  external:
    host: harbor-postgres-rw.harbor.svc
    port: "5432"
    coreDatabase: registry
    username: harbor
    existingSecret: harbor-postgres-app   # CNPG auto-creates this secret

# External storage via Garage S3
persistence:
  imageChartStorage:
    type: s3
    s3:
      region: garage
      bucket: harbor-registry
      regionendpoint: http://garage-01.homelab.internal:3900
      existingSecret: garage-harbor-creds
      v4auth: true

# Trivy integrated for image scanning
trivy:
  enabled: true

# Disable bundled chartmuseum (legacy, deprecated)
chartmuseum:
  enabled: false

# Disable bundled redis — for v4 it's fine to leave it on
redis:
  type: internal
```

#### 2.9c — Cosign signing keys in Vault Transit

Already set up `transit/keys/cosign-harbor` in Tier 0 Phase 0.8. Harbor doesn't natively support Vault Transit for signing yet, so the integration pattern is:

1. CI pipelines (in Tier 4) call `cosign sign --key hashivault://transit/keys/cosign-harbor` to sign images using the in-Vault key
2. The public key is published to a well-known location for verification
3. Kyverno verifies signatures using the published public key (Phase 2.13)

Export the public key for verification:

```bash
vault read -field=public_key transit/keys/cosign-harbor/public_key/1 > ~/cosign-harbor.pub
# Store in a ConfigMap on each cluster that Kyverno can reference
kubectl --context homelab-prod -n kyverno create configmap cosign-public-keys \
  --from-file=harbor.pub=~/cosign-harbor.pub
# Mirror to homelab-dev
kubectl --context homelab-dev -n kyverno create configmap cosign-public-keys \
  --from-file=harbor.pub=~/cosign-harbor.pub
```

> **Why the key never touches disk on signers:** Anyone signing images authenticates to Vault (via AppRole in CI), invokes the signing operation server-side, gets back a signature. The private key never leaves Vault. If a CI runner is compromised, the attacker can sign while they have the AppRole token (mitigated by short TTLs), but cannot exfiltrate the key for offline use. The defense equivalent uses an HSM-backed Transit key — same pattern, hardware-rooted trust.

#### Verification

- [ ] Harbor UI loads at `https://harbor.homelab-prod.homelab.internal`
- [ ] Login with admin credentials (auto-generated by Helm, stored in `harbor` namespace; will OIDC-integrate to Keycloak in Tier 3)
- [ ] Create a project, push a test image: `docker push harbor.homelab-prod.homelab.internal/test/hello:v1`
- [ ] Pull from a fresh node: `docker pull harbor.homelab-prod.homelab.internal/test/hello:v1`
- [ ] Sign with Cosign using the Vault Transit key:
  ```bash
  export VAULT_ADDR=https://vault.homelab.internal:8200
  export VAULT_TOKEN=...
  cosign sign --key hashivault://transit/keys/cosign-harbor \
    harbor.homelab-prod.homelab.internal/test/hello:v1
  ```
- [ ] Verify signature: `cosign verify --key ~/cosign-harbor.pub harbor.homelab-prod.homelab.internal/test/hello:v1`
- [ ] CloudNativePG backup runs successfully and a base backup appears in Garage

---

### Phase 2.10: Air-Gap Pivot for Workload Clusters

**Goal:** homelab-prod and homelab-dev stop pulling images from Docker Hub, Quay, gcr.io, etc. All workload image pulls go through Harbor as a pull-through proxy or replicated registry. Mgmt-plane retains upstream access for observability bootstrap.

#### 2.10a — Configure Harbor proxy projects

In Harbor UI, create proxy-cache projects for each upstream you regularly pull from:

- `dockerhub` → proxy for `docker.io`
- `quay` → proxy for `quay.io`
- `ghcr` → proxy for `ghcr.io`
- `gcr` → proxy for `gcr.io`
- `registryk8s` → proxy for `registry.k8s.io`

Now `harbor.homelab-prod.homelab.internal/dockerhub/library/nginx:latest` transparently fetches and caches `docker.io/library/nginx:latest`.

#### 2.10b — RKE2 containerd registry mirror config

On each homelab-prod and homelab-dev node, write `/etc/rancher/rke2/registries.yaml`:

```yaml
mirrors:
  docker.io:
    endpoint:
      - "https://harbor.homelab-prod.homelab.internal/v2/dockerhub"
  quay.io:
    endpoint:
      - "https://harbor.homelab-prod.homelab.internal/v2/quay"
  ghcr.io:
    endpoint:
      - "https://harbor.homelab-prod.homelab.internal/v2/ghcr"
  gcr.io:
    endpoint:
      - "https://harbor.homelab-prod.homelab.internal/v2/gcr"
  registry.k8s.io:
    endpoint:
      - "https://harbor.homelab-prod.homelab.internal/v2/registryk8s"

configs:
  "harbor.homelab-prod.homelab.internal":
    tls:
      ca_file: /etc/ssl/certs/homelab-root-ca.crt
    # No credentials needed for public read on proxy projects
    # Auth required only for pushing — that's a CI concern, not a node concern
```

Restart rke2-server / rke2-agent on each node to pick up the new config. Use the Ansible role to apply the file and restart in rolling order (one node at a time, wait for it to come back Ready).

> **Critical subtlety — egress firewall enforcement:** The registries.yaml config makes nodes *prefer* Harbor, but doesn't *prevent* direct upstream pulls if something hardcodes a registry URL bypassing containerd. To truly enforce air-gap, add egress firewall rules at VyOS:
>
> ```bash
> # On bgp-01 and bgp-02, deny VLAN 50 and VLAN 60 from initiating outbound to known registries
> # (homelab-mgmt VLAN 40 keeps full egress for now)
> set firewall name VLAN50-EGRESS rule 100 action drop
> set firewall name VLAN50-EGRESS rule 100 description "Drop docker.io egress (force Harbor)"
> set firewall name VLAN50-EGRESS rule 100 destination address 0.0.0.0/0  # broad, refine with FQDN-resolved IPs
> ```
>
> In practice, FQDN-based blocking in VyOS is fiddly. The defense-grade way is an egress proxy (Squid) on VyOS allow-listing only Harbor. **For Tier 2, document the gap. Implement explicit FQDN-resolved blocks for `docker.io`, `quay.io`, `ghcr.io`, `gcr.io`, `registry.k8s.io` in a Tier 2 follow-up.** The pull-through configuration is the first step; the firewall enforcement is the verification.

#### Verification

- [ ] On a homelab-prod node: `crictl pull docker.io/library/nginx:1.27` succeeds; check Harbor UI — the `dockerhub/library/nginx` image now exists in Harbor
- [ ] On the same node: try to `curl https://registry-1.docker.io` directly — should fail once firewall enforcement is added (Tier 2 follow-up)
- [ ] Mgmt-plane nodes are NOT configured with `registries.yaml` mirrors — they pull directly upstream

---

### Phase 2.11: ArgoCD on homelab-prod

**Goal:** ArgoCD installed on homelab-prod, registered with both homelab-prod and homelab-dev as managed clusters, GitHub repo connected, ready to deploy workloads via ApplicationSets in Tier 4.

#### 2.11a — Install ArgoCD

```bash
kubectl --context homelab-prod create namespace argocd

# Pin a specific version for reproducibility
helm --kube-context homelab-prod repo add argo https://argoproj.github.io/argo-helm
helm --kube-context homelab-prod upgrade --install argocd argo/argo-cd \
  -n argocd \
  --version 7.x \
  -f argocd-values.yaml
```

`argocd-values.yaml` essentials:

```yaml
global:
  domain: argocd.homelab-prod.homelab.internal

server:
  ingress:
    enabled: true
    ingressClassName: cilium
    hostname: argocd.homelab-prod.homelab.internal
    tls: true

configs:
  cm:
    application.instanceLabelKey: argocd.argoproj.io/instance
    # OIDC integration deferred to Tier 3 when Keycloak exists
  rbac:
    policy.default: role:readonly
    policy.csv: |
      g, dalton, role:admin
```

#### 2.11b — Register homelab-dev as a managed cluster

ArgoCD on homelab-prod needs to be able to deploy to homelab-dev. Add homelab-dev's kubeconfig:

```bash
# From workstation with both kubeconfigs available
argocd cluster add homelab-dev --kubeconfig ~/.kube/config
# Auto-creates a service account on homelab-dev with cluster-admin
# Stores the secret in argocd namespace on homelab-prod
```

#### 2.11c — Connect GitHub repo

```bash
# Deploy key for argo to read the gitops repo
vault kv put secret/homelab-prod/argocd/github-deploy-key \
  private-key="$(cat ~/.ssh/homelab-deploy-key)"

# Materialize via ESO into argocd namespace
# Then register the repo in ArgoCD
argocd repo add git@github.com:yourorg/homelab-gitops.git \
  --ssh-private-key-path ~/.ssh/homelab-deploy-key
```

#### 2.11d — App-of-Apps bootstrap

A single `root` Application that points at `homelab-gitops/clusters/homelab-prod/apps/` (and another for homelab-dev). This directory contains ApplicationSets that generate Applications for each workload. We pre-seed the structure in Tier 2 but populate apps in Tier 4.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root-homelab-prod
  namespace: argocd
spec:
  project: default
  source:
    repoURL: git@github.com:yourorg/homelab-gitops.git
    targetRevision: main
    path: clusters/homelab-prod/apps
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

#### Verification

- [ ] ArgoCD UI loads at `https://argocd.homelab-prod.homelab.internal`
- [ ] `argocd cluster list` shows both `in-cluster` (homelab-prod) and `homelab-dev`
- [ ] `argocd repo list` shows the homelab-gitops repo with `Connection Status: Successful`
- [ ] Root applications sync (initially empty — apps come in Tier 4)

---

### Phase 2.12: Flux on Mgmt-Plane

**Goal:** Flux installed on homelab-mgmt, GitHub repo connected, ready to manage observability stack and identity stack in Tier 3.

```bash
# Flux CLI bootstrap (one-time)
flux --context mgmt bootstrap github \
  --owner=yourorg \
  --repository=homelab-gitops \
  --branch=main \
  --path=clusters/homelab-mgmt \
  --personal=false \
  --components-extra=image-reflector-controller,image-automation-controller
```

> **Why a different tool for homelab-mgmt:** Genuine value: you build muscle memory for both tools. ArgoCD's UI-first model fits workload deployments where you want visibility. Flux's CLI-first model fits platform tooling where you want declarative-only. Documenting *which* paradigm fits *which* tier is part of v4's value as a learning vehicle.

#### Verification

- [ ] `flux --context mgmt get sources git` shows the gitops repo `Ready`
- [ ] `flux --context mgmt get kustomizations` shows the bootstrap kustomizations `Ready`
- [ ] A commit to `homelab-gitops/clusters/homelab-mgmt/` triggers a reconcile within 1 minute

---

### Phase 2.13: Kyverno in Audit Mode

**Goal:** Kyverno installed on all clusters with a seed set of baseline policies. All policies run in `audit` mode for Tier 2 — they log violations but don't block. Switch to `enforce` happens in Tier 4 once workloads are stable.

#### 2.13a — Install

```bash
# Repeat per cluster
kubectl --context homelab-prod create namespace kyverno
helm --kube-context homelab-prod repo add kyverno https://kyverno.github.io/kyverno/
helm --kube-context homelab-prod upgrade --install kyverno kyverno/kyverno \
  -n kyverno \
  --version 3.2.x \
  --set replicaCount=3   # HA on homelab-prod + mgmt; homelab-dev can run 1
```

#### 2.13b — Seed policies (committed to gitops repo)

A starter set, all in audit mode:

1. **`require-image-signature`** — verify images pulled from `harbor.homelab-prod.homelab.internal` are signed by the Cosign key. References the `cosign-public-keys` ConfigMap from Phase 2.9c.
2. **`disallow-default-namespace`** — workloads must explicitly choose a namespace
3. **`require-resource-requests`** — every container declares CPU/memory requests
4. **`require-non-root`** — containers run as non-root by default
5. **`disallow-privileged-containers`** — no privileged: true except in explicit exception namespaces (kube-system, cilium, etc.)
6. **`require-pod-security-standards-restricted`** — pods comply with PSS restricted profile

Example signature verification policy:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-image-signature
spec:
  validationFailureAction: Audit   # Switch to Enforce in Tier 4
  webhookTimeoutSeconds: 30
  background: false
  rules:
    - name: verify-harbor-signatures
      match:
        any:
          - resources:
              kinds:
                - Pod
      verifyImages:
        - imageReferences:
            - "harbor.homelab-prod.homelab.internal/*"
          attestors:
            - count: 1
              entries:
                - keys:
                    publicKeys: |-
                      -----BEGIN PUBLIC KEY-----
                      ... (contents of ~/cosign-harbor.pub)
                      -----END PUBLIC KEY-----
```

#### Verification

- [ ] `kubectl get clusterpolicies` shows all seed policies `Ready: True`
- [ ] Deploy a non-compliant pod (e.g., privileged: true) — kubectl creates it successfully but Kyverno logs an audit violation
- [ ] Push an unsigned image to Harbor and deploy it — Kyverno audit log shows signature verification failure (but pod runs in audit mode)
- [ ] PolicyReport CRs populated: `kubectl get policyreport -A`

---

### Phase 2.14: Renovate Bot via GitHub App

**Goal:** Renovate automatically opens PRs against the gitops repo when new versions of charts, images, or terraform modules are available. Runs as a CronJob in homelab-prod. Authenticates via a GitHub App (not a personal PAT).

#### 2.14a — Create the GitHub App

In GitHub, create a new App with permissions:
- Repository contents: Read & write
- Pull requests: Read & write
- Workflows: Read & write
- Metadata: Read

Install on your `homelab-gitops` repo. Download the private key.

#### 2.14b — Store credentials in Vault

```bash
vault kv put secret/homelab-prod/renovate/github-app \
  app-id="<your-app-id>" \
  installation-id="<your-installation-id>" \
  private-key="$(cat ~/Downloads/renovate-bot.private-key.pem)"
```

#### 2.14c — Renovate config (`renovate.json` in gitops repo)

```json
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": [
    "config:recommended",
    ":semanticCommits",
    "schedule:weekly"
  ],
  "kubernetes": {
    "fileMatch": ["clusters/.+\\.ya?ml$"]
  },
  "helm-values": {
    "fileMatch": ["clusters/.+/values\\.ya?ml$"]
  },
  "argocd": {
    "fileMatch": ["clusters/.+\\.ya?ml$"]
  },
  "vulnerabilityAlerts": {
    "enabled": true
  },
  "packageRules": [
    {
      "matchUpdateTypes": ["minor", "patch"],
      "automerge": false,
      "labels": ["renovate", "non-major"]
    },
    {
      "matchUpdateTypes": ["major"],
      "automerge": false,
      "labels": ["renovate", "major", "review-carefully"]
    }
  ]
}
```

#### 2.14d — CronJob deployment

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: renovate
  namespace: renovate
spec:
  schedule: "0 6 * * *"   # 6am daily
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: renovate
          containers:
            - name: renovate
              image: harbor.homelab-prod.homelab.internal/dockerhub/renovate/renovate:latest
              env:
                - name: RENOVATE_PLATFORM
                  value: github
                - name: RENOVATE_REPOSITORIES
                  value: yourorg/homelab-gitops
                - name: RENOVATE_GITHUB_APP_ID
                  valueFrom: { secretKeyRef: { name: renovate-github-app, key: app-id } }
                - name: RENOVATE_GITHUB_APP_KEY
                  valueFrom: { secretKeyRef: { name: renovate-github-app, key: private-key } }
          restartPolicy: OnFailure
```

The `renovate-github-app` secret is materialized via ESO from Vault.

#### Verification

- [ ] CronJob exists and the first scheduled run completes successfully
- [ ] Renovate opens its first PR against `homelab-gitops` (typically the "Dependency Dashboard" issue + initial onboarding PR)
- [ ] No PAT or long-lived credential anywhere outside of Vault

---

### Phase 2.15: Supply Chain Attestation — SBOMs via Syft + Cosign

**Goal:** Every image pushed to Harbor carries an SBOM (Software Bill of Materials) as a signed OCI attestation. Kyverno verifies SBOM presence at admission alongside image signatures.

> **Why this matters:** Image signing answers "is this image authentic?" SBOM attestation answers "what's actually inside this image?" For supply-chain audit — and any defense customer — both are needed. Building it in now is one CI step plus one policy line; bolting it on later means amending dozens of charts and pipelines.

#### 2.15a — Add Syft to image builds

The CI pipeline (Tier 4.6 ARC + 4.7) is where images get built. The pattern extends naturally:

```yaml
# .gitea/workflows/build-image.yaml (or .github/workflows/...)
- name: Build image
  uses: docker/build-push-action@v5
  with:
    push: true
    tags: harbor.homelab.local/myapp:${{ github.sha }}

- name: Generate SBOM with Syft
  uses: anchore/syft-action@v1
  with:
    image: harbor.homelab.local/myapp:${{ github.sha }}
    format: spdx-json
    output-file: sbom.spdx.json

- name: Sign image with Cosign + Vault Transit
  run: |
    cosign sign --key 'hashivault://cosign-signer' \
      harbor.homelab.local/myapp:${{ github.sha }}

- name: Attach + sign SBOM attestation
  run: |
    cosign attest \
      --predicate sbom.spdx.json \
      --type spdxjson \
      --key 'hashivault://cosign-signer' \
      harbor.homelab.local/myapp:${{ github.sha }}
```

The Cosign signing key lives in Vault Transit (already established in Tier 0.8). It never touches disk.

#### 2.15b — Kyverno policy: verify image AND SBOM at admission

Extend the existing image signature verification policy to also require an SBOM attestation:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-image-and-sbom
spec:
  validationFailureAction: Audit   # Audit during rollout, Enforce after 2 weeks
  webhookTimeoutSeconds: 30
  rules:
    - name: verify-cosign-signature
      match:
        any:
          - resources:
              kinds: [Pod]
      verifyImages:
        - imageReferences:
            - "harbor.homelab.local/*"
          attestors:
            - count: 1
              entries:
                - keys:
                    publicKeys: |-
                      <PEM from Vault Transit public key>
    - name: verify-sbom-attestation
      match:
        any:
          - resources:
              kinds: [Pod]
      verifyImages:
        - imageReferences:
            - "harbor.homelab.local/*"
          attestations:
            - type: spdxjson
              attestors:
                - count: 1
                  entries:
                    - keys:
                        publicKeys: |-
                          <same PEM>
              conditions:
                - all:
                    - key: "{{ creationInfo.created }}"
                      operator: GreaterThanOrEquals
                      value: "2026-01-01T00:00:00Z"
```

The `conditions` block on the SBOM attestation lets you reject ancient SBOMs even if signed correctly.

#### 2.15c — Harbor SBOM integration

Harbor (v2.10+) can ingest and surface SBOMs. Configure Harbor to recognize OCI referrer artifacts:

- Harbor UI → Administration → Interrogation Services
- Enable Trivy scanner (already on by default in 2.10+)
- Enable SBOM generation in repository settings
- Per-repository "SBOM generation" toggle for legacy repos that don't push their own

Harbor will display the SBOM contents per image in the UI and let you query "which images contain log4j 2.x?"

#### 2.15d — Rollout pattern

Two-week soft launch:

1. **Day 0:** Deploy the policy in `Audit` mode. Existing pods continue to work; logs show which images lack SBOM attestations.
2. **Days 1–14:** Rebuild every image you control through the new pipeline. Watch the Audit warnings drop.
3. **Day 14:** Flip to `Enforce`. New pods without signed SBOMs are rejected.

A few categories of images won't have SBOMs (third-party Helm chart sidecars, upstream operator images). For those, add a Kyverno exemption list keyed on image prefix — but document each exemption with an ADR.

#### Verification

- [ ] One image rebuilt through the new pipeline; `cosign tree harbor.homelab.local/myapp:<sha>` shows both `signature` and `attestation` references
- [ ] `cosign verify-attestation --key hashivault://cosign-signer --type spdxjson harbor.homelab.local/myapp:<sha>` succeeds
- [ ] Kyverno policy in Audit mode logs SBOM-missing for older images
- [ ] After cutover to Enforce: a pod referencing a deliberately-unsigned image is rejected at admission with the SBOM-related message
- [ ] Harbor UI displays SBOM data for the test image
- [ ] Exemption list documented as an ADR in `homelab-gitops/docs/adr/`

---

### Phase 2.16: Tier 2 Verification Gate

**Tier 2 is complete when every item below passes.**

#### Network & DNS

- [ ] BGP sessions Established between every cluster node and both VyOS routers
- [ ] LB IP allocation works via `io.cilium/lb-pool` label
- [ ] Wildcard internal DNS works: `dig +short <anything>.homelab-prod.homelab.internal` returns expected IPs
- [ ] BGP failover test: stop bgp-01, all LB IPs remain reachable within 10s
- [ ] CoreDNS authoritative for `homelab.local`, reachable on `192.168.40.245`
- [ ] VyOS forwards `*.homelab.local` queries to CoreDNS (test from non-cluster host)
- [ ] ExternalDNS creates DNS records for new HTTPRoutes within 60s
- [ ] ExternalDNS deletes records when HTTPRoute is deleted (`policy: sync` working)

#### Vault integration

- [ ] Three per-cluster Kubernetes auth backends in Vault
- [ ] ESO running on all clusters, ClusterSecretStore `Ready` everywhere
- [ ] Smoke test: ExternalSecret materializes a KV value from Vault into a K8s Secret on each cluster

#### Certificates

- [ ] cert-manager running on all clusters
- [ ] Both ClusterIssuers (`vault-pki`, `letsencrypt-prod`) `Ready`
- [ ] Internal cert smoke test passes — 24h TTL cert issued, renewed before expiry
- [ ] Vault's own listener cert rotation documented (manual until automated; calendar reminder set)

#### Gateway API

- [ ] Cilium GatewayClass available
- [ ] Per-cluster Gateway resources Programmed and serving traffic on wildcard TLS

#### Platform services

- [ ] CloudNativePG operator running on homelab-prod
- [ ] Harbor at `https://harbor.homelab-prod.homelab.internal` — login works, push/pull works, Trivy scanning active, CNPG backups landing in Garage
- [ ] Cosign signing works via Vault Transit key, signatures verifiable with the published public key
- [ ] Syft generates SBOM in CI; `cosign tree <image>` shows both signature and SBOM attestation
- [ ] Kyverno policy in Audit mode logs SBOM-missing for legacy images; rebuilt images pass
- [ ] Harbor UI displays SBOM data per image

#### Air-gap pivot

- [ ] homelab-prod and homelab-dev nodes have `/etc/rancher/rke2/registries.yaml` configured
- [ ] Pulling `docker.io/...` from any workload node transparently routes through Harbor and caches
- [ ] Mgmt-plane nodes still pull upstream directly (no registries.yaml)
- [ ] (Tier 2 follow-up task documented: VyOS egress firewall to enforce, not just prefer)

#### GitOps

- [ ] ArgoCD on homelab-prod managing both homelab-prod and homelab-dev as targets, repo connected
- [ ] Flux on homelab-mgmt reconciling from gitops repo
- [ ] App-of-apps structure exists in the repo (empty apps acceptable; Tier 4 fills in)

#### Policy & dependencies

- [ ] Kyverno on all clusters with 6 seed policies in audit mode
- [ ] PolicyReports populated for at least one synthetic violation per policy (sanity-check that each rule fires)
- [ ] Renovate CronJob running, first PR opened

#### Hygiene

- [ ] No credentials in any Git-committed file (grep verified across both gitops and ansible repos)
- [ ] All workstation-side credentials live in `pass` only
- [ ] Vault audit log shows authentication events from ESO, cert-manager, Cosign signing, and Renovate (when it runs)

When every item passes: **Tier 2 is complete.** The platform is real. From here, Tier 3 layers observability and identity, then Tier 4 brings actual workloads to life on top of everything built so far.
# Tier 3 — Observability & Identity

**Purpose:** Three operational clusters become *legible*. Metrics, logs, traces, and runtime security events flow from workload clusters into homelab-mgmt and are queryable through a single Grafana. SLOs are defined for the platform itself before any workload depends on them. Keycloak is the single source of identity, with every UI on the platform OIDC-federated and break-glass procedures documented.

**Why observability before workloads:** Tier 4 will deploy apps that exercise canary releases, chaos engineering, and load testing. None of that is meaningful without observability already in place to measure outcomes. Building the measurement substrate first means every workload deployed in Tier 4 gets metrics, logs, traces, and SLOs from the moment it lands.

**Why identity before workloads:** Same reason. Every app deployed in Tier 4 will OIDC-integrate to Keycloak at deploy time, not as a follow-up. Retrofitting OIDC after-the-fact is the v3 pattern — v4 makes identity foundational.

## Tier 3 Phases

- **3.1** — kube-prometheus-stack on homelab-mgmt
- **3.2** — Loki on homelab-mgmt (Garage S3 backed)
- **3.3** — Tempo on homelab-mgmt (Garage S3 backed)
- **3.4** — Grafana Alloy on all Kubernetes clusters
- **3.5** — Grafana Alloy on substrate VMs (Vault, BGP, NFS, Garage, hypervisors)
- **3.6** — Cross-cluster metric scraping + log shipping wired up
- **3.7** — Falco on workload clusters with Loki output
- **3.8** — Tetragon event export to Loki
- **3.9** — Alertmanager routing configured
- **3.10** — Sloth for SLO-driven alerts (platform SLOs defined)
- **3.11** — CloudNativePG operator on homelab-mgmt (for Keycloak)
- **3.12** — Kubernetes audit log immutable retention
- **3.13** — Keycloak deployment + break-glass runbook
- **3.14** — OIDC integrations: ArgoCD, Grafana, Harbor, Vault UI
- **3.15** — OpenCost — cost attribution and visibility
- **3.16** — Tier 3 verification gate

---

### Phase 3.1: kube-prometheus-stack on Mgmt-Plane

**Goal:** Single Prometheus instance on homelab-mgmt is the central metrics store. Per-cluster collection happens via Alloy in Phase 3.4 with `remote_write` here. Grafana, Alertmanager, kube-state-metrics, and node-exporter come bundled.

> **Architecture decision — central Prometheus vs federation:** Two patterns exist for multi-cluster metrics. Per-cluster Prometheus instances with Prometheus federation pulling rolled-up metrics to a central is the "classic" pattern. Modern shops have shifted to remote_write from a collection agent (Alloy/Grafana Agent) directly to a central Prometheus, eliminating per-cluster Prometheus servers entirely. v4 uses the modern pattern: no Prometheus on homelab-prod or homelab-dev, only Alloy. Central Prometheus on homelab-mgmt stores everything. Simpler, fewer moving parts, no federation lag.

#### 3.1a — Manifest via Flux

Add to `homelab-gitops/clusters/homelab-mgmt/observability/kube-prometheus-stack/`:

```yaml
# helmrelease.yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: kube-prometheus-stack
  namespace: observability
spec:
  interval: 30m
  chart:
    spec:
      chart: kube-prometheus-stack
      version: "65.x"
      sourceRef:
        kind: HelmRepository
        name: prometheus-community
        namespace: flux-system
  values:
    fullnameOverride: kps

    # Disable bundled node-exporter (Alloy handles node metrics in Phase 3.4)
    # Keep kube-state-metrics — it's a cluster-state source, not a collector
    nodeExporter:
      enabled: false

    prometheus:
      prometheusSpec:
        # Long-ish retention since we're not using Mimir
        retention: 30d
        retentionSize: "80GB"

        # Storage — NFS-backed for now, will reconsider if Prometheus
        # WAL latency on NFS becomes painful (it usually doesn't at this scale)
        storageSpec:
          volumeClaimTemplate:
            spec:
              storageClassName: nfs-csi
              accessModes: ["ReadWriteOnce"]
              resources:
                requests:
                  storage: 100Gi

        # Allow remote_write from external Alloy instances
        enableRemoteWriteReceiver: true

        # Select all PodMonitors / ServiceMonitors / PrometheusRules cluster-wide
        # rather than restricting to release labels (gives us flexibility for Tier 4)
        podMonitorSelectorNilUsesHelmValues: false
        serviceMonitorSelectorNilUsesHelmValues: false
        ruleSelectorNilUsesHelmValues: false
        probeSelectorNilUsesHelmValues: false

        resources:
          requests:
            cpu: 500m
            memory: 4Gi
          limits:
            memory: 6Gi

    alertmanager:
      alertmanagerSpec:
        storage:
          volumeClaimTemplate:
            spec:
              storageClassName: nfs-csi
              accessModes: ["ReadWriteOnce"]
              resources:
                requests:
                  storage: 5Gi

    grafana:
      # We'll OIDC-integrate Grafana in Phase 3.14; keep admin password as break-glass
      admin:
        existingSecret: grafana-admin-credentials   # materialized by ESO from Vault
      ingress:
        enabled: true
        ingressClassName: cilium
        hosts:
          - grafana.mgmt.homelab.internal
        tls:
          - secretName: mgmt-wildcard-tls
            hosts: [grafana.mgmt.homelab.internal]
      persistence:
        enabled: true
        type: pvc
        storageClassName: nfs-csi
        size: 10Gi
      # Pre-configure data sources — Prometheus is local, Loki and Tempo wired in their phases
      additionalDataSources:
        - name: Loki
          type: loki
          url: http://loki-gateway.observability.svc:3100
          access: proxy
        - name: Tempo
          type: tempo
          url: http://tempo-query-frontend.observability.svc:3100
          access: proxy
          jsonData:
            tracesToLogs:
              datasourceUid: loki
              tags: ['cluster', 'namespace', 'pod']
```

#### 3.1b — Vault-stored Grafana admin

```bash
vault kv put secret/mgmt/grafana/admin \
  user=admin \
  password="$(openssl rand -base64 24)"
```

ExternalSecret manifest in the gitops repo materializes this as `grafana-admin-credentials`.

#### Verification

- [ ] Prometheus pod Running on homelab-mgmt
- [ ] Grafana UI reachable at `https://grafana.mgmt.homelab.internal`
- [ ] Login with vault-stored admin works
- [ ] Loki and Tempo data sources show "not yet wired" errors (expected — those come in 3.2 and 3.3)

---

### Phase 3.2: Loki on Mgmt-Plane

**Goal:** Loki deployed in `SimpleScalable` mode, chunks stored in Garage S3, index stored on NFS, ready to receive logs from Alloy on every cluster.

#### 3.2a — Garage bucket and credentials

Already pre-created in Tier 1 (`loki-chunks-mgmt`). Materialize Garage credentials via ESO into the observability namespace.

```bash
vault kv put secret/mgmt/loki/s3 \
  access-key="<garage-loki-key>" \
  secret-key="<garage-loki-secret>"
```

#### 3.2b — Loki HelmRelease (via Flux)

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: loki
  namespace: observability
spec:
  interval: 30m
  chart:
    spec:
      chart: loki
      version: "6.x"
      sourceRef:
        kind: HelmRepository
        name: grafana
        namespace: flux-system
  values:
    deploymentMode: SimpleScalable
    loki:
      auth_enabled: false   # single-tenant — we use cluster labels instead
      schemaConfig:
        configs:
          - from: "2024-01-01"
            store: tsdb
            object_store: s3
            schema: v13
            index:
              prefix: loki_index_
              period: 24h
      storage:
        type: s3
        bucketNames:
          chunks: loki-chunks-mgmt
          ruler: loki-chunks-mgmt
        s3:
          endpoint: http://garage-01.homelab.internal:3900
          secretAccessKey: ${LOKI_S3_SECRET}
          accessKeyId: ${LOKI_S3_KEY}
          s3ForcePathStyle: true
          insecure: true
      limits_config:
        retention_period: 90d    # 90 days of logs — adjust to your liking
        ingestion_rate_mb: 10
        ingestion_burst_size_mb: 20

    backend:
      replicas: 2
      persistence:
        storageClass: nfs-csi
        size: 20Gi
    read:
      replicas: 2
    write:
      replicas: 3              # write path is the most load-sensitive
      persistence:
        storageClass: nfs-csi
        size: 20Gi
    gateway:
      enabled: true            # nginx fronting Loki — what Grafana queries
```

#### Verification

- [ ] All Loki pods Running on homelab-mgmt
- [ ] In Grafana, the Loki data source test passes
- [ ] Send a manual test log via `curl` to Loki's push endpoint — verify it shows up in Grafana's Explore view

---

### Phase 3.3: Tempo on Mgmt-Plane

**Goal:** Tempo deployed in `monolithic` mode (sufficient for homelab scale; single binary, multiple replicas), traces stored in Garage S3, OTLP endpoints exposed for apps to push to directly.

```bash
# Vault-side
vault kv put secret/mgmt/tempo/s3 \
  access-key="<garage-tempo-key>" \
  secret-key="<garage-tempo-secret>"
```

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: tempo
  namespace: observability
spec:
  interval: 30m
  chart:
    spec:
      chart: tempo
      version: "1.x"
      sourceRef:
        kind: HelmRepository
        name: grafana
        namespace: flux-system
  values:
    tempo:
      storage:
        trace:
          backend: s3
          s3:
            bucket: tempo-traces-mgmt
            endpoint: garage-01.homelab.internal:3900
            insecure: true
            access_key: ${TEMPO_S3_KEY}
            secret_key: ${TEMPO_S3_SECRET}
      receivers:
        otlp:
          protocols:
            grpc:
              endpoint: 0.0.0.0:4317
            http:
              endpoint: 0.0.0.0:4318
      retention: 720h    # 30 days of traces
    persistence:
      enabled: true
      storageClassName: nfs-csi
      size: 10Gi
```

A `Gateway` HTTPRoute exposes OTLP/HTTP at `tempo-otlp.mgmt.homelab.internal:4318` so workload clusters can push without service-mesh trickery.

> **Why monolithic Tempo for homelab:** Microservices mode (separate distributor, ingester, querier, compactor) is the production scale-out option. Homelab scale doesn't need it. Monolithic is one container that does everything, scales horizontally via replicas, simple to reason about. ADR-worthy "knew the upgrade path, deliberately chose simpler."

#### Verification

- [ ] Tempo pods Running
- [ ] Grafana data source test passes
- [ ] Manual trace push via `curl` to `:4318/v1/traces` succeeds, trace queryable in Grafana Explore

---

### Phase 3.4: Grafana Alloy on All Clusters

**Goal:** Alloy installed on homelab-prod, homelab-dev, and homelab-mgmt as a DaemonSet. Single agent that scrapes Prometheus metrics, tails container logs, and forwards everything to homelab-mgmt's central stack.

> **Why Alloy not Promtail + Prometheus + OTel Collector separately:** Grafana Labs consolidated all three (and more) into Alloy in 2024. Same binary, single config, less operational surface. The legacy stack still works; Alloy is the future direction. Going with Alloy aligns the doc with where the ecosystem is heading rather than where it's been.

#### 3.4a — Alloy as DaemonSet on each cluster

Manifest deployed via ArgoCD on homelab-prod and homelab-dev, via Flux on homelab-mgmt:

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2     # or ArgoCD Application for workload clusters
kind: HelmRelease
metadata:
  name: alloy
  namespace: observability
spec:
  interval: 30m
  chart:
    spec:
      chart: alloy
      version: "0.x"
      sourceRef:
        kind: HelmRepository
        name: grafana
  values:
    alloy:
      configMap:
        content: |-
          // ============================================================
          // Discovery
          // ============================================================
          discovery.kubernetes "pods" {
            role = "pod"
          }

          discovery.kubernetes "nodes" {
            role = "node"
          }

          // ============================================================
          // Logs
          // ============================================================
          loki.source.kubernetes "pods" {
            targets    = discovery.kubernetes.pods.targets
            forward_to = [loki.process.add_cluster_label.receiver]
          }

          loki.process "add_cluster_label" {
            forward_to = [loki.write.central.receiver]
            stage.static_labels {
              values = { cluster = "homelab-prod" }   // change per cluster
            }
          }

          loki.write "central" {
            endpoint {
              url = "https://loki.mgmt.homelab.internal/loki/api/v1/push"
              tls_config {
                ca_file = "/etc/ssl/certs/homelab-root-ca.crt"
              }
            }
          }

          // ============================================================
          // Metrics
          // ============================================================
          prometheus.scrape "kubelet_cadvisor" {
            targets = discovery.kubernetes.nodes.targets
            forward_to = [prometheus.remote_write.central.receiver]
            scheme = "https"
            tls_config {
              ca_file = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
              insecure_skip_verify = false
            }
            bearer_token_file = "/var/run/secrets/kubernetes.io/serviceaccount/token"
            metrics_path = "/metrics/cadvisor"
          }

          // ServiceMonitor / PodMonitor scraping
          prometheus.operator.servicemonitors "default" {
            forward_to = [prometheus.remote_write.central.receiver]
          }
          prometheus.operator.podmonitors "default" {
            forward_to = [prometheus.remote_write.central.receiver]
          }

          prometheus.remote_write "central" {
            endpoint {
              url = "https://prometheus.mgmt.homelab.internal/api/v1/write"
              tls_config {
                ca_file = "/etc/ssl/certs/homelab-root-ca.crt"
              }
            }
            external_labels = {
              cluster = "homelab-prod",   // change per cluster
            }
          }
```

#### 3.4b — Per-cluster label discipline

Every metric and every log line gets a `cluster` label (`homelab-prod`, `homelab-dev`, `mgmt`). Grafana dashboards filter by cluster. This is the entire reason multi-cluster observability works without separate UIs per environment.

#### Verification

- [ ] Alloy pods Running on every node of every cluster
- [ ] In Grafana, query `{cluster="homelab-prod"}` in Logs Explore — returns container logs
- [ ] In Grafana, query `up{cluster="homelab-dev"}` in Metrics — returns scrape targets

---

### Phase 3.5: Grafana Alloy on Substrate VMs

**Goal:** Vault VMs, VyOS BGP routers, NFS server, Garage host, and the Proxmox hypervisors themselves ship logs and metrics into the LGTM stack. No SSH-into-vault-01-at-3am to read journalctl when something goes sideways.

> **Why this matters:** Phase 3.4 deployed Alloy on every Kubernetes node — every cluster is observable. But the *substrate* (Vault VMs, routers, storage hosts, hypervisors) is invisible. When Vault unseal fails at 3am, when BGP flaps, when ZFS hits a scrub error — without this, you're SSHing manually. This phase closes the substrate observability gap.

#### 3.5a — Alloy on Ubuntu VMs (Vault, NFS, Garage hosts)

Extend the existing OS baseline Ansible role:

```yaml
# roles/observability/tasks/main.yml
- name: Install Grafana Alloy
  apt:
    deb: "https://github.com/grafana/alloy/releases/download/v1.4.0/alloy-{{ ansible_architecture }}.deb"
    state: present

- name: Drop Alloy config
  template:
    src: alloy/config.alloy.j2
    dest: /etc/alloy/config.alloy
    owner: root
    group: root
    mode: '0644'
  notify: restart alloy

- name: Enable + start Alloy
  systemd:
    name: alloy
    enabled: true
    state: started
```

Config template captures journald, node metrics, and ships them to mgmt-plane:

```alloy
// /etc/alloy/config.alloy
loki.source.journal "journal" {
  forward_to = [loki.write.mgmt.receiver]
  labels = {
    host = "{{ ansible_hostname }}",
    role = "{{ host_role }}",         // vault | nfs | garage | bgp | hypervisor
  }
}

prometheus.exporter.unix "node" { }

prometheus.scrape "self" {
  targets    = prometheus.exporter.unix.node.targets
  forward_to = [prometheus.remote_write.mgmt.receiver]
}

loki.write "mgmt" {
  endpoint {
    url = "https://loki.homelab.local/loki/api/v1/push"
    tls_config {
      ca_file = "/etc/ssl/certs/homelab-root-ca.crt"
    }
  }
  // WAL on disk: don't lose logs if mgmt-plane is briefly unreachable
  wal {
    enabled = true
    max_segment_age = "1h"
  }
}

prometheus.remote_write "mgmt" {
  endpoint {
    url = "https://prometheus.homelab.local/api/v1/write"
  }
}
```

Push to vault-01/02/03, nfs-01, garage-01.

#### 3.5b — Alloy on VyOS routers

VyOS is Debian-based. The deb installs, but VyOS treats services through its config commit system rather than systemd directly. The pattern:

```bash
# In a VyOS config commit-on-boot script (or systemd-via-VyOS-task):
sudo dpkg -i /config/scripts/alloy.deb
sudo systemctl enable alloy
sudo systemctl start alloy
```

Capture VyOS-specific telemetry. FRRouting (VyOS's routing daemon) exposes metrics on a Unix socket; Alloy reads them:

```alloy
prometheus.exporter.frr "frr" {
  socket = "/var/run/frr/frr.sock"
}

prometheus.scrape "frr" {
  targets    = prometheus.exporter.frr.frr.targets
  forward_to = [prometheus.remote_write.mgmt.receiver]
}
```

Important metrics: `bgp_session_established`, `bgp_received_prefix_count`, `vrrp_role` (master vs backup).

#### 3.5c — Alloy on Proxmox hypervisors

Proxmox is Debian. Direct install works. Capture three additional sources:

```alloy
// Proxmox VE API metrics
prometheus.exporter.pve "pve" {
  api_url = "https://localhost:8006/api2/json"
  username = "metrics@pam"
  token_id = "alloy"
  token_secret = sys.env("PVE_TOKEN")
}

// ZFS pool health
prometheus.exporter.zfs "zfs" { }

// Hypervisor host metrics (already covered by unix exporter)
```

Provision the `metrics@pam` user in Proxmox with `PVEAuditor` role (read-only). Token stored in Vault, materialized by Ansible to `/etc/alloy/pve-token.env`.

**Important constraint:** Alloy on the hypervisor must NOT depend on Kubernetes being up to function locally. The WAL config ensures Alloy queues logs to disk when mgmt-plane is unreachable and replays when connectivity returns. Test this explicitly during verification.

#### 3.5d — Grafana dashboards: Substrate Health

Add a dashboard set under a "Substrate" folder:

- **Substrate / Vault VMs** — disk usage, memory pressure, `vault.service` status, time-since-last-seal-status-check, unseal status alert if applicable
- **Substrate / Network (VyOS)** — BGP session state per neighbor, VRRP master/backup, packet drops, interface error rates
- **Substrate / Storage** — NFS req/s and latency, ZFS pool health, scrub last-completed timestamp, ZFS error counts, Garage S3 op rate
- **Substrate / Hypervisors** — VM density per host, memory balloon pressure, IO wait, disk SMART status, host uptime

#### 3.5e — Alerts on substrate signals

The substrate alerts that should wake you up:

- `vault.service` not running on any vault-0X
- ZFS pool not ONLINE or scrub older than 30 days
- BGP session not Established for 2+ minutes (lose redundancy)
- VRRP master flap rate > 1/hr (likely network instability)
- Hypervisor IO wait > 30% for 10+ minutes
- Disk SMART self-test failed

Add these to Alertmanager routing (Phase 3.9) with `severity: critical`.

#### Verification

- [ ] `loki` query `{host="vault-01"}` in Grafana returns recent journal entries
- [ ] Prometheus query `node_filesystem_avail_bytes{host="garage-01"}` returns data
- [ ] BGP session state visible: `bgp_session_established{neighbor=~".*"}` returns 1 for each established session
- [ ] WAL test: `iptables -A OUTPUT -d <mgmt-plane> -j DROP` on vault-01 for 5 min → Alloy queues locally → restore connectivity → queued logs arrive in Loki
- [ ] All Substrate Health dashboards populated within 5 minutes of install
- [ ] Stop `vault.service` on vault-02 → alert fires within 2 minutes

---

### Phase 3.6: Cross-Cluster Wiring Verification

This is a verification phase, not a deployment phase. Confirm that data from all three clusters lands in the central stack.

- [ ] Logs from homelab-prod, homelab-dev, and mgmt visible in Grafana via the `cluster` label
- [ ] Metrics from all three clusters in central Prometheus
- [ ] Multi-cluster Grafana dashboards work: import the kube-state-metrics dashboards from grafana.com and confirm cluster selector populates with all three values

---

### Phase 3.7: Falco on Workload Clusters

**Goal:** Falco installed on homelab-prod and homelab-dev with default rules + the Falco Sandbox ruleset. Events shipped to Loki via falcosidekick.

#### 3.7a — Install via Helm (deployed by ArgoCD)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: falco-homelab-prod
  namespace: argocd
spec:
  destination:
    name: in-cluster
    namespace: falco
  source:
    repoURL: https://falcosecurity.github.io/charts
    chart: falco
    targetRevision: 4.x
    helm:
      values: |-
        driver:
          kind: modern-bpf   # eBPF driver, no kernel modules needed
        falcosidekick:
          enabled: true
          config:
            loki:
              hostport: https://loki.mgmt.homelab.internal
              tenant: homelab-prod
              tls:
                cafile: /etc/ssl/certs/homelab-root-ca.crt
        falcoctl:
          artifact:
            install:
              enabled: true
            follow:
              enabled: true
          config:
            artifact:
              install:
                refs: [falco-rules:3, falco-sandbox-rules:0]
              follow:
                refs: [falco-rules:3, falco-sandbox-rules:0]
```

Mirror to homelab-dev with `tenant: homelab-dev`.

#### 3.7b — Loki query examples for security review

```
# All Falco events from homelab-prod in the last hour
{cluster="homelab-prod", source="falco"} |= ""

# Critical and above only
{cluster="homelab-prod", source="falco"} |= "Critical" or {cluster="homelab-prod", source="falco"} |= "Error"

# Shell spawned in a container — common indicator
{cluster=~"homelab-prod|homelab-dev", source="falco"} |= "Terminal shell in container"
```

---

### Phase 3.8: Tetragon Event Export

**Goal:** Cilium Tetragon (already enabled in Tier 1 Cilium config) emits events. Alloy ships them to Loki.

Tetragon writes events to stdout in JSON. Alloy already tails container logs (Phase 3.4), so Tetragon events are *already* being shipped — they just need a label discriminator. Add to the Alloy log pipeline:

```hcl
loki.process "tag_tetragon" {
  forward_to = [loki.process.add_cluster_label.receiver]
  stage.match {
    selector = "{container=\"export-stdout\"}"
    stage.static_labels {
      values = { source = "tetragon" }
    }
  }
}
```

Query in Grafana: `{cluster="homelab-prod", source="tetragon"}`.

> **Falco vs Tetragon — why both:** Different lenses. Falco's rule engine is mature, with a large community ruleset library, and produces well-formed alert events. Tetragon's eBPF approach is more granular and lower-overhead but the rule-writing experience is more developer-y. In production you'd usually pick one as the primary alerting source and keep the other as a forensic detail layer. For v4, run both, learn the strengths, decide which becomes primary as workloads mature.

---

### Phase 3.9: Alertmanager Routing

**Goal:** Alerts from Prometheus rules reach you outside the homelab UI. v4 supports two delivery paths — pick one (or both).

#### Option A: Discord webhook (easy, third-party)

```yaml
# alertmanager-config.yaml (ESO-templated; webhook URL from Vault)
route:
  group_by: ['alertname', 'cluster', 'severity']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
  receiver: discord-default
  routes:
    - matchers: [severity="critical"]
      receiver: discord-critical
      repeat_interval: 30m

receivers:
  - name: discord-default
    discord_configs:
      - webhook_url_file: /etc/alertmanager/secrets/discord-default-webhook
  - name: discord-critical
    discord_configs:
      - webhook_url_file: /etc/alertmanager/secrets/discord-critical-webhook
```

#### Option B: Self-hosted ntfy.sh (no third-party)

Deploy ntfy as a small workload on homelab-mgmt, point Alertmanager at it via the generic webhook receiver. Defense-aligned: alerts never leave your network.

```yaml
# Brief ntfy deployment manifest
apiVersion: apps/v1
kind: Deployment
metadata: { name: ntfy, namespace: observability }
spec:
  replicas: 1
  selector: { matchLabels: { app: ntfy } }
  template:
    metadata: { labels: { app: ntfy } }
    spec:
      containers:
        - name: ntfy
          image: harbor.homelab-prod.homelab.internal/dockerhub/binwiederhier/ntfy:latest
          args: ["serve"]
          ports: [{ containerPort: 80, name: http }]
          volumeMounts:
            - { name: data, mountPath: /var/cache/ntfy }
      volumes:
        - name: data
          persistentVolumeClaim: { claimName: ntfy-data }
```

Exposed at `https://ntfy.mgmt.homelab.internal`. Subscribe from your phone via the ntfy app to specific topics (`homelab-prod-critical`, `homelab-dev-warnings`, etc.).

> **Recommendation:** Start with Discord (Option A) for friction-free setup. Migrate to ntfy in a Tier 3 follow-up if you want the "no alerts leave the network" property — defense-relevant, but not blocking.

#### Vault entries

```bash
vault kv put secret/mgmt/alertmanager/webhooks \
  discord-default-webhook="https://discord.com/api/webhooks/..." \
  discord-critical-webhook="https://discord.com/api/webhooks/..."
```

#### Verification

- [ ] Manually trigger an alert (e.g., scale down a deployment to 0 replicas with an `Up == 0` alert) — message arrives in Discord/ntfy within ~5 minutes
- [ ] Critical-routed alerts arrive in the correct channel/topic, not the default one

---

### Phase 3.10: Sloth — SLO-Driven Alerting

**Goal:** Define SLOs for the platform itself (API availability, Vault availability, ArgoCD reconcile latency) before any workload depends on them. Sloth converts SLO definitions into Prometheus recording and alerting rules — multi-window multi-burn-rate, the Google SRE pattern.

> **Why this is on the doc before workloads exist:** SLO discipline is a learned habit, not a tool. Defining SLOs for the platform itself — *before* there are workloads to distract you — is how you build the muscle. By Tier 4 every new app gets an SLO at deploy time because the muscle exists. Skipping this until "the apps need it" is how shops end up with year-old apps that have no SLOs.

#### 3.10a — Install Sloth

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata: { name: sloth, namespace: observability }
spec:
  chart:
    spec:
      chart: sloth
      version: "0.x"
      sourceRef: { kind: HelmRepository, name: sloth }
```

#### 3.10b — Platform SLOs

```yaml
# observability/sloth/platform-slos.yaml
apiVersion: sloth.slok.dev/v1
kind: PrometheusServiceLevel
metadata:
  name: platform-availability
  namespace: observability
spec:
  service: "platform"
  labels:
    tier: "platform"
  slos:
    - name: "vault-api-availability"
      objective: 99.9
      description: "Vault API responsive within VLAN 40"
      sli:
        events:
          error_query: 'sum(rate(vault_audit_log_request_failure[5m]))'
          total_query: 'sum(rate(vault_audit_log_request[5m]))'
      alerting:
        name: VaultAPIBurnRate
        page_alert:    { labels: { severity: critical } }
        ticket_alert:  { labels: { severity: warning } }

    - name: "homelab-prod-api-availability"
      objective: 99.5
      sli:
        events:
          error_query: 'sum(rate(apiserver_request_total{cluster="homelab-prod",code=~"5.."}[5m]))'
          total_query: 'sum(rate(apiserver_request_total{cluster="homelab-prod"}[5m]))'
      alerting:
        name: HomelabProdAPIBurnRate
        page_alert:    { labels: { severity: critical } }

    - name: "argocd-sync-success"
      objective: 99.0
      sli:
        events:
          error_query: 'sum(rate(argocd_app_sync_total{phase="Failed"}[5m]))'
          total_query: 'sum(rate(argocd_app_sync_total[5m]))'
      alerting:
        name: ArgoCDSyncBurnRate
        ticket_alert:  { labels: { severity: warning } }
```

#### Verification

- [ ] Sloth pod Running
- [ ] PrometheusRule generated by Sloth visible: `kubectl get prometheusrule | grep platform`
- [ ] Recording rules query successfully in Prometheus (`slo:sli_error:ratio_rate5m`)
- [ ] Alert rules visible in Alertmanager UI under "Configured Alerts"

---

### Phase 3.11: CloudNativePG on Mgmt-Plane

**Goal:** Postgres operator installed on homelab-mgmt so Keycloak can have a real database.

Same install as Tier 2 Phase 2.8 on homelab-prod — duplicate the HelmRelease into `homelab-gitops/clusters/homelab-mgmt/cnpg/`.

> **Why a duplicate operator install rather than reaching across clusters:** Database stays in the same cluster as its consumer. Cross-cluster DB connections introduce a coupling we don't want for identity (Keycloak needs to function even if homelab-prod is rebuilding). The operator binary is tiny (~50MB RAM). ADR-worthy "each cluster owns its data tier."

---

### Phase 3.12: Kubernetes Audit Log Immutable Retention

**Goal:** Kubernetes API server audit logs ship immediately to Loki under a dedicated tenant with long retention. Long-term audit chunks replicate to AWS S3 with Object Lock. A compromised control plane cannot tamper with its own audit trail.

> **Why this matters:** RKE2's CIS profile writes audit logs to `/var/lib/rancher/rke2/server/logs/audit.log` on each CP node. If that node is compromised, those logs are mutable. Shipping them off-host immediately removes that attack window. For any defense customer (and increasingly for SOC2 / FedRAMP-adjacent commercial customers), audit-log integrity is a hard requirement. This phase makes the v4 platform actually audit-defensible rather than just "audit logs exist."

#### 3.12a — Separate audit logs from app logs in Alloy

Already shipping logs via the Tier 3.4 Alloy DaemonSet — but they currently go into the same Loki tenant as app logs. Separate them with a distinct source and a different `tenant_id` on the write endpoint.

Extend the Alloy config on control plane nodes:

```alloy
loki.source.file "k8s_audit" {
  targets = [{__path__ = "/var/lib/rancher/rke2/server/logs/audit.log"}]
  forward_to = [loki.process.audit.receiver]
}

loki.process "audit" {
  stage.static_labels {
    values = {
      log_type = "audit",
      cluster  = "homelab-prod",   // templated per cluster
    }
  }
  stage.json {
    expressions = {
      verb = "verb",
      user = "user.username",
      resource = "objectRef.resource",
      namespace = "objectRef.namespace",
    }
  }
  stage.labels {
    values = { verb = "", user = "", resource = "" }
  }
  forward_to = [loki.write.audit.receiver]
}

loki.write "audit" {
  endpoint {
    url       = "https://loki.homelab.local/loki/api/v1/push"
    tenant_id = "audit"
    tls_config {
      ca_file = "/etc/ssl/certs/homelab-root-ca.crt"
    }
  }
  wal {
    enabled = true
    max_segment_age = "4h"   // longer WAL for audit — never drop on the floor
  }
}
```

Audit logs now arrive in Loki under tenant `audit`, separately from app logs under tenant `default`.

#### 3.12b — Loki multi-tenant config with per-tenant retention

Update Loki helm values:

```yaml
loki:
  config:
    auth_enabled: true   // required for multi-tenancy
    limits_config:
      retention_period: 30d      // default for any tenant
      ingestion_rate_mb: 16
      ingestion_burst_size_mb: 32
  # Per-tenant overrides
  runtimeConfig:
    overrides:
      audit:
        retention_period: 365d     # one year hot-queryable
        ingestion_rate_mb: 10
        max_query_lookback: 365d
  schemaConfig:
    configs:
      - from: 2026-01-01
        store: tsdb
        object_store: s3
        schema: v13
        index:
          prefix: index_
          period: 24h
```

#### 3.12c — Object Lock for long-term audit archive

The audit tenant in Loki keeps 365 days hot-queryable. Beyond that, chunks compact and ship to a separate AWS S3 bucket with Object Lock — the same WORM pattern from Phase 1.11.

Stand up the bucket:

```hcl
# homelab-terraform/modules/audit-archive/main.tf
resource "aws_s3_bucket" "audit_archive" {
  bucket              = "homelab-audit-logs-immutable"
  object_lock_enabled = true
}

resource "aws_s3_bucket_object_lock_configuration" "audit_archive" {
  bucket = aws_s3_bucket.audit_archive.id
  rule {
    default_retention {
      mode = "COMPLIANCE"   // even root can't bypass before window expires
      days = 2555           // 7 years — the common audit floor
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "audit_archive" {
  bucket = aws_s3_bucket.audit_archive.id
  rule {
    id     = "transition-to-glacier"
    status = "Enabled"
    transition {
      days          = 90
      storage_class = "GLACIER"
    }
  }
}
```

CronJob in `platform-dr` namespace runs daily, syncs Loki-compacted audit chunks from Garage to AWS:

```yaml
spec:
  schedule: "0 4 * * *"
  jobTemplate:
    spec:
      template:
        spec:
          containers:
            - name: rclone
              image: harbor.homelab.local/rclone/rclone:latest
              command:
                - rclone
                - sync
                - garage:loki-chunks/audit/
                - aws:homelab-audit-logs-immutable/
                - --immutable
                - --transfers=2
```

7-year retention with COMPLIANCE mode is the strictest tier; downgrade to GOVERNANCE mode if you want to be able to lift retention later in genuine emergencies. COMPLIANCE is what defense customers typically expect.

#### 3.12d — Grafana access pattern: tenant-aware permissions

Audit logs aren't for everyone. Configure Grafana with separate datasources per tenant:

- `Loki (default)` — app logs, available to anyone with Grafana login
- `Loki (audit)` — audit logs, available only to `mlops-admins` or `homelab-admins` group via Keycloak role mapping

Grafana datasource permissions (set in the datasource YAML):

```yaml
apiVersion: 1
datasources:
  - name: Loki-audit
    type: loki
    url: http://loki.loki.svc.cluster.local:3100
    jsonData:
      httpHeaderName1: 'X-Scope-OrgID'
    secureJsonData:
      httpHeaderValue1: 'audit'
    # Restrict via Grafana team permissions
```

Build a default dashboard: "Audit Trail":
- Failed authentications (verb=create, resource=tokenreviews, status=Failure)
- RBAC denials (annotations.authorization.k8s.io/decision=Forbid)
- Secret reads (verb=get, resource=secrets)
- Namespace deletions (verb=delete, resource=namespaces)
- Privileged pod creations (Kyverno blocks these but the attempt is the signal)

#### 3.12e — Alert on audit log absence (canary)

If audit logs stop arriving from a cluster, that itself is a security signal — possibly indicating tampering or a compromise. Add a Prometheus alert:

```yaml
- alert: AuditLogIngestStopped
  expr: |
    rate(loki_distributor_lines_received_total{tenant="audit"}[5m]) == 0
  for: 10m
  labels:
    severity: critical
    pager: true
  annotations:
    summary: "Audit logs not arriving in Loki for {{ $labels.cluster }} for 10+ minutes"
    runbook_url: "https://homelab.local/runbooks/audit-log-stopped"
```

The runbook walks through diagnosing whether it's a network issue, Alloy crash, log rotation problem, or actual tampering.

#### Verification

- [ ] Audit logs visible in Grafana via the audit-tenant datasource: `{log_type="audit", cluster="homelab-prod"}`
- [ ] Non-admin user logged into Grafana sees app logs only, NOT audit (test with a `data-scientist` Keycloak user)
- [ ] 365d retention configured on audit tenant: `curl loki/loki/api/v1/labels --header "X-Scope-OrgID: audit"` works, oldest data is from a year back (after the year passes)
- [ ] AWS S3 archive bucket receiving compacted audit chunks daily
- [ ] `aws s3api delete-object --bucket homelab-audit-logs-immutable --key <chunk>` returns AccessDenied during retention window
- [ ] AuditLogIngestStopped alert fires after `iptables -A OUTPUT -d <loki-IP> -p tcp --dport 3100 -j DROP` on a CP node for 15 minutes

---

### Phase 3.13: Keycloak Deployment

**Goal:** Keycloak running on homelab-mgmt at `keycloak.mgmt.homelab.internal`, backed by CloudNativePG, with a `homelab` realm and clients pre-staged for ArgoCD, Grafana, Harbor, and Vault. **Break-glass admin retained on every integration.**

#### 3.13a — Postgres cluster for Keycloak

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata: { name: keycloak-postgres, namespace: keycloak }
spec:
  instances: 2
  storage:
    size: 10Gi
    storageClass: nfs-csi
  backup:
    barmanObjectStore:
      destinationPath: s3://harbor-registry/postgres-backups/keycloak
      endpointURL: http://garage-01.homelab.internal:3900
      s3Credentials:
        accessKeyId:     { name: garage-cnpg-creds, key: access-key }
        secretAccessKey: { name: garage-cnpg-creds, key: secret-key }
    retentionPolicy: "30d"
```

#### 3.13b — Keycloak via Bitnami chart

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata: { name: keycloak, namespace: keycloak }
spec:
  chart:
    spec:
      chart: keycloak
      version: "22.x"
      sourceRef: { kind: HelmRepository, name: bitnami }
  values:
    auth:
      adminUser: admin
      existingSecret: keycloak-admin-credentials   # ESO from Vault
    replicaCount: 2
    proxyHeaders: xforwarded
    externalDatabase:
      host: keycloak-postgres-rw.keycloak.svc
      port: 5432
      database: keycloak
      existingSecret: keycloak-postgres-app
      existingSecretUserKey: username
      existingSecretPasswordKey: password
    postgresql: { enabled: false }   # using CNPG, not bundled chart
    ingress:
      enabled: true
      ingressClassName: cilium
      hostname: keycloak.mgmt.homelab.internal
      tls: true
      extraTls:
        - hosts: [keycloak.mgmt.homelab.internal]
          secretName: mgmt-wildcard-tls
    production: true
    cache: { enabled: true }
```

#### 3.13c — Realm + clients (Terraform via the Keycloak provider — or manual UI for v4 bootstrap)

For Tier 3 bootstrap, use the UI. In Tier 4 we'll migrate realm config to declarative (`mrparkers/keycloak` Terraform provider running against the existing Keycloak):

1. Create realm `homelab`
2. Create users: yourself, with email + initial password (will rotate after first login)
3. Create clients:
   - **`argocd`** — confidential, redirect URI `https://argocd.homelab-prod.homelab.internal/auth/callback`
   - **`grafana`** — confidential, redirect URI `https://grafana.mgmt.homelab.internal/login/generic_oauth`
   - **`harbor`** — confidential, redirect URI `https://harbor.homelab-prod.homelab.internal/c/oidc/callback`
   - **`vault`** — confidential, redirect URI `https://vault.homelab.internal:8200/ui/vault/auth/oidc/oidc/callback` (and the CLI variant)
4. For each client, capture the client secret and store in Vault:
   ```bash
   vault kv put secret/mgmt/keycloak/argocd-oidc client-id="argocd" client-secret="..."
   # etc for each
   ```
5. Map realm roles to groups: `homelab-admin`, `homelab-reader`. Assign yourself to `homelab-admin`.

#### 3.13d — Break-glass runbook (commit to `homelab-gitops/docs/runbooks/keycloak-outage.md`)

```markdown
# Runbook: Keycloak Outage

## Symptoms
- ArgoCD UI shows "OIDC unavailable" on login page
- Grafana login redirects to non-functioning Keycloak
- Harbor login fails

## Immediate Mitigation
Each integration retains a local admin account that bypasses OIDC:

| Service  | URL                                        | Local Admin Credential Path           |
| -------- | ------------------------------------------ | ------------------------------------- |
| ArgoCD   | https://argocd.homelab-prod.../  (login as admin, not SSO) | pass: homelab/argocd/admin            |
| Grafana  | https://grafana.mgmt.../                   | pass: homelab/grafana/admin           |
| Harbor   | https://harbor.homelab-prod.../              | pass: homelab/harbor/admin            |
| Vault    | https://vault.../  (token auth, not OIDC)  | pass: homelab/vault/root-token-backup |

## Recovery Steps
1. Check Keycloak pod status: `kubectl --context mgmt -n keycloak get pods`
2. Check Postgres status: `kubectl --context mgmt -n keycloak get cluster keycloak-postgres`
3. Most common failure: Postgres pod OOM. Increase resources, rollout restart.
4. If Postgres data corruption: restore from Garage backup using CNPG's recovery procedure (separate runbook)
5. If realm config corruption: re-import from the realm JSON exported quarterly (auto-cron at TODO)
```

#### Verification

- [ ] Keycloak UI reachable, login as admin works
- [ ] Realm `homelab` exists with 4 clients configured
- [ ] All 4 client secrets stored in Vault under `secret/mgmt/keycloak/*`
- [ ] Local-admin credentials for each integration target stored in `pass`
- [ ] Runbook committed to gitops repo and readable

---

### Phase 3.14: OIDC Integrations

Now wire each consumer. Pattern is identical: read client secret from Vault via ESO, configure OIDC in the app, test login, retain local-admin fallback.

#### 3.14a — ArgoCD

ConfigMap patch in `homelab-gitops/clusters/homelab-prod/argocd-config/`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata: { name: argocd-cm, namespace: argocd }
data:
  url: https://argocd.homelab-prod.homelab.internal
  oidc.config: |
    name: Keycloak
    issuer: https://keycloak.mgmt.homelab.internal/realms/homelab
    clientID: argocd
    clientSecret: $oidc.keycloak.clientSecret    # references ESO-materialized secret
    requestedScopes: ["openid", "profile", "email", "groups"]
    requestedIDTokenClaims: { groups: { essential: true } }
---
apiVersion: v1
kind: ConfigMap
metadata: { name: argocd-rbac-cm, namespace: argocd }
data:
  policy.default: role:readonly
  policy.csv: |
    g, homelab-admin, role:admin
    g, homelab-reader, role:readonly
```

#### 3.14b — Grafana

In the kube-prometheus-stack values, add:

```yaml
grafana:
  grafana.ini:
    server:
      root_url: https://grafana.mgmt.homelab.internal
    auth.generic_oauth:
      enabled: true
      name: Keycloak
      client_id: grafana
      client_secret: $__file{/etc/grafana/oauth-secret/secret}
      scopes: openid email profile groups
      auth_url: https://keycloak.mgmt.homelab.internal/realms/homelab/protocol/openid-connect/auth
      token_url: https://keycloak.mgmt.homelab.internal/realms/homelab/protocol/openid-connect/token
      api_url:  https://keycloak.mgmt.homelab.internal/realms/homelab/protocol/openid-connect/userinfo
      role_attribute_path: contains(groups[*], 'homelab-admin') && 'Admin' || 'Viewer'
```

ESO mounts the client secret to `/etc/grafana/oauth-secret/secret`.

#### 3.14c — Harbor

Harbor UI → Administration → Configuration → Authentication → OIDC Provider:

- Name: Keycloak
- Endpoint: `https://keycloak.mgmt.homelab.internal/realms/homelab`
- Client ID: harbor
- Client Secret: (from Vault)
- Scope: `openid,profile,email,groups`
- Verify Certificate: yes
- Auto onboarding: yes
- User claim: preferred_username

#### 3.14d — Vault UI

```bash
vault auth enable oidc
vault write auth/oidc/config \
  oidc_discovery_url="https://keycloak.mgmt.homelab.internal/realms/homelab" \
  oidc_client_id="vault" \
  oidc_client_secret="<from-keycloak>" \
  default_role="reader"

vault write auth/oidc/role/admin \
  bound_audiences="vault" \
  allowed_redirect_uris="https://vault.homelab.internal:8200/ui/vault/auth/oidc/oidc/callback" \
  allowed_redirect_uris="http://localhost:8250/oidc/callback" \
  user_claim="sub" \
  groups_claim="groups" \
  bound_claims='{"groups": ["homelab-admin"]}' \
  policies="default"   # Vault root policy retained only via token auth as break-glass

vault write auth/oidc/role/reader \
  bound_audiences="vault" \
  allowed_redirect_uris="https://vault.homelab.internal:8200/ui/vault/auth/oidc/oidc/callback" \
  user_claim="sub" \
  policies="default"
```

> **Vault's root token stays for break-glass.** The root token never gets revoked. It's stored in `pass` under `homelab/vault/root-token-backup` and is the bypass if Keycloak is down AND you've locked yourself out of OIDC. Generate-root via recovery keys is the *deeper* break-glass; root token is the everyday one.

#### Verification

- [ ] Log into each UI via Keycloak (ArgoCD, Grafana, Harbor, Vault UI)
- [ ] Group-based authorization works: removing yourself from `homelab-admin` in Keycloak demotes access to read-only on next login
- [ ] Local-admin fallback works for each (test by deliberately failing OIDC — e.g., temporarily change client_secret to garbage, verify local-admin still works, restore)
- [ ] Vault's CLI OIDC login flow works: `vault login -method=oidc role=admin` opens browser, returns token

---

### Phase 3.15: OpenCost — Cost Attribution and Visibility

**Goal:** Per-namespace, per-tenant, per-workload cost visibility across homelab clusters and AWS cloud bursts. Replaces what would otherwise be a multi-week build of custom Prometheus recording rules and label-slicing.

> **Why this matters:** Tier 5 multi-tenancy needs cost accountability — who's burning the GPU dollars on a cloud burst? Building this from scratch with PromQL gets you 60% of the way to OpenCost's out-of-the-box dashboards and saves the rest of the build entirely. OpenCost is the CNCF project Kubecost is built on; it's production-grade and free.

#### 3.15a — Deploy OpenCost on mgmt-plane

Single central OpenCost on homelab-mgmt with federation from workload clusters.

```yaml
# homelab-gitops/apps/opencost/values.yaml
opencost:
  prometheus:
    external:
      enabled: true
      url: http://prometheus.mgmt.svc.cluster.local:9090
  exporter:
    defaultClusterId: homelab-mgmt
    persistentVolume:
      enabled: true
      size: 10Gi
  ui:
    enabled: true
    ingress:
      enabled: true
      hosts:
        - opencost.homelab.local
      annotations:
        external-dns.alpha.kubernetes.io/hostname: opencost.homelab.local
  # Synthetic pricing for homelab hardware (amortized) — these aren't free
  customPricing:
    enabled: true
    provider: custom
    costModel:
      CPU: 0.02       # $/CPU-hour, M920q amortization
      spotCPU: 0.02
      RAM: 0.005      # $/GB-hour
      spotRAM: 0.005
      GPU: 0          # no homelab GPUs
      storage: 0.0001 # $/GB-hour
      internetNetworkEgress: 0
      regionNetworkEgress: 0
      zoneNetworkEgress: 0
```

Cloud-burst clusters automatically use real AWS prices when OpenCost detects them — no custom pricing needed for those.

#### 3.15b — Federation from workload clusters

Each workload cluster runs an OpenCost agent that the central instance scrapes:

```yaml
# homelab-gitops/apps/opencost-agent/values.yaml  (on homelab-prod, homelab-dev)
opencost:
  exporter:
    defaultClusterId: homelab-prod  # or homelab-dev
  prometheus:
    external:
      url: http://prometheus.mgmt.homelab.local:9090   # central Prom
  ui:
    enabled: false  # agents don't expose UI, only central does
```

Central OpenCost aggregates by `clusterId` label, so the UI shows cost broken down by source cluster.

#### 3.15c — Label-based cost attribution

OpenCost slices by Kubernetes labels. The Tier 5 multi-tenancy labels (`mlops.homelab/owner-sub`, `mlops.homelab/owner-username`) are designed for this.

```bash
# Cost by owner over the last 30 days
curl 'http://opencost.homelab.local/allocation?window=30d&aggregate=label:mlops_homelab_owner_username'
```

Push aggregations into Prometheus as recording rules so they appear in Grafana:

```yaml
- record: mlops:cost_by_owner_30d:sum
  expr: |
    sum by (mlops_homelab_owner_username) (
      opencost_namespace_total_cost{namespace=~"mlops-.+"}
    )

- record: mlops:cost_by_tier_30d:sum
  expr: |
    sum by (mlops_homelab_tier) (
      opencost_namespace_total_cost{namespace=~"mlops-.+"}
    )
```

#### 3.15d — Cloud-burst cost attribution

Tier 5.10 spins up AWS EKS clusters per training job. Two integration points:

1. **Resource tagging.** Terraform module tags every AWS resource with `mlops-burst-job-id` and `owner-username`. AWS Cost Explorer reads these tags.

2. **Cost Explorer puller.** A CronJob in homelab-mgmt queries Cost Explorer daily, attributes spend to users, pushes results to Prometheus pushgateway:

```python
# scripts/aws-cost-attribution.py
import boto3, os, requests
from datetime import datetime, timedelta

ce = boto3.client('ce')
end = datetime.utcnow().date()
start = end - timedelta(days=1)

resp = ce.get_cost_and_usage(
    TimePeriod={'Start': str(start), 'End': str(end)},
    Granularity='DAILY',
    Metrics=['UnblendedCost'],
    GroupBy=[{'Type': 'TAG', 'Key': 'owner-username'}]
)

for group in resp['ResultsByTime'][0]['Groups']:
    owner = group['Keys'][0].split('$')[1]   # "owner-username$alice"
    cost = float(group['Metrics']['UnblendedCost']['Amount'])
    # Push to Prometheus pushgateway
    requests.post(
        f'{os.environ["PUSHGATEWAY"]}/metrics/job/aws-cost-attribution',
        data=f'aws_cost_daily{{owner="{owner}"}} {cost}\n'
    )
```

AWS creds via Vault AWS secrets engine (Tier 5.7).

#### 3.15e — Grafana dashboards and budget alerts

Add the dashboard set:
- **MLOps Cost by Tenant** — total $ per Keycloak user over time, daily/weekly/monthly
- **MLOps Cost by Tier** — sandbox vs staging vs prod cost ratios
- **Cloud Burst Spend** — daily AWS spend with drill-down by user and job-id
- **Cost Forecasts** — naive 30-day projection per user based on trailing rate

Budget alerts:

```yaml
- alert: TenantMonthlyBudgetExceeded
  expr: mlops:cost_by_owner_30d:sum > 500
  labels:
    severity: warning
  annotations:
    summary: "Tenant {{ $labels.mlops_homelab_owner_username }} exceeded $500 in trailing 30d"

- alert: CloudBurstSpendSpike
  expr: rate(aws_cost_daily[1d]) > rate(aws_cost_daily[7d]) * 3
  for: 1h
  labels:
    severity: critical
  annotations:
    summary: "Cloud burst spend tripled vs trailing week — runaway job?"
```

#### Verification

- [ ] OpenCost UI reachable at https://opencost.homelab.local
- [ ] Cost data appearing for all three clusters (cluster selector populates)
- [ ] Custom pricing applied: verify CPU cost matches config
- [ ] Label aggregation: `curl 'opencost.homelab.local/allocation?aggregate=label:mlops_homelab_owner_username'` returns per-owner data
- [ ] After a Tier 5.10 cloud-burst job: AWS spend attributed within 24h
- [ ] Budget alert fires when set to a deliberately low threshold (then revert)
- [ ] Spend spike alert tested by manipulating a synthetic high value

---

### Phase 3.16: Tier 3 Verification Gate

#### Observability

- [ ] Prometheus on homelab-mgmt scrapes all three clusters via Alloy remote_write
- [ ] Loki receives logs from all three clusters; cluster label discriminates correctly
- [ ] Tempo receives traces from manual test pushes; trace queryable in Grafana
- [ ] Multi-cluster dashboards work: kube-state-metrics, node-exporter, Cilium dashboards all populate for all three clusters
- [ ] Grafana data sources all green
- [ ] Alloy DaemonSet healthy on every node of every cluster

#### Substrate observability

- [ ] Alloy running on every Vault VM, NFS host, Garage host, BGP router, and Proxmox hypervisor
- [ ] `loki` query `{host="vault-01"}` returns recent journal entries
- [ ] BGP session metrics visible: `bgp_session_established` returns 1 per established neighbor
- [ ] Substrate Health dashboards populated (Vault, Network, Storage, Hypervisors)
- [ ] WAL resilience verified: substrate Alloy queues logs locally when mgmt-plane is briefly unreachable, replays on recovery

#### Audit log immutability

- [ ] Audit logs visible under separate Loki tenant `audit` (verify with `X-Scope-OrgID: audit`)
- [ ] Non-admin Grafana user cannot read audit tenant (test with `data-scientist` user)
- [ ] AWS S3 audit archive bucket receiving daily compacted chunks
- [ ] Object Lock enforced: delete attempt on archived chunk returns AccessDenied
- [ ] AuditLogIngestStopped alert fires when audit log shipping is artificially broken

#### Cost attribution

- [ ] OpenCost UI reachable at `https://opencost.homelab.local`
- [ ] Cost data visible per cluster (homelab-prod, homelab-dev, homelab-mgmt)
- [ ] Custom homelab pricing applied
- [ ] Per-namespace cost breakdown working
- [ ] Label aggregation by `mlops.homelab/owner-username` returns data (after Tier 5 tenants exist; otherwise verify with placeholder labels)

#### Runtime security

- [ ] Falco running on homelab-prod and homelab-dev; events arrive in Loki tagged `source=falco`
- [ ] Tetragon events tagged `source=tetragon` in Loki
- [ ] Synthetic event test: `kubectl exec` into a pod, verify a "Terminal shell in container" event lands in Loki within 30 seconds

#### Alerting

- [ ] Alertmanager delivers test alert to Discord/ntfy within 5 minutes
- [ ] Critical-severity routes hit the critical channel; warning-severity hits the default
- [ ] Sloth-generated SLO alerts visible in Alertmanager UI

#### Identity

- [ ] Keycloak reachable, realm + 4 clients + admin user configured
- [ ] Each of ArgoCD, Grafana, Harbor, Vault UI logs in via Keycloak SSO
- [ ] Group-based authorization tested for each
- [ ] Break-glass local-admin works for each (verified)
- [ ] Keycloak outage runbook committed to gitops repo

#### Hygiene

- [ ] All OIDC client secrets in Vault
- [ ] All break-glass credentials in `pass`
- [ ] CNPG backups for keycloak-postgres landing in Garage
- [ ] Workstation (and ideally mobile) trust store contains the homelab root CA — every UI loads with a green padlock

When every item passes: **Tier 3 is complete.** The platform now sees itself, knows when it's broken, and authenticates everyone through a single source of truth. Tier 4 is the payoff — actual workloads deployed via real GitOps patterns, with canary rollouts, load testing, and chaos engineering exercising everything you just built.
# Tier 4 — Workloads & Delivery

**Purpose:** Everything built in Tiers 0–3 finally does work. Real applications deploy via real GitOps patterns. Progressive delivery with automated canary analysis. Load testing and chaos engineering exercise the platform against simulated production stress. Backups are tested with a documented disaster recovery drill. Policy enforcement moves from audit to enforce. This is the tier where v4 becomes the longstanding foundation it was designed to be.

**Why this tier exists:** A platform without workloads is just infrastructure. A workload without observability, identity, signing, policy, and progressive delivery is just a deployment. Tier 4 is where the pieces come together to demonstrate every production pattern the previous tiers enabled.

## Tier 4 Phases

- **4.1** — Argo Rollouts installation
- **4.2** — ApplicationSet structure for env promotion
- **4.3** — Argo Events (EventBus + EventSources + Sensors)
- **4.4** — Declarative Keycloak realm via Terraform
- **4.5** — Custom OTel app: end-to-end production deployment story
- **4.6** — ARC (Actions Runner Controller) for self-hosted runners
- **4.7–4.11** — *Deferred to post-Tier-5*: Vaultwarden, n8n, NetBox, Forgejo, Immich (see Tier 5 doc)
- **4.12** — k6-operator and load-testing patterns
- **4.13** — Chaos Mesh and combined chaos+load tests
- **4.14** — Velero on every cluster + DR drill
- **4.15** — Kyverno audit → enforce migration
- **4.16** — Carryover items from earlier tiers
- **4.17** — Tier 4 verification gate
- **4.18** — Closing reflections

---

### Phase 4.1: Argo Rollouts Installation

**Goal:** Argo Rollouts controller installed on homelab-prod and homelab-dev. Rollout resources can replace Deployments to get canary / blue-green / progressive delivery with automated analysis.

#### 4.1a — Install via Helm (managed by ArgoCD itself in app-of-apps pattern)

```yaml
# homelab-gitops/clusters/homelab-prod/argo-rollouts/application.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: argo-rollouts
  namespace: argocd
spec:
  destination: { name: in-cluster, namespace: argo-rollouts }
  source:
    repoURL: https://argoproj.github.io/argo-helm
    chart: argo-rollouts
    targetRevision: 2.x
    helm:
      values: |-
        dashboard:
          enabled: true
          ingress:
            enabled: true
            ingressClassName: cilium
            hosts: [rollouts.homelab-prod.homelab.internal]
            tls: [{ secretName: homelab-prod-wildcard-tls, hosts: [rollouts.homelab-prod.homelab.internal] }]
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true]
```

Mirror to homelab-dev with hostname `rollouts.homelab-dev.homelab.internal`.

#### 4.1b — Install kubectl plugin on workstation

```bash
curl -LO https://github.com/argoproj/argo-rollouts/releases/latest/download/kubectl-argo-rollouts-linux-amd64
chmod +x kubectl-argo-rollouts-linux-amd64
sudo mv kubectl-argo-rollouts-linux-amd64 /usr/local/bin/kubectl-argo-rollouts

kubectl argo rollouts version   # confirms plugin works
```

#### Verification

- [ ] Rollouts controller pods Running on homelab-prod and homelab-dev
- [ ] Dashboard reachable at `https://rollouts.homelab-prod.homelab.internal` (via Keycloak OIDC once a downstream issue with Rollouts OIDC is configured — local-admin works for now)
- [ ] `kubectl-argo-rollouts get rollout` is functional (returns "no resources" — expected, no Rollouts yet)

---

### Phase 4.2: ApplicationSet Structure for Env Promotion

**Goal:** A clean ApplicationSet pattern that generates per-environment Applications, with kustomize overlays per environment, and a documented promotion workflow.

#### 4.2a — Repo structure

```
homelab-gitops/
├── clusters/
│   ├── homelab-prod/                        # prod cluster
│   │   ├── apps/                          # ApplicationSets and Applications
│   │   ├── argo-rollouts/
│   │   ├── argocd-config/
│   │   ├── harbor/
│   │   └── platform-services/
│   ├── homelab-dev/                             # dev/staging cluster
│   │   ├── apps/
│   │   └── platform-services/
│   └── homelab-mgmt/                        # mgmt cluster (Flux-managed)
│       └── observability/
└── apps/                                  # per-app source manifests with overlays
    ├── hello-otel/                        # custom app
    │   ├── base/
    │   │   ├── kustomization.yaml
    │   │   ├── rollout.yaml
    │   │   ├── service.yaml
    │   │   ├── httproute.yaml
    │   │   ├── postgres-cluster.yaml
    │   │   ├── external-secret.yaml
    │   │   └── analysis-template.yaml
    │   └── overlays/
    │       ├── dev/                       # homelab-dev / namespace: hello-dev
    │       │   ├── kustomization.yaml
    │       │   └── patches/
    │       ├── staging/                   # homelab-dev / namespace: hello-staging
    │       └── prod/                      # homelab-prod / namespace: hello-prod
    ├── vaultwarden/
    ├── n8n/
    ├── netbox/
    ├── forgejo/
    └── immich/
```

#### 4.2b — ApplicationSet template

```yaml
# homelab-gitops/clusters/homelab-prod/apps/hello-otel-appset.yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: hello-otel
  namespace: argocd
spec:
  generators:
    - list:
        elements:
          - env: dev
            cluster: homelab-dev
            namespace: hello-dev
            autoSync: true     # dev auto-syncs on every commit
          - env: staging
            cluster: homelab-dev
            namespace: hello-staging
            autoSync: false    # staging requires manual sync trigger
          - env: prod
            cluster: in-cluster   # homelab-prod
            namespace: hello-prod
            autoSync: false    # prod requires manual sync — promotion gate
  template:
    metadata:
      name: 'hello-otel-{{env}}'
      labels:
        app: hello-otel
        env: '{{env}}'
    spec:
      project: default
      source:
        repoURL: git@github.com:yourorg/homelab-gitops.git
        path: 'apps/hello-otel/overlays/{{env}}'
        targetRevision: main
      destination:
        name: '{{cluster}}'
        namespace: '{{namespace}}'
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
          - ServerSideApply=true
```

> **`autoSync` per environment is intentional asymmetry.** Dev syncs automatically because that's where you want fast feedback. Staging is manual to force a deliberate "ready for testing" decision. Prod is manual because flipping bits in prod is always a deliberate human decision. This pattern maps directly to how regulated environments work — promotion always involves a human gate.

#### 4.2c — Promotion workflow

The image tag in `apps/hello-otel/overlays/<env>/kustomization.yaml` defines what's deployed:

```yaml
# apps/hello-otel/overlays/dev/kustomization.yaml
resources:
  - ../../base
images:
  - name: hello-otel
    newName: harbor.homelab-prod.homelab.internal/apps/hello-otel
    newTag: "v1.4.2-rc.7"   # Renovate updates this when a new tag exists
namespace: hello-dev
```

**Promotion = a PR moving a tag through the overlays:**

1. CI builds + signs image → pushes to Harbor with semver tag
2. Renovate opens PR updating `overlays/dev/kustomization.yaml` to the new tag
3. PR merges → ArgoCD auto-syncs to homelab-dev/hello-dev (autoSync: true)
4. Manual promotion: human opens PR updating `overlays/staging/kustomization.yaml` to the same tag
5. PR merges → manual `argocd app sync hello-otel-staging` (or trigger via UI)
6. After staging validation: PR for `overlays/prod/kustomization.yaml` → manual prod sync

> **What about Kargo?** Kargo (the Argo promotion tool) automates step 4 onwards but is still maturing. The PR-based pattern above is simpler, leaves a clear audit trail in Git, and is exactly how most production shops do it without a dedicated promotion tool. ADR-worthy: "considered Kargo, chose PR-based promotion for transparency and tooling minimalism."

#### Verification (after Phase 4.5 deploys the actual app)

- [ ] ApplicationSet generates three Applications: `hello-otel-dev`, `hello-otel-staging`, `hello-otel-prod`
- [ ] Dev syncs automatically on commit; staging and prod require manual sync
- [ ] Promoting a tag through dev → staging → prod via PRs works end-to-end

---

### Phase 4.3: Argo Events

**Goal:** Event-driven triggers wire the platform together. Git webhook → Argo Workflow. Harbor image push → security scan. MLflow model registered → promotion PR opens. The platform reacts instantly to events rather than polling.

> **Why this matters:** Without Argo Events, the Argo family is half a story. ArgoCD polls Git every 3 minutes (configurable but inherently lag-prone). With Argo Events, a PR merge fires a webhook that triggers a Workflow that triggers an ArgoCD sync — end-to-end latency drops from minutes to seconds. For Tier 5 MLOps, this means "model registered → deployment PR opens automatically" rather than "model registered, wait 5 minutes for polling."

#### 4.3a — Install Argo Events

```yaml
# homelab-gitops/apps/argo-events/argocd-app.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: argo-events
  namespace: argocd
spec:
  source:
    repoURL: https://argoproj.github.io/argo-helm
    chart: argo-events
    targetRevision: 2.4.x
  destination:
    server: https://homelab-prod-api.homelab.local
    namespace: argo-events
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

Installs three CRDs: `EventBus`, `EventSource`, `Sensor`. Mental model:
- **EventBus** — the message broker (NATS-backed) that decouples sources from sensors
- **EventSource** — defines what events to listen for (webhooks, schedules, message queues)
- **Sensor** — defines what to do when matched events arrive (submit Workflow, create resource, trigger HTTP call)

#### 4.3b — EventBus

One shared EventBus in `argo-events` namespace, NATS streaming under the hood:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: EventBus
metadata:
  name: default
  namespace: argo-events
spec:
  nats:
    native:
      replicas: 3
      auth: token
      persistence:
        storageClassName: nfs-csi
        size: 1Gi
```

3 replicas tolerate one NATS pod loss without dropping events.

#### 4.3c — Foundational EventSources

**GitHub webhook source** (or Forgejo once it's deployed, which has a compatible webhook payload):

```yaml
apiVersion: argoproj.io/v1alpha1
kind: EventSource
metadata:
  name: github
  namespace: argo-events
spec:
  service:
    ports:
      - port: 12000
        targetPort: 12000
  github:
    homelab-gitops-push:
      repositories:
        - owner: dalton
          names: [homelab-gitops]
      webhook:
        endpoint: /push
        port: "12000"
        method: POST
        url: https://argo-events-webhook.homelab.local
      events: [push, pull_request]
      apiToken:
        name: github-webhook-token
        key: token   # ESO-synced from Vault
      insecure: false
      active: true
```

The webhook URL is exposed via a Gateway API HTTPRoute with TLS. GitHub posts to it on push/PR events.

**Harbor webhook source** (image push triggers):

```yaml
apiVersion: argoproj.io/v1alpha1
kind: EventSource
metadata:
  name: harbor
  namespace: argo-events
spec:
  webhook:
    image-pushed:
      endpoint: /harbor/push
      port: "12000"
      method: POST
```

Configure Harbor (Projects → your project → Webhooks) to POST to `https://argo-events-webhook.homelab.local/harbor/push` on `PUSH_ARTIFACT` event.

**MLflow registry source** (for Tier 5):

MLflow doesn't have native webhooks as of mid-2026. Adapter pattern: a small Python service polls the MLflow registry API every 60s and emits Argo Events when transitions occur (registered → staging → production). Lives in `mlops-platform` namespace, ~80 lines of code.

#### 4.3d — Foundational Sensors

**Sensor: PR merged on homelab-gitops triggers platform tests**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Sensor
metadata:
  name: gitops-pr-merged
  namespace: argo-events
spec:
  template:
    serviceAccountName: argo-events-workflow-trigger
  dependencies:
    - name: dep
      eventSourceName: github
      eventName: homelab-gitops-push
      filters:
        data:
          - path: body.action
            type: string
            value: ["closed"]
          - path: body.pull_request.merged
            type: bool
            value: ["true"]
          - path: body.pull_request.base.ref
            type: string
            value: ["main"]
  triggers:
    - template:
        name: submit-platform-tests
        argoWorkflow:
          operation: submit
          source:
            resource:
              apiVersion: argoproj.io/v1alpha1
              kind: Workflow
              metadata:
                generateName: platform-tests-
                namespace: argo
              spec:
                workflowTemplateRef:
                  name: run-platform-tests
                arguments:
                  parameters:
                    - name: pr-number
                      value: "{{ .Input.body.number }}"
                    - name: pr-author
                      value: "{{ .Input.body.pull_request.user.login }}"
```

**Sensor: Harbor image push triggers vulnerability scan**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Sensor
metadata:
  name: harbor-push-scan
  namespace: argo-events
spec:
  dependencies:
    - name: dep
      eventSourceName: harbor
      eventName: image-pushed
      filters:
        data:
          - path: body.type
            type: string
            value: ["PUSH_ARTIFACT"]
  triggers:
    - template:
        name: trigger-trivy-scan
        argoWorkflow:
          operation: submit
          source:
            resource:
              apiVersion: argoproj.io/v1alpha1
              kind: Workflow
              metadata:
                generateName: trivy-scan-
              spec:
                workflowTemplateRef:
                  name: trivy-scan-image
                arguments:
                  parameters:
                    - name: image
                      value: "{{ .Input.body.event_data.resources[0].resource_url }}"
```

#### 4.3e — Pattern catalog (document in repo)

Document the wired event patterns in `homelab-gitops/docs/event-patterns.md`. Each entry: trigger, source, action, owner.

Initial catalog:
- PR merged on `homelab-gitops` → platform test workflow
- Harbor image pushed → Trivy scan workflow
- (Tier 5) MLflow model `staging` → open promotion PR
- (Tier 5) MLflow model `production` → trigger Argo Rollouts canary on homelab-prod

Each new sensor added in PR form, with the catalog updated.

#### 4.3f — Security: who can write Sensors?

Sensors can submit arbitrary Workflows. RBAC tight:
- ClusterRole `argo-events-sensor-admin` (full Sensor CRUD) restricted to `mlops-admins` group
- Tenant users cannot create Sensors in their own namespaces
- The webhook endpoint authenticates incoming requests via shared secret (Vault-managed) for GitHub, signed payloads for Harbor

#### Verification

- [ ] Argo Events installed; CRDs `EventBus`, `EventSource`, `Sensor` present
- [ ] EventBus `default` running with 3 NATS replicas
- [ ] GitHub webhook: open + close a test PR on a fork of `homelab-gitops` → Sensor `gitops-pr-merged` triggers → Workflow created
- [ ] Harbor webhook: push a test image → Sensor `harbor-push-scan` triggers → Trivy scan Workflow runs and reports results
- [ ] Cross-namespace authorization: Sensor in `argo-events` can submit Workflows in `argo` (service account binding works)
- [ ] RBAC: a `data-scientist` Keycloak user cannot create Sensors anywhere
- [ ] EventBus tolerance: kill one NATS pod, events still flow

---

### Phase 4.4: Declarative Keycloak Realm via Terraform

**Goal:** What was bootstrapped manually in Tier 3 Phase 3.13c becomes code. Future realm changes go through PR.

#### 4.4a — Terraform setup

New environment in `homelab-terraform/environments/keycloak/`:

```hcl
terraform {
  required_providers {
    keycloak = {
      source  = "mrparkers/keycloak"
      version = "~> 4.4"
    }
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.4"
    }
  }
}

# Auth Vault first (same AppRole pattern as Tier 1)
provider "vault" {
  address = "https://vault.homelab.internal:8200"
  auth_login {
    path = "auth/approle/login"
    parameters = {
      role_id   = var.vault_role_id
      secret_id = var.vault_secret_id
    }
  }
}

# Read Keycloak admin from Vault
data "vault_kv_secret_v2" "keycloak_admin" {
  mount = "secret"
  name  = "mgmt/keycloak/admin"
}

provider "keycloak" {
  client_id     = "admin-cli"
  username      = data.vault_kv_secret_v2.keycloak_admin.data["user"]
  password      = data.vault_kv_secret_v2.keycloak_admin.data["password"]
  url           = "https://keycloak.mgmt.homelab.internal"
  initial_login = false
}
```

#### 4.4b — Realm, groups, clients as code

```hcl
resource "keycloak_realm" "homelab" {
  realm        = "homelab"
  enabled      = true
  display_name = "Homelab"

  password_policy = "upperCase(1) and length(12) and notUsername"

  registration_allowed         = false
  reset_password_allowed       = true
  remember_me                  = true
  verify_email                 = false
  login_with_email_allowed     = true

  access_token_lifespan         = "30m"
  sso_session_idle_timeout      = "8h"
  sso_session_max_lifespan      = "24h"
  offline_session_idle_timeout  = "30d"
}

resource "keycloak_group" "admin" {
  realm_id = keycloak_realm.homelab.id
  name     = "homelab-admin"
}

resource "keycloak_group" "reader" {
  realm_id = keycloak_realm.homelab.id
  name     = "homelab-reader"
}

# Clients — declarative versions of what we built in the UI
resource "keycloak_openid_client" "argocd" {
  realm_id              = keycloak_realm.homelab.id
  client_id             = "argocd"
  name                  = "ArgoCD"
  access_type           = "CONFIDENTIAL"
  standard_flow_enabled = true
  valid_redirect_uris   = ["https://argocd.homelab-prod.homelab.internal/auth/callback"]
}

# Repeat for grafana, harbor, vault, and any future client
# ... (omitted for brevity)

# Group claim mapper — sends "groups" in tokens so apps can role-map
resource "keycloak_generic_client_protocol_mapper" "groups" {
  for_each = toset([
    keycloak_openid_client.argocd.id,
    # ... other clients
  ])
  realm_id        = keycloak_realm.homelab.id
  client_id       = each.value
  name            = "groups"
  protocol        = "openid-connect"
  protocol_mapper = "oidc-group-membership-mapper"
  config = {
    "claim.name"           = "groups"
    "full.path"            = "false"
    "id.token.claim"       = "true"
    "access.token.claim"   = "true"
    "userinfo.token.claim" = "true"
  }
}
```

#### 4.4c — Import existing state

Critical step — we manually created clients in Tier 3. Terraform must import them rather than recreate:

```bash
source ../../scripts/vault-login.sh
terraform init
terraform import keycloak_realm.homelab homelab
terraform import keycloak_openid_client.argocd homelab/<client-uuid-from-keycloak-ui>
terraform import keycloak_openid_client.grafana homelab/<client-uuid>
# ... etc

terraform plan   # should show no changes after all imports
```

#### Verification

- [ ] `terraform plan` shows no drift after import
- [ ] Make a trivial change (e.g., update a redirect URI), `terraform apply`, verify in Keycloak UI
- [ ] OIDC logins to all 4 apps still work after the apply

---

### Phase 4.5: Custom OTel App — End-to-End Production Story

**Goal:** A simple HTTP service you wrote yourself that exercises *the entire stack* — Harbor (signed images), CloudNativePG (database), Vault (dynamic credentials), cert-manager (TLS), Cilium Gateway (ingress), Tempo (traces), Prometheus (metrics), Loki (logs), Argo Rollouts (canary), Sloth (SLOs), Kyverno (policy verification). This is the demo.

#### 4.5a — The app itself

Pick a domain. Suggestions:
- **URL shortener** — simple, demonstrates everything, useful
- **Feature flag service** — slightly more interesting, exercises read-heavy patterns
- **Tiny webhook receiver** — sit between Renovate/GitHub and other systems

Whichever you pick:
- **Language:** Go (smallest image, instrumentation is easy with `otelhttp`)
- **Endpoints:** `GET /healthz`, `GET /readyz`, `GET /metrics` (Prometheus format), `POST /` and `GET /:id` (or whatever the domain needs)
- **Storage:** Postgres via CloudNativePG-issued credentials
- **Observability:** OTel SDK initialized at startup, traces to `tempo-otlp.mgmt.homelab.internal:4318`, metrics scraped by Alloy ServiceMonitor

Skeleton structure:

```
hello-otel/
├── cmd/server/main.go              # entrypoint
├── internal/
│   ├── api/                         # HTTP handlers
│   ├── db/                          # Postgres queries
│   └── observability/               # OTel init
├── Dockerfile                       # multi-stage, distroless final
├── .github/workflows/
│   └── release.yaml                 # CI: build → sign → push to Harbor
└── README.md
```

#### 4.5b — CI pipeline (GitHub Actions, runs on self-hosted runners in Phase 4.6)

```yaml
# .github/workflows/release.yaml
name: build-and-release
on:
  push:
    tags: ['v*']
jobs:
  release:
    runs-on: [self-hosted, homelab]
    permissions: { id-token: write, contents: read }
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-buildx-action@v3
      - name: Login to Harbor
        uses: docker/login-action@v3
        with:
          registry: harbor.homelab-prod.homelab.internal
          username: ${{ secrets.HARBOR_ROBOT_USER }}
          password: ${{ secrets.HARBOR_ROBOT_TOKEN }}
      - name: Build
        run: |
          docker build -t harbor.homelab-prod.homelab.internal/apps/hello-otel:${{ github.ref_name }} .
          docker push  harbor.homelab-prod.homelab.internal/apps/hello-otel:${{ github.ref_name }}
      - name: Sign with Cosign + Vault Transit
        env:
          VAULT_ADDR: https://vault.homelab.internal:8200
        run: |
          # Runner has VAULT_TOKEN env set via the harness; AppRole auth done before this step
          cosign sign --key hashivault://transit/keys/cosign-harbor \
            harbor.homelab-prod.homelab.internal/apps/hello-otel:${{ github.ref_name }}
      - name: Generate SBOM
        run: |
          syft harbor.homelab-prod.homelab.internal/apps/hello-otel:${{ github.ref_name }} \
            -o cyclonedx-json > sbom.json
          cosign attest --predicate sbom.json --type cyclonedx --key hashivault://transit/keys/cosign-harbor \
            harbor.homelab-prod.homelab.internal/apps/hello-otel:${{ github.ref_name }}
```

> **What this pipeline demonstrates:** Build → sign with key never on the runner → generate SBOM → attest SBOM. Every defense-industry supply-chain checkbox. The SBOM lives alongside the image as an attestation; Kyverno verifies it in Phase 4.15.

#### 4.5c — Kubernetes manifests (`apps/hello-otel/base/`)

The Rollout (replacing what would be a Deployment):

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata: { name: hello-otel }
spec:
  replicas: 3
  selector: { matchLabels: { app: hello-otel } }
  template:
    metadata: { labels: { app: hello-otel } }
    spec:
      serviceAccountName: hello-otel
      containers:
        - name: app
          image: hello-otel:placeholder   # replaced by kustomize overlay
          ports: [{ containerPort: 8080, name: http }]
          env:
            - name: OTEL_EXPORTER_OTLP_ENDPOINT
              value: "https://tempo-otlp.mgmt.homelab.internal:4318"
            - name: PG_HOST
              value: hello-otel-postgres-rw.${NAMESPACE}.svc
            - name: PG_USER
              valueFrom: { secretKeyRef: { name: hello-otel-postgres-app, key: username } }
            - name: PG_PASSWORD
              valueFrom: { secretKeyRef: { name: hello-otel-postgres-app, key: password } }
          resources:
            requests: { cpu: 50m, memory: 128Mi }
            limits:   { memory: 256Mi }
          securityContext:
            runAsNonRoot: true
            runAsUser: 65532
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: [ALL] }
  strategy:
    canary:
      steps:
        - setWeight: 10
        - pause: { duration: 2m }
        - analysis:
            templates:
              - templateName: hello-otel-success-rate
            args:
              - name: service
                value: hello-otel
              - name: namespace
                valueFrom: { fieldRef: { fieldPath: metadata.namespace } }
        - setWeight: 50
        - pause: { duration: 2m }
        - analysis:
            templates:
              - templateName: hello-otel-success-rate
        - setWeight: 100
      trafficRouting:
        # Cilium Gateway via HTTPRoute weighted backends
        plugins:
          argoproj-labs/gatewayAPI:
            httpRoute: hello-otel
            namespace: ${NAMESPACE}
```

The AnalysisTemplate that drives canary success/abort:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata: { name: hello-otel-success-rate }
spec:
  args:
    - name: service
    - name: namespace
  metrics:
    - name: success-rate
      interval: 30s
      successCondition: result[0] >= 0.99
      failureLimit: 2
      provider:
        prometheus:
          address: https://prometheus.mgmt.homelab.internal
          query: |
            sum(rate(http_requests_total{
              service="{{args.service}}",
              namespace="{{args.namespace}}",
              code!~"5.."
            }[1m]))
            /
            sum(rate(http_requests_total{
              service="{{args.service}}",
              namespace="{{args.namespace}}"
            }[1m]))
    - name: p99-latency
      interval: 30s
      successCondition: result[0] <= 0.5     # 500ms p99
      failureLimit: 2
      provider:
        prometheus:
          address: https://prometheus.mgmt.homelab.internal
          query: |
            histogram_quantile(0.99,
              sum(rate(http_request_duration_seconds_bucket{
                service="{{args.service}}",
                namespace="{{args.namespace}}"
              }[1m])) by (le)
            )
```

#### 4.5d — Per-app SLO

```yaml
apiVersion: sloth.slok.dev/v1
kind: PrometheusServiceLevel
metadata: { name: hello-otel-slo, namespace: hello-prod }
spec:
  service: "hello-otel"
  labels: { tier: "application" }
  slos:
    - name: "availability"
      objective: 99.5
      sli:
        events:
          error_query: 'sum(rate(http_requests_total{service="hello-otel",namespace="hello-prod",code=~"5.."}[5m]))'
          total_query: 'sum(rate(http_requests_total{service="hello-otel",namespace="hello-prod"}[5m]))'
      alerting:
        name: HelloOtelAvailabilityBurn
        page_alert: { labels: { severity: critical } }
```

#### Verification

- [ ] CI pipeline produces signed, attested images in Harbor
- [ ] Image pull from homelab-dev succeeds (Kyverno in audit mode logs the signature verification, sees it passes)
- [ ] App reachable at `https://hello.homelab-dev.homelab.internal` (dev)
- [ ] Traces visible in Tempo (Grafana Explore → Tempo data source → search by service `hello-otel`)
- [ ] Metrics visible in Prometheus, Alloy is scraping the ServiceMonitor
- [ ] Logs visible in Loki, filtered to `{cluster="homelab-dev",namespace="hello-dev"}`
- [ ] Trigger a deploy: push a new tag, watch the Rollout walk through canary steps, see analysis succeed
- [ ] Trigger an *unhealthy* deploy (introduce a deliberate 500 error): canary aborts, traffic stays on stable, Discord alert fires

---

### Phase 4.6: ARC (Actions Runner Controller)

**Goal:** Self-hosted GitHub runners on homelab-dev, scaled on demand, pulling images from Harbor.

> **Why homelab-dev not homelab-prod:** CI is a dev-tier concern. Don't burn prod resources on builds. Runners run on homelab-dev; the artifacts they push land in Harbor on homelab-prod.

#### 4.6a — ARC install

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: { name: arc-controller, namespace: argocd }
spec:
  destination: { name: homelab-dev, namespace: arc-systems }
  source:
    repoURL: ghcr.io/actions/actions-runner-controller-charts
    chart: gha-runner-scale-set-controller
    targetRevision: 0.x
```

#### 4.6b — Runner scale set per repo

```yaml
apiVersion: actions.github.com/v1alpha1
kind: AutoscalingRunnerSet
metadata: { name: homelab-runners, namespace: arc-runners }
spec:
  githubConfigUrl: https://github.com/yourorg/homelab-gitops
  githubConfigSecret: arc-github-creds   # ESO from Vault (GitHub App credentials)
  maxRunners: 4
  minRunners: 1
  containerMode: { type: dind }
  template:
    spec:
      containers:
        - name: runner
          image: harbor.homelab-prod.homelab.internal/dockerhub/actions/runner:latest
          env:
            - name: VAULT_ADDR
              value: https://vault.homelab.internal:8200
          # AppRole credentials for Vault-Cosign signing — short-lived
          envFrom:
            - secretRef: { name: runner-vault-approle }
```

The `runner-vault-approle` secret carries an AppRole bound to a `ci-signer` Vault policy:

```hcl
# Vault policy: ci-signer
path "transit/sign/cosign-harbor"   { capabilities = ["create", "update"] }
path "transit/verify/cosign-harbor" { capabilities = ["create", "update"] }
```

> **AppRole TTL = 4h**, force re-issue from Vault for long-running CI. If runners get compromised, the blast window is bounded.

#### Verification

- [ ] Runner pods appear in `arc-runners` namespace on homelab-dev when a workflow needs them
- [ ] Pushing a tag to `hello-otel` triggers the release workflow on a self-hosted runner
- [ ] Signed image lands in Harbor, signature verifiable

---

### Phases 4.7–4.11: The Application Suite

Each follows the same pattern: Helm chart (proxied through Harbor) → values file in `apps/<name>/base/` → Kustomize overlay for prod (and dev if applicable) → Postgres via CloudNativePG where needed → ESO for any secrets → HTTPRoute via Cilium Gateway → OIDC client in Keycloak.

I'll keep these phases tight — the pattern is established.

#### 4.6 — Vaultwarden (prod-only on homelab-prod)

- Single replica, Postgres via CNPG
- Hostname: `vault-pwd.homelab-prod.homelab.internal` (avoid `vault.` conflict with HashiCorp Vault)
- Admin token in Vault KV, materialized via ESO
- OIDC integration optional (Vaultwarden has limited SSO support; not worth wiring)
- Daily Velero backup; restore drill documented

#### 4.7 — n8n (prod-only on homelab-prod)

- Helm chart from the [n8n community charts](https://github.com/8gears/n8n-helm-chart)
- Postgres via CNPG, persistent storage for workflow data
- OIDC via Keycloak (enterprise feature; on community version use header auth + a placeholder)
- Useful early workflow: monitor Renovate PRs, auto-approve patches that pass Kyverno verification

#### 4.8 — NetBox (prod-only on homelab-prod)

- Postgres via CNPG + Redis (CNPG doesn't do Redis — use Bitnami Redis chart)
- OIDC via Keycloak (NetBox natively supports it through python-social-auth)
- **Seed the inventory:** import all VLANs, subnets, racks (just the one), and devices (everything in your IP allocation table from Tier 0). NetBox becomes source of truth for IPAM going forward.
- Bonus: configure Ansible to use NetBox as a dynamic inventory source — closes the loop on "NetBox documents real infrastructure"

#### 4.9 — Forgejo (prod-only on homelab-prod)

- Postgres via CNPG, NFS for repo storage
- OIDC via Keycloak
- Configure **GitHub mirroring** for the three homelab repos (`homelab-gitops`, `homelab-ansible`, `homelab-terraform`)
- Now you have offline-resilient copies of every repo your platform depends on. The defense-grade air-gap pattern: if GitHub disappears tomorrow, the homelab keeps running.

> **Pull-through mirror is one-way (GitHub → Forgejo)**, not a fork. ArgoCD and Flux continue pulling from GitHub. Forgejo is a read-only failsafe. If GitHub goes down, you re-point ArgoCD/Flux to Forgejo as the source. Add this as a runbook.

#### 4.10 — Immich (prod-only on homelab-prod; the storage stress test)

- Heavy: Postgres + Redis + ML processing
- NFS-mounted storage for the photo library (could be huge — set a realistic ZFS quota)
- OIDC via Keycloak
- Mobile apps point at `https://photos.homelab-prod.homelab.internal`
- **Why this is in v4:** Real workload that exercises NFS storage at scale, CPU-heavy ML processing, large object handling. Best chaos engineering target you'll have.

---

### Phase 4.12: k6-operator and Load-Testing Patterns

**Goal:** Distributed load tests defined as Kubernetes resources, results streamed to Prometheus, dashboards in Grafana. Run regular load tests against the hello-otel app and other workloads.

#### 4.12a — Install on homelab-dev only

Load testing belongs in the dev/staging tier. Don't load-test prod from inside prod.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: { name: k6-operator, namespace: argocd }
spec:
  destination: { name: homelab-dev, namespace: k6-operator-system }
  source:
    repoURL: https://grafana.github.io/helm-charts
    chart: k6-operator
    targetRevision: 3.x
```

#### 4.12b — Test script lives in gitops repo

```javascript
// apps/hello-otel/load-tests/baseline.js
import http from 'k6/http';
import { check, sleep } from 'k6';

export const options = {
  scenarios: {
    ramp_up: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '2m', target: 100 },   // ramp to 100 VUs
        { duration: '5m', target: 100 },   // hold
        { duration: '2m', target: 0 },     // ramp down
      ],
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.01'],          // < 1% errors
    http_req_duration: ['p(95)<500'],        // 95th percentile < 500ms
  },
};

export default function () {
  const target = __ENV.TARGET || 'https://hello.homelab-dev.homelab.internal';
  const r = http.post(`${target}/`, JSON.stringify({ url: 'https://example.com/long-url' }), {
    headers: { 'Content-Type': 'application/json' },
  });
  check(r, { 'status is 201': (r) => r.status === 201 });
  sleep(1);
}
```

#### 4.12c — TestRun CRD

```yaml
apiVersion: k6.io/v1alpha1
kind: TestRun
metadata: { name: hello-otel-baseline, namespace: k6-tests }
spec:
  parallelism: 4   # distributed across 4 pods
  script:
    configMap: { name: hello-otel-baseline-script, file: baseline.js }
  arguments: --out experimental-prometheus-rw
  runner:
    env:
      - name: K6_PROMETHEUS_RW_SERVER_URL
        value: https://prometheus.mgmt.homelab.internal/api/v1/write
      - name: K6_PROMETHEUS_RW_TREND_STATS
        value: "p(95),p(99),min,max"
      - name: TARGET
        value: "https://hello.homelab-dev.homelab.internal"
```

After the run completes, metrics (`k6_http_req_duration`, `k6_http_reqs`) are queryable in Grafana. Pre-import the [k6 Grafana dashboard](https://grafana.com/grafana/dashboards/19665) for visualization.

#### Verification

- [ ] Baseline test runs successfully, metrics appear in Prometheus
- [ ] k6 dashboard in Grafana populates
- [ ] During load test, application Tempo traces show increased volume, hello-otel SLO recording rules update

---

### Phase 4.13: Chaos Mesh + Combined Chaos+Load Tests

**Goal:** Chaos experiments run on homelab-dev (never on homelab-prod). Combined with k6 load tests to simulate "load + something goes wrong simultaneously" — the most realistic production stress.

#### 4.13a — Install on homelab-dev only

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: { name: chaos-mesh, namespace: argocd }
spec:
  destination: { name: homelab-dev, namespace: chaos-mesh }
  source:
    repoURL: https://charts.chaos-mesh.org
    chart: chaos-mesh
    targetRevision: 2.x
    helm:
      values: |-
        dashboard:
          create: true
          securityMode: false   # for homelab; production should use authenticated dashboard
```

#### 4.13b — Three starter experiments

**PodChaos — random pod kill:**

```yaml
apiVersion: chaos-mesh.org/v1alpha1
kind: PodChaos
metadata: { name: hello-otel-pod-kill, namespace: chaos-mesh }
spec:
  action: pod-kill
  mode: one
  selector:
    namespaces: [hello-dev]
    labelSelectors: { app: hello-otel }
  scheduler:
    cron: "@every 5m"     # one pod dies every 5 minutes
```

**NetworkChaos — induce latency:**

```yaml
apiVersion: chaos-mesh.org/v1alpha1
kind: NetworkChaos
metadata: { name: hello-otel-latency, namespace: chaos-mesh }
spec:
  action: delay
  mode: all
  selector:
    namespaces: [hello-dev]
    labelSelectors: { app: hello-otel }
  delay: { latency: "100ms", jitter: "50ms" }
  duration: "5m"
```

**IOChaos — disk latency (Immich is a great target):**

```yaml
apiVersion: chaos-mesh.org/v1alpha1
kind: IOChaos
metadata: { name: immich-disk-slow, namespace: chaos-mesh }
spec:
  action: latency
  mode: one
  selector:
    namespaces: [immich-dev]   # if you stand one up in homelab-dev
    labelSelectors: { app: immich }
  volumePath: /usr/src/app/upload
  path: "**"
  delay: "200ms"
  duration: "10m"
```

#### 4.13c — Combined test ritual

The "production stress simulation" — schedule a k6 TestRun and a Chaos experiment to overlap:

1. Start k6 ramp-up (2 min)
2. At t+3min (during hold phase), trigger PodChaos pod-kill experiment
3. Observe: does the canary stability hold? Do circuit breakers engage? Does the SLO burn-rate alert fire?
4. After test: compare baseline metrics vs chaos metrics, document findings

> **The defense-industry framing:** Real workloads don't fail in isolation. They fail under load. Combining k6 + Chaos Mesh is how you get realistic resilience data without paying for fault-injection-as-a-service. ADR-worthy: "We treat resilience as a measurable property, exercised quarterly."

#### Verification

- [ ] Chaos Mesh dashboard reachable
- [ ] All three experiments can be triggered manually
- [ ] Combined chaos+load test demonstrates: pod kills don't break the canary, latency injection shows up in Tempo traces, SLO burn-rate alert fires when load + chaos exceed acceptable bounds

---

### Phase 4.14: Velero + Documented DR Drill

**Goal:** Velero on every cluster, scheduled daily backups to Garage S3, AND a documented + executed DR drill that proves the backups actually work.

> **Backups are theater until they're restored.** This phase is the only one where you intentionally destroy something to prove you can rebuild it.

#### 4.14a — Velero install per cluster

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: { name: velero, namespace: argocd }
spec:
  destination: { name: in-cluster, namespace: velero }
  source:
    repoURL: https://vmware-tanzu.github.io/helm-charts
    chart: velero
    targetRevision: 7.x
    helm:
      values: |-
        configuration:
          backupStorageLocation:
            - name: garage
              provider: aws
              bucket: velero-backups-homelab-prod   # rename per cluster
              config:
                region: garage
                s3ForcePathStyle: "true"
                s3Url: http://garage-01.homelab.internal:3900
          volumeSnapshotLocation:
            - name: garage
              provider: aws
        credentials:
          existingSecret: velero-garage-creds   # ESO from Vault
        initContainers:
          - name: velero-plugin-for-aws
            image: harbor.homelab-prod.homelab.internal/dockerhub/velero/velero-plugin-for-aws:v1.10.x
            volumeMounts: [{ name: plugins, mountPath: /target }]
```

#### 4.14b — Schedule daily backups

```yaml
apiVersion: velero.io/v1
kind: Schedule
metadata: { name: daily-full, namespace: velero }
spec:
  schedule: "0 3 * * *"     # 3am
  template:
    storageLocation: garage
    ttl: "720h"             # 30 days
    includeClusterResources: true
    snapshotVolumes: true
```

#### 4.14c — The DR drill (run quarterly)

Document in `homelab-gitops/docs/runbooks/dr-drill.md`:

```markdown
# Quarterly DR Drill

**Last completed:** [date]
**Next due:** [date + 90 days]

## Procedure

1. Pick a non-critical namespace on homelab-dev (e.g., `hello-dev`)
2. Take a fresh backup: `velero backup create dr-drill-$(date +%Y%m%d) --include-namespaces hello-dev`
3. Wait for completion: `velero backup describe dr-drill-...`
4. **Destroy:** `kubectl --context homelab-dev delete namespace hello-dev`
5. Confirm complete deletion (Postgres CR gone, PVCs gone, all resources gone)
6. Start a timer. Restore: `velero restore create --from-backup dr-drill-...`
7. Wait for restore completion
8. Verify hello-dev fully functional (app reachable, Postgres data intact via test query, traces resume)
9. **Stop the timer.** That's your RTO.
10. Compare last successful health check time vs the data state in restored Postgres. The gap is your RPO.

## Last drill results

| Date       | RTO    | RPO    | Notes                                          |
| ---------- | ------ | ------ | ---------------------------------------------- |
| 2026-MM-DD | 14 min | 22h    | Backup was from 3am; drill ran at 1pm           |
| ...        |        |        |                                                |

## Improvement actions from last drill

- ...
```

> **What "RTO 14 min, RPO 22h" tells you:** Recovery takes 14 minutes once you start. Data loss can be up to 22 hours (the time since last backup). If RPO is unacceptable, increase backup frequency or add point-in-time recovery (CNPG WAL archiving handles that — you already have it). Stating these numbers is the whole point — you can't improve what you don't measure.

#### Verification

- [ ] Daily schedule running on every cluster, backups appearing in Garage
- [ ] Initial DR drill completed for hello-dev with RTO and RPO documented
- [ ] CNPG continuous WAL archiving enabled — verify by checking that WAL files appear in Garage in addition to base backups
- [ ] Runbook committed to gitops repo with results table

---

### Phase 4.15: Kyverno Audit → Enforce Migration

**Goal:** Every policy seeded in Tier 2 Phase 2.13 moves from `validationFailureAction: Audit` to `Enforce`, with documented exemptions for cases where enforcement breaks legitimate workloads.

#### Migration ritual per policy

1. Pull recent PolicyReports: `kubectl get polr -A -o json | jq '.items[] | select(.results[].result == "fail")'`
2. Categorize violations:
   - **Real misconfigurations** — fix the workload
   - **Legitimate exceptions** — add namespace exemption to the policy
3. Update policy: `validationFailureAction: Enforce`
4. Commit and let ArgoCD/Flux roll it out
5. Watch for new admission failures over the next 24 hours; address fast

#### Required exemptions (known cases)

- `kube-system`, `cilium-system`, `kyverno`, `external-secrets`, `cert-manager`, `argo-rollouts` — system namespaces often need elevated privileges and/or images from upstream (not Harbor) during bootstrap
- `velero` — needs cluster-wide permissions for backups

Add to each policy spec:

```yaml
exclude:
  any:
    - resources:
        namespaces: [kube-system, cilium-system, kyverno, external-secrets, cert-manager, argo-rollouts, velero]
```

#### One policy that *must* be enforced last: `require-image-signature`

Until every workload pulls signed images, enforcement breaks deployments. Sequence:

1. Confirm hello-otel (the only app you control end-to-end) has signed images via the CI pipeline
2. Add exemption list for "upstream charts that don't sign yet" — most public Helm charts don't push signatures
3. Switch the policy to enforce
4. Track the exemption list as technical debt — every time a chart vendor starts signing, remove the exemption

> **The honest scope call:** v4 will not have signature verification enforced on every image. The defense-industry pattern is to maintain a vendor allow-list of trusted unsigned-image sources alongside the signed-image enforcement. Document the list, work to shrink it over time. That posture is realistic and demonstrates real engineering judgment.

---

### Phase 4.16: Carryover Items From Earlier Tiers

A handful of items were deferred during tier construction. Address now or document as long-term TODOs:

- **Vault listener cert auto-rotation** (deferred from Tier 2 Phase 2.5) — write the systemd timer + pull script on each Vault VM, or rotate manually every 28 days. Calendar-pinned.
- **Egress firewall enforcement for air-gap** (deferred from Tier 2 Phase 2.10) — add VyOS firewall rules blocking VLANs 50/60 from initiating connections to docker.io, quay.io, ghcr.io, gcr.io, registry.k8s.io. FQDN-based blocking in VyOS is fiddly; an alternative is to deploy an explicit Squid proxy on bgp-01/bgp-02 that only allows Harbor and Cloudflare DNS.
- **Mobile root CA install** — install homelab root CA cert on your phone so mobile access to internal services doesn't warn about untrusted certificates.
- **DNS sprawl threshold** — if you've crossed ~20 hostname entries on VyOS, time to deploy CoreDNS as a platform service.
- **Keycloak realm declarative migration** — confirmed in Phase 4.4; verify drift-free state.

---

### Phase 4.17: Tier 4 Verification Gate

#### Delivery primitives

- [ ] Argo Rollouts controller on homelab-prod and homelab-dev, dashboard reachable
- [ ] ApplicationSet pattern generating per-environment Applications for at least one app
- [ ] Keycloak realm declaratively managed, `terraform plan` shows no drift
- [ ] CI pipeline produces signed, attested images in Harbor
- [ ] Cosign verification works for signed images

#### Event-driven workflows

- [ ] Argo Events installed: EventBus running with 3 NATS replicas
- [ ] GitHub webhook EventSource live; test PR open/close fires the registered Sensor
- [ ] PR-merged Sensor successfully submits the platform-tests Workflow
- [ ] Harbor webhook configured and triggering Trivy scan workflows on image push
- [ ] RBAC verified: a `data-scientist` Keycloak user cannot create Sensors
- [ ] EventBus tolerates one NATS pod loss without dropping events

#### Custom app full stack

- [ ] hello-otel deployed to dev, staging, and prod via separate Applications
- [ ] Canary Rollout walks through analysis steps automatically
- [ ] Deliberate bad deploy aborts canary, traffic stays on stable
- [ ] Traces in Tempo, metrics in Prometheus, logs in Loki — all tagged with cluster + namespace
- [ ] SLO recording rules computing, burn-rate alerts configured

#### Personal apps (deferred)

- [ ] Vaultwarden, n8n, NetBox, Forgejo, Immich — *deferred to post-Tier-5*; not blocking Tier 4 completion
- [ ] When built post-Tier-5: each app deployed on homelab-prod, OIDC login works where supported, Velero backup verified, NetBox seeded with homelab inventory, Forgejo mirroring repos

#### CI runtime

- [ ] ARC runner scale set on homelab-dev, scales up on demand
- [ ] Self-hosted runners use Vault AppRole for Cosign signing

#### Resilience

- [ ] k6 baseline load test passes on hello-otel; metrics streaming to Prometheus
- [ ] Three Chaos Mesh experiments work (PodChaos, NetworkChaos, IOChaos)
- [ ] Combined chaos+load test executed at least once
- [ ] Velero on every cluster with daily schedules running
- [ ] Initial DR drill complete with RTO + RPO documented in the runbook

#### Policy

- [ ] All Kyverno policies moved to Enforce except documented exemptions
- [ ] Signature-verification policy in Enforce with vendor exemption list maintained
- [ ] No surprise admission failures over 7 consecutive days

#### Carryover items

- [ ] Vault listener cert rotation: implemented or calendar-pinned
- [ ] Egress firewall enforcement: implemented or documented as Phase 5 follow-up
- [ ] Mobile root CA installed
- [ ] Quarterly DR drill scheduled in calendar

---

### Phase 4.18: Closing Reflections

You're done. Or rather: the *foundation* is done. From this point, v4 stops being a build doc and starts being the substrate you ship on top of.

#### What v4 actually demonstrates

When you walk an interviewer through this, the talking points organize naturally by tier:

**Foundation (Tier 0).** "I run Vault as a platform substrate, not as an application. Three-node Raft cluster auto-unsealed via GCP KMS, with PKI/Transit/SSH/Database engines providing dynamic credentials, internal CA, encryption-as-a-service, and audited SSH OTPs. The substrate has its own redundant BGP routing fabric so it survives single hypervisor failures."

**Provisioning (Tier 1).** "Every VM and OS configuration is Vault-authenticated Terraform and Ansible. No long-lived credentials in tfvars, no encrypted YAML files, no `--ask-vault-pass`. RKE2 clusters with CIS profile, encryption-at-rest, audit policy, and Cilium with BGP control plane and WireGuard pod-to-pod encryption."

**Platform Services (Tier 2).** "Two-tier internal PKI with 24-hour leaf certificates auto-rotated by cert-manager. External Secrets Operator authenticates per-cluster via Kubernetes auth method. Self-hosted Harbor with Cosign signing using keys in Vault Transit — the key material never leaves Vault. Air-gap pattern on workload clusters demonstrates the Iron Bank style supply chain."

**Observability & Identity (Tier 3).** "Centralized LGTM stack with cross-cluster collection via Alloy. Falco + Tetragon for runtime security observability. Sloth-managed SLOs for the platform itself. Keycloak federates identity across every UI, with documented break-glass procedures because identity outages are real."

**Delivery (Tier 4).** "Progressive delivery via Argo Rollouts with Prometheus-driven canary analysis. Per-environment ApplicationSets with PR-gated promotion. Quarterly DR drills with measured RTO and RPO. Combined chaos engineering and load testing as a resilience exercise."

#### What v4 deliberately doesn't do

Worth being honest about scope:

- **Not multi-region.** Single physical site, two hypervisors. Real DR for site loss would require a remote target — Garage backup replication or offsite Velero target as Phase 5 work.
- **Not full air-gap.** Mgmt-plane pulls upstream for observability bootstrap. Egress firewall enforcement on workload clusters is documented but not strictly implemented yet.
- **Not FIPS or full STIG.** RKE2 CIS profile gets us close on the K8s layer. OS-level STIG hardening was scoped as "CIS-adjacent." Full STIG is achievable but the marginal effort wasn't worth it for homelab purposes.
- **Not HSM-backed.** Vault Transit keys are software-backed. Real defense environments back transit with HSMs (CloudHSM, Thales, YubiHSM). Pattern is identical; hardware is the upgrade.

These are honest gaps, not failures. Document them in ADRs and you have a roadmap for any future hardening pass.

#### Maintenance posture

The platform isn't "done" forever — it's done *for now*. Going forward:

- **Renovate** handles routine version bumps. Review weekly.
- **Quarterly:** DR drill, review Kyverno exemption list, rotate Vault recovery keys.
- **Monthly:** Review observability dashboards for newly-noisy alerts; tune burn rates.
- **Annually:** Audit IAM grants (GCP KMS service account scope), rotate the Cosign key, review SLO targets against actual reliability.

These are operations, not engineering. The engineering is done.

#### One last thing

Build the things on top of this that you actually want. Workflows in n8n that scratch real itches. Forgejo as your sandbox for projects you don't want on GitHub. Immich filled with the photos you care about preserving. The custom app, extended into something genuinely useful.

The whole point of a foundation is the buildings it lets you put up.

---

# Future Upgrades

Not part of v4 scope. Documented here so they don't get lost — and so the next engineer to read this repo (you in three months, or someone you're handing the keys to) sees where the platform was heading. Each item has a clear trigger: do this when X happens.

## vLLM Serving Runtime for KServe

**What it is:** A KServe-native serving runtime optimized for transformer-based language models. Implements paged attention and continuous batching — radically more efficient than naive HuggingFace transformers serving. The de facto LLM serving runtime as of 2026.

**Why later:** KServe ships with serving runtimes for scikit-learn, PyTorch, TensorFlow, ONNX, and a generic HuggingFace runtime out of the box. None of those need vLLM. vLLM matters specifically when LLM workloads emerge — fine-tuning a Llama variant, serving a quantized 7B model, building a retrieval-augmented generation endpoint.

**Trigger to revisit:** The friend (or any tenant) wants to serve an LLM at production scale. Symptoms: HuggingFace runtime is too slow under realistic concurrent load, or per-request GPU memory pressure is bad.

**Effort:** 1–2 evenings. Install the vLLM `ClusterServingRuntime`, point an `InferenceService` at it. KServe handles the integration.

```yaml
# Sketch
apiVersion: serving.kserve.io/v1alpha1
kind: ClusterServingRuntime
metadata:
  name: kserve-vllmserver
spec:
  supportedModelFormats:
    - name: huggingface
      version: "1"
  containers:
    - name: kserve-container
      image: harbor.homelab.local/kserve/vllm:v0.x
      args:
        - --model
        - "{{.Name}}"
        - --tensor-parallel-size
        - "1"
```

Pair with GPU-bearing nodes (homelab-prod node added later, or AWS burst cluster with `g5.xlarge`).

## Papermill for Parameterized Notebooks

**What it is:** A library + CLI that lets you execute Jupyter notebooks programmatically with injected parameters. Turns notebook cells into a reusable, parameterized pipeline step.

**Why it matters for v4 + Tier 5:** The MLOps platform has two worlds — JupyterHub (exploration) and Argo Workflows (production pipelines). Papermill bridges them. A data scientist builds an exploration notebook, parameterizes the inputs (dataset version, hyperparameters), and the same notebook becomes an Argo Workflow step that runs nightly. No "rewrite the notebook as a Python script" tax.

**Trigger to revisit:** First time someone says "I want to schedule my notebook" or "I want to run this notebook with a different input every week." That's the moment Papermill earns its place.

**Effort:** ~1 hour. Install Papermill in the JupyterHub image; write one Argo Workflow template that takes a notebook URL + parameters, executes via Papermill, uploads the resulting output notebook to Garage S3.

```yaml
# Argo WorkflowTemplate sketch
apiVersion: argoproj.io/v1alpha1
kind: WorkflowTemplate
metadata:
  name: run-notebook
spec:
  templates:
    - name: papermill
      inputs:
        parameters:
          - name: notebook-url
          - name: params-json
      container:
        image: harbor.homelab.local/jupyter/papermill-runner:latest
        command: [papermill]
        args:
          - "{{inputs.parameters.notebook-url}}"
          - "/output/result.ipynb"
          - "-y"
          - "{{inputs.parameters.params-json}}"
```

The output `result.ipynb` becomes a reproducible artifact — a paper trail of "this notebook, with these parameters, produced this result."

## Backstage Developer Portal

**What it is:** Spotify's open-source internal developer portal. Catalogs services, owners, docs, dependencies; scaffolds new projects from templates; surfaces ownership and on-call from one place. The de facto answer to "where do I go to find out anything about anything we run?"

**Why it's interesting:** For a 5-person MLOps team, Backstage is borderline overkill — that's enough people to keep service ownership in their heads. But it's *exactly* the kind of platform-engineering capability that demonstrates "you understand the platform layer beyond just CI/CD." Defense industry, FAANG, any platform team — Backstage on a resume is a strong signal.

**Why not in v4:** Backstage is itself a significant build. A real Backstage deployment is ~2–3 weekends of work to set up well: deploy + Postgres backend + GitHub auth + Catalog YAML + first scaffolder template + first TechDocs page. That's a tier in itself, with no operational payoff for v4's actual users.

**Trigger to revisit:** Either (a) the platform grows past ~10 services and service discovery becomes painful, or (b) you specifically want to build it as a portfolio piece. Both are valid.

**What a v4-style Backstage tier would include:**
- Phase B.1 — Backstage on homelab-mgmt (Postgres via CNPG, OIDC via Keycloak)
- Phase B.2 — Catalog: enumerate every service in homelab-gitops with `catalog-info.yaml`
- Phase B.3 — TechDocs: every service has a `docs/` folder rendered in Backstage
- Phase B.4 — Scaffolder: at least one template for "new MLOps tenant" that wires Keycloak group + namespaces + JupyterHub access in one PR
- Phase B.5 — Plugin: Argo CD, Argo Workflows, Grafana, Harbor all surfaced in service pages

**Effort estimate:** 3–4 weekends end-to-end if done thoroughly.

---

The list ends here intentionally. The temptation in a homelab is always to add one more thing — every new CNCF project, every emerging pattern, every "interesting" demo. v4 plus Tier 5 plus these three is already substantially more platform than five users need. Build it, run it, learn what actually hurts, then revisit this list with real evidence.
