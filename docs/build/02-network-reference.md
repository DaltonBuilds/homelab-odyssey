[← Docs index](../README.md) · **Operation Long Haul v5**

[← ADRs](01-adrs.md)  ·  [Tier 0 · Foundation →](tier-0-foundation.md)

---

## Network Architecture (Reference)

### VLAN plan

| VLAN | Subnet            | Purpose                                          |
| ---- | ----------------- | ------------------------------------------------ |
| 10   | 192.168.10.0/24   | Workstation / management                         |
| 40   | 192.168.40.0/24   | Platform tier (Proxmox, Vault, homelab-mgmt, NFS, Garage, BGP routers) |
| 50   | 192.168.50.0/24   | homelab-prod cluster (prod nodes + LB pool)        |
| 60   | 192.168.60.0/24   | homelab-dev cluster (dev/staging nodes + LB pool)      |
| 70   | 192.168.70.0/24   | Ephemeral clusters (pve-03/pve-04, disposable — ADR-004) *(v5.1)* |

> **Note on VLAN expansion:** v3 used a single workload VLAN (40). v4 separates platform from prod from dev/staging, mirroring how real shops carve impact-level / tenancy boundaries at L2. Your switch must support VLAN trunks to **every Proxmox host** (v5.2: that now includes the M920q/M920x #2 boxes carrying the prod-tier VLAN 50). Configure trunks before starting Tier 0.
>
> **v5.4 — two switches, one L2 domain.** The fabric is two managed UniFi switches: an upstream switch that feeds the home-office wall jacks, and an 8-port switch in the office. pve-09 lands on its own office jack rather than on the office switch, so **the trunk must be configured on both switches and on the inter-switch path** — VLANs 10/40/50/60 tagged end to end. A correct config on the office switch alone will leave pve-09 reachable on the native VLAN but silently missing 40/50, which surfaces much later as a VM that won't get an address. Verify the jack, not just the switch port.

### BGP ASN plan

| ASN    | Speaker             | Notes                                            |
| ------ | ------------------- | ------------------------------------------------ |
| 65000  | bgp-01, bgp-02 (VyOS) | iBGP between the two routers (full mesh, 2 peers) |
| 65001  | homelab-prod Cilium   | eBGP to bgp-01 and bgp-02                          |
| 65002  | homelab-dev Cilium        | eBGP to bgp-01 and bgp-02                          |
| 65003  | homelab-mgmt Cilium   | eBGP to bgp-01 and bgp-02 *(v5.1: was implicit — see Phase 2.1b)* |
| 65004  | ephemeral clusters    | eBGP, reused by whichever ephemeral cluster is live *(v5.1)* |

> **Why these ASNs:** Private ASN range is 64512–65534. Using 65000 as the routing-infrastructure ASN and incrementing for each cluster keeps the topology readable. iBGP within VyOS pair = same ASN; eBGP to clusters = different ASN.

### IP allocation

| Host / Component       | IP              | VLAN | Role                                    | Location           |
| ---------------------- | --------------- | ---- | --------------------------------------- | ------------------ |
| Workstation            | 192.168.10.77   | 10   | Daily driver                            | Physical           |
| pve-01 (M920 SFF)   | 192.168.40.50   | 40   | Hypervisor 1 (64GB, prod-adjacent)      | Physical           |
| pve-02 (M920x #1)  | 192.168.40.55   | 40   | Hypervisor 2 (32GB, dev/staging)        | Physical           |
| pve-03 (NUC)        | 192.168.40.56   | 40   | Hypervisor 3 — ephemeral capacity *(v5.1)* | Physical        |
| pve-04 (NUC)        | 192.168.40.57   | 40   | Hypervisor 4 — ephemeral capacity *(v5.1)* | Physical        |
| pve-05 (M920x #2)  | 192.168.40.58   | 40   | Hypervisor 5 (32GB, spare + quorum) *(v5.2)* | Physical        |
| pve-06 (M920q)      | 192.168.40.59   | 40   | Hypervisor 6 — hosts prod-cp-01 *(v5.2)* | Physical        |
| pve-07 (M920q)      | 192.168.40.64   | 40   | Hypervisor 7 — hosts prod-w-01 *(v5.2)*  | Physical        |
| pve-08 (M920q)      | 192.168.40.65   | 40   | Hypervisor 8 — hosts prod-w-02 *(v5.2)*  | Physical        |
| pve-09 (Tower)      | 192.168.40.66   | 40   | Hypervisor 9 — GPU + build + mgmt-02 *(v5.4)* | Physical   |
| bgp-01 (VyOS)           | 192.168.40.10   | 40   | BGP router, VRRP master                 | VM on pve-01    |
| bgp-02 (VyOS)           | 192.168.40.11   | 40   | BGP router, VRRP backup                 | VM on pve-02    |
| bgp-vrrp (virtual)     | 192.168.40.1    | 40   | VRRP virtual IP — VLAN 40 gateway       | Floats bgp-01↔bgp-02 |
| vault-01 (Vault)       | 192.168.40.20   | 40   | Vault HA node 1 (Raft leader candidate) | VM on pve-01    |
| vault-02 (Vault)       | 192.168.40.21   | 40   | Vault HA node 2                         | VM on **pve-05** *(v5.4: was pve-01)* |
| vault-03 (Vault)       | 192.168.40.22   | 40   | Vault HA node 3                         | VM on pve-02    |
| nfs-01             | 192.168.40.51   | 40   | NFS + ZFS persistent storage            | VM on pve-01    |
| garage-01              | 192.168.40.53   | 40   | S3-compatible object storage            | LXC on pve-01   |
| mgmt-01 (mgmt CP)       | 192.168.40.60   | 40   | homelab-mgmt control plane                | VM on pve-01    |
| mgmt-02 (mgmt CP)    | 192.168.40.61   | 40   | homelab-mgmt control plane                | VM on **pve-09** *(v5.4: was pve-01)* |
| mgmt-03 (mgmt CP)     | 192.168.40.62   | 40   | homelab-mgmt control plane                | VM on pve-02    |
| mgmt-api (virtual)    | 192.168.40.63   | 40   | homelab-mgmt HA VIP (Talos-managed) *(v5.1)* | Floats mgmt-01/02/03 |
| prod-cp-01 (homelab-prod)   | 192.168.50.30   | 50   | homelab-prod control plane                | VM on pve-06    |
| prod-w-01 (homelab-prod)   | 192.168.50.31   | 50   | homelab-prod worker 1                     | VM on pve-07    |
| prod-w-02 (homelab-prod)   | 192.168.50.32   | 50   | homelab-prod worker 2                     | VM on pve-08    |
| prod-w-03 (homelab-prod)     | 192.168.50.33   | 50   | homelab-prod worker 3                     | VM on pve-01    |
| prod-gpu-01 (homelab-prod) | 192.168.50.34   | 50   | homelab-prod GPU worker (tainted, RTX 5070 passthrough) *(v5.4)* | VM on pve-09 |
| dev-cp-01 (homelab-dev)        | 192.168.60.30   | 60   | homelab-dev control plane                     | VM on pve-02    |
| dev-w-01 (homelab-dev)          | 192.168.60.31   | 60   | homelab-dev worker 1                          | VM on pve-02    |
| dev-w-02 (homelab-dev)          | 192.168.60.32   | 60   | homelab-dev worker 2                          | VM on pve-02    |

> ### ✅ Failure-domain concentration — resolved *(v5.4; was an open decision from the v5.1 review)*
>
> **The original problem.** Through v5.3, the "Location" column read: **pve-01 hosts two of three Vault nodes *and* two of three mgmt control-plane nodes**, plus nfs-01, garage-01, bgp-01, and prod-w-03. Losing pve-01 didn't degrade the platform — it *stopped* it: OpenBao lost Raft quorum (1 of 3 left), homelab-mgmt lost etcd quorum (1 of 3 left), and all persistent storage vanished at once. Both "HA" clusters were HA in name only against their single largest failure mode. Two nodes on one box was unavoidable with two hypervisors; it stopped being unavoidable at v5.2, and v5.1–v5.3 left the fix as an explicit open decision.
>
> **The decision (ADR-011).** Split the two relocated quorum nodes across **two different** hosts:
>
> - **vault-02 → pve-05** (M920x #2, 32GB — ample headroom for one OpenBao node)
> - **mgmt-02 → pve-09** (the tower, 64GB, mirrored NVMe — good etcd storage and the most headroom in the fleet)
>
> The Location cells above are updated accordingly. This is **strictly better than the old "Option 1,"** which put both nodes on pve-05 and merely relocated the correlated-failure problem: with the split, no single hypervisor loss can break either quorum. Both quorums now tolerate any one host failure, and the NUCs (pve-03/04) stay pristine for ephemeral drills.
>
> **Post-mitigation failure analysis:**
>
> | Host lost | OpenBao Raft | homelab-mgmt etcd | Other impact |
> | --- | --- | --- | --- |
> | pve-01 | 2 of 3 — **quorum holds** | 2 of 3 — **quorum holds** | nfs-01 + garage-01 + bgp-01 + prod-w-03 down (storage outage; VRRP fails over to bgp-02) |
> | pve-05 | 2 of 3 — **quorum holds** | unaffected | none standing |
> | pve-09 | unaffected | 2 of 3 — **quorum holds** | prod-gpu-01 + build host down (no platform impact) |
> | pve-02 | 2 of 3 — **quorum holds** | 2 of 3 — **quorum holds** | homelab-dev entirely down; bgp-02 down |
>
> **What remains accepted, deliberately.** Storage is still a single point of failure: nfs-01 and garage-01 both live on pve-01 and neither is replicated, so a pve-01 loss is a storage outage even though both quorums survive it. This is fine for a lab — the Phase 1.11 snapshot DR covers the data — but it is now the *largest* remaining single-host blast radius, and pve-09's mirrored 2TB is the obvious future home for a Garage replica or a relocated nfs-01 (ADR-011 role 4). Revisit if a NAS is acquired.

### LoadBalancer pools (BGP-advertised)

| Pool                    | Range                            | Advertised by      | Consumer               |
| ----------------------- | -------------------------------- | ------------------ | ---------------------- |
| homelab-prod-lb-pool      | 192.168.50.240 – 192.168.50.250  | Cilium (homelab-prod) | homelab-prod services    |
| homelab-dev-lb-pool           | 192.168.60.240 – 192.168.60.250  | Cilium (homelab-dev)      | homelab-dev services         |
| mgmt-lb-pool            | 192.168.40.240 – 192.168.40.250  | Cilium (homelab-mgmt) | homelab-mgmt services    |

> **Edge router static routes:** Because most consumer/prosumer edge routers don't speak BGP, the edge gets static routes pointing each LB pool to `192.168.40.1` (the VRRP virtual IP). VyOS handles the rest. This keeps the BGP topology entirely internal.

---

