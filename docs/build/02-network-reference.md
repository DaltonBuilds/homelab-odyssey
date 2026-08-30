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
| mgmt-api (virtual)    | 192.168.40.63   | 40   | homelab-mgmt HA VIP (Talos-managed) *(v5.1)* | Floats mgmt-01/02/03 |
| prod-cp-01 (homelab-prod)   | 192.168.50.30   | 50   | homelab-prod control plane                | VM on pve-06    |
| prod-w-01 (homelab-prod)   | 192.168.50.31   | 50   | homelab-prod worker 1                     | VM on pve-07    |
| prod-w-02 (homelab-prod)   | 192.168.50.32   | 50   | homelab-prod worker 2                     | VM on pve-08    |
| prod-w-03 (homelab-prod)     | 192.168.50.33   | 50   | homelab-prod worker 3                     | VM on pve-01    |
| dev-cp-01 (homelab-dev)        | 192.168.60.30   | 60   | homelab-dev control plane                     | VM on pve-02    |
| dev-w-01 (homelab-dev)          | 192.168.60.31   | 60   | homelab-dev worker 1                          | VM on pve-02    |
| dev-w-02 (homelab-dev)          | 192.168.60.32   | 60   | homelab-dev worker 2                          | VM on pve-02    |

> ### ⚠ Failure-domain warning (v5.1 review — needs your decision)
>
> Look down the "Location" column: **pve-01 hosts two of three Vault nodes *and* two of three mgmt control-plane nodes**, plus nfs-01, garage-01, bgp-01, and prod-w-03. Losing pve-01 doesn't degrade the platform — it *stops* it: OpenBao loses Raft quorum (1 of 3 left), homelab-mgmt loses etcd quorum (1 of 3 left), and all persistent storage vanishes at once. Both "HA" clusters are HA in name only against their single largest failure mode.
>
> Two nodes on one box was unavoidable with two hypervisors. **It isn't anymore** — as of v5.2 every physical box runs Proxmox, so pve-03/pve-04 and the newly-assigned pve-05 are all available quorum homes. Options, cheapest first:
> 1. **Move vault-02 → pve-05 and mgmt-02 → pve-05** *(v5.2 recommended)*. M920x #2 was assigned as pve-05 partly for this — it has ample headroom (32GB), and both quorums then survive any single hypervisor loss while the NUCs stay pristine for ephemeral drills. *(This is the old "Option 2," now trivially available because pve-05 exists.)*
> 2. **Spread onto the NUCs instead** — vault-02 → pve-03 and mgmt-02 → pve-04. Also survives a single-host loss, but the NUCs are no longer purely ephemeral capacity (one small standing VM each) and ephemeral drills share the box.
> 3. **Accept it and write it down** — document a single-hypervisor loss as a known RPO/RTO event, and lean on the Phase 1.11 snapshot DR. Legitimate for a lab, but it undercuts the HA rehearsal the 3-node topology exists to provide.
>
> *(The table above still shows vault-02/mgmt-02 on pve-01 — the pre-mitigation baseline. Pick an option and update the two Location cells; this doc leaves the choice to you rather than silently rewriting the quorum layout.)*
>
> Storage is a separate single point of failure regardless: nfs-01 and garage-01 both live on pve-01, and neither is replicated. That one is fine to accept — just accept it deliberately.

### LoadBalancer pools (BGP-advertised)

| Pool                    | Range                            | Advertised by      | Consumer               |
| ----------------------- | -------------------------------- | ------------------ | ---------------------- |
| homelab-prod-lb-pool      | 192.168.50.240 – 192.168.50.250  | Cilium (homelab-prod) | homelab-prod services    |
| homelab-dev-lb-pool           | 192.168.60.240 – 192.168.60.250  | Cilium (homelab-dev)      | homelab-dev services         |
| mgmt-lb-pool            | 192.168.40.240 – 192.168.40.250  | Cilium (homelab-mgmt) | homelab-mgmt services    |

> **Edge router static routes:** Because most consumer/prosumer edge routers don't speak BGP, the edge gets static routes pointing each LB pool to `192.168.40.1` (the VRRP virtual IP). VyOS handles the rest. This keeps the BGP topology entirely internal.

---

