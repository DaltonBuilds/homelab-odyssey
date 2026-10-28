[← Docs index](../README.md) · **Operation Long Haul v5**

[← ADRs](01-adrs.md)  ·  [Tier 0 · Foundation →](tier-0-foundation.md)

---

## Network Architecture (Reference)

**Planned cluster baseline (ADR-012):** seven members in `homelab-pve`; hosts are numbered pve-01 through pve-07; .56/.57 remain unused. All home networking equipment is UniFi. Follow the [day-one port matrix](proxmox-day-one.md) for native VLAN 40 on host-facing ports and tagged guest VLANs. The owner confirmed `192.168.40.1` is the UniFi gateway; retain it for Proxmox/platform routing and use it for DNS only after verifying DNS service. VyOS uses planned VIP `192.168.40.12` for LoadBalancer routes; confirm .12 is free and outside the DHCP range before deployment. A MAC-based UniFi fixed-IP reservation is not needed for this future VRRP VIP. VLAN 50/60 gateway ownership still needs verification before assigning their planned VyOS VIPs.

### VLAN plan

| VLAN | Subnet            | Purpose                                          |
| ---- | ----------------- | ------------------------------------------------ |
| 10   | 192.168.10.0/24   | Workstation / management                         |
| 40   | 192.168.40.0/24   | Platform tier (Proxmox, Vault, homelab-mgmt, NFS, Garage, BGP routers) |
| 50   | 192.168.50.0/24   | homelab-prod cluster (prod nodes + LB pool)        |
| 60   | 192.168.60.0/24   | homelab-dev cluster (dev/staging nodes + LB pool)      |
| 70   | 192.168.70.0/24   | Ephemeral clusters (capacity-checked existing hosts — ADR-004/012) *(v5.1)* |

**Subnet versus pool:** UniFi VLANs 40, 50, 60, and 70 remain `/24` networks. The three planned `*.240/28` routes below describe smaller LoadBalancer destination blocks *within* the corresponding `/24` VLANs; they do not change the VLAN masks. The owner adjusted DHCP ranges for all four VLANs on 2026-09-19. Keep every planned static address and VIP outside its VLAN's DHCP range. In particular, exclude `192.168.40.12` and the full `192.168.40.240–255`, `192.168.50.240–255`, and `192.168.60.240–255` blocks from DHCP before enabling those VIPs or pools. UniFi fixed-IP reservations require client identity; shrinking the DHCP range protects addresses that have no MAC yet.

> **Note on VLAN expansion:** v3 used a single workload VLAN (40). v4 separates platform from prod from dev/staging, mirroring how real shops carve impact-level / tenancy boundaries at L2. Your switch must support VLAN trunks to **every Proxmox host** (v5.2: that now includes the M920q/M920x #2 boxes carrying the prod-tier VLAN 50). Configure trunks before starting Tier 0.
>
> **Current two-switch topology (owner update 2026-09-19).** The two office wall-jack ports feed the AP and the 8-port UniFi Flex switch separately. All seven Proxmox hosts, including pve-07, connect directly to the Flex switch; its eighth port is the uplink to the upstream switch. The Flex switch has no spare port in this layout. Carry VLANs 10/40/50/60 across the inter-switch uplink, with VLAN 70 added before use; configure each host-facing port with native VLAN 40 and its required tagged guest VLANs from the [day-one matrix](proxmox-day-one.md). A pve-07 VLAN 50 test checks its Flex host port and the shared inter-switch uplink, rather than a dedicated wall-jack trunk.

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
| Workstation            | 192.168.10.20   | 10   | Daily driver                            | Physical           |
| pve-01 (M920 SFF)   | 192.168.40.50   | 40   | Hypervisor 1 (64GB, prod-adjacent)      | Physical           |
| pve-02 (M920x #1)  | 192.168.40.55   | 40   | Hypervisor 2 (32GB, dev/staging)        | Physical           |
| pve-03 (M920x #2)  | 192.168.40.58   | 40   | Hypervisor 3 (32GB, spare + quorum) *(v5.2)* | Physical        |
| pve-04 (M920q)      | 192.168.40.59   | 40   | Hypervisor 4 — hosts prod-cp-01 *(v5.2)* | Physical        |
| pve-05 (M920q)      | 192.168.40.64   | 40   | Hypervisor 5 — hosts prod-w-01 *(v5.2)*  | Physical        |
| pve-06 (M920q)      | 192.168.40.65   | 40   | Hypervisor 6 — hosts prod-w-02 *(v5.2)*  | Physical        |
| pve-07 (Tower)      | 192.168.40.66   | 40   | Hypervisor 7 — GPU + build + mgmt-02 *(v5.4)* | Physical   |
| bgp-01 (VyOS)           | 192.168.40.10   | 40   | BGP router, VRRP master                 | VM on pve-01    |
| bgp-02 (VyOS)           | 192.168.40.11   | 40   | BGP router, VRRP backup                 | VM on pve-02    |
| UniFi gateway | 192.168.40.1 | 40 | Confirmed Proxmox/platform gateway; DNS if enabled | UniFi |
| bgp-vrrp (virtual) | 192.168.40.12 | 40 | VRRP next hop for LB routes (live 2026-10-28) | Floats bgp-01↔bgp-02 |
| vault-01 (Vault)       | 192.168.40.20   | 40   | Vault HA node 1 (Raft leader candidate) | VM on pve-01    |
| vault-02 (Vault)       | 192.168.40.21   | 40   | Vault HA node 2                         | VM on pve-02 *(2026-10-28: was pve-03)* |
| vault-03 (Vault)       | 192.168.40.22   | 40   | Vault HA node 3                         | VM on **pve-03** *(2026-10-28: was pve-02)* |
| nfs-01             | 192.168.40.51   | 40   | NFS + ZFS persistent storage            | VM on pve-01    |
| garage-01              | 192.168.40.53   | 40   | S3-compatible object storage            | LXC on pve-01   |
| ts-router-01           | 192.168.40.13   | 40   | Tailscale subnet router for PVE management (guest 110) *(HOMELAB-37)* | LXC on **pve-03** |
| mgmt-01 (mgmt CP)       | 192.168.40.60   | 40   | homelab-mgmt control plane                | VM on pve-01    |
| mgmt-02 (mgmt CP)    | 192.168.40.61   | 40   | homelab-mgmt control plane                | VM on **pve-07** *(v5.4: was pve-01)* |
| mgmt-03 (mgmt CP)     | 192.168.40.62   | 40   | homelab-mgmt control plane                | VM on pve-02    |
| mgmt-api (virtual)    | 192.168.40.63   | 40   | homelab-mgmt HA VIP (Talos-managed) *(v5.1)* | Floats mgmt-01/02/03 |
| prod-cp-01 (homelab-prod)   | 192.168.50.30   | 50   | homelab-prod control plane                | VM on pve-04    |
| prod-w-01 (homelab-prod)   | 192.168.50.31   | 50   | homelab-prod worker 1                     | VM on pve-05    |
| prod-w-02 (homelab-prod)   | 192.168.50.32   | 50   | homelab-prod worker 2                     | VM on pve-06    |
| prod-w-03 (homelab-prod)     | 192.168.50.33   | 50   | homelab-prod worker 3                     | VM on pve-01    |
| prod-gpu-01 (homelab-prod) | 192.168.50.34   | 50   | homelab-prod GPU worker (tainted, RTX 5070 passthrough) *(v5.4)* | VM on pve-07 |
| dev-cp-01 (homelab-dev)        | 192.168.60.30   | 60   | homelab-dev control plane                     | VM on pve-02    |
| dev-w-01 (homelab-dev)          | 192.168.60.31   | 60   | homelab-dev worker 1                          | VM on pve-02    |
| dev-w-02 (homelab-dev)          | 192.168.60.32   | 60   | homelab-dev worker 2                          | VM on pve-02    |

> ### ✅ Failure-domain concentration — resolved *(v5.4; was an open decision from the v5.1 review)*
>
> **The original problem.** Through v5.3, the "Location" column read: **pve-01 hosts two of three Vault nodes *and* two of three mgmt control-plane nodes**, plus nfs-01, garage-01, bgp-01, and prod-w-03. Losing pve-01 didn't degrade the platform — it *stopped* it: OpenBao lost Raft quorum (1 of 3 left), homelab-mgmt lost etcd quorum (1 of 3 left), and all persistent storage vanished at once. Both "HA" clusters were HA in name only against their single largest failure mode. Two nodes on one box was unavoidable with two hypervisors; it stopped being unavoidable at v5.2, and v5.1–v5.3 left the fix as an explicit open decision.
>
> **The decision (ADR-011).** Split the two relocated quorum nodes across **two different** hosts:
>
> - **vault-03 → pve-03** (M920x #2, 32GB — ample headroom for one OpenBao node) *(decided as vault-02 → pve-03; renumbered 2026-10-28 so vault-0N lives on pve-0N, with vault-02 on pve-02)*
> - **mgmt-02 → pve-07** (the tower, 64GB, mirrored NVMe — good etcd storage and the most headroom in the fleet)
>
> The Location cells above are updated accordingly. This is **strictly better than the old "Option 1,"** which put both nodes on pve-03 and merely relocated the correlated-failure problem: with the split, no single hypervisor loss can break either quorum. Both quorums now tolerate any one host failure, and ephemeral drills must fit available fleet capacity (ADR-012).
>
> **Post-mitigation failure analysis:**
>
> | Host lost | OpenBao Raft | homelab-mgmt etcd | Other impact |
> | --- | --- | --- | --- |
> | pve-01 | 2 of 3 — **quorum holds** | 2 of 3 — **quorum holds** | nfs-01 + garage-01 + bgp-01 + prod-w-03 down (storage outage; VRRP fails over to bgp-02) |
> | pve-03 | 2 of 3 — **quorum holds** | unaffected | Tailscale remote management down (ts-router-01); manage from the LAN or console |
> | pve-07 | unaffected | 2 of 3 — **quorum holds** | prod-gpu-01 + build host down (no platform impact) |
> | pve-02 | 2 of 3 — **quorum holds** | 2 of 3 — **quorum holds** | homelab-dev entirely down; bgp-02 down |
>
> **What remains accepted, deliberately.** Storage is still a single point of failure: nfs-01 and garage-01 both live on pve-01 and neither is replicated, so a pve-01 loss is a storage outage even though both quorums survive it. This is fine for a lab — the Phase 1.11 snapshot DR covers the data — but it is now the *largest* remaining single-host blast radius, and pve-07's mirror is the obvious future home for a Garage replica or a relocated nfs-01 (ADR-011 role 4). The mirror is now verified as **2×2TB WD_BLACK SN850X, ~1.8TiB usable** (2026-09-13). Existing VM sizes and placements remain unchanged. Additional headroom makes a future Garage replica more practical, but evaluate it after measuring real object-storage needs; NFS relocation and a NAS remain deferred decisions.

### LoadBalancer pools (BGP-advertised)

| Pool                    | Range                            | Advertised by      | Consumer               |
| ----------------------- | -------------------------------- | ------------------ | ---------------------- |
| homelab-prod-lb-pool      | 192.168.50.240 – 192.168.50.250  | Cilium (homelab-prod) | homelab-prod services    |
| homelab-dev-lb-pool           | 192.168.60.240 – 192.168.60.250  | Cilium (homelab-dev)      | homelab-dev services         |
| mgmt-lb-pool            | 192.168.40.240 – 192.168.40.250  | Cilium (homelab-mgmt) | homelab-mgmt services    |

> **Edge router static routes:** Because most consumer/prosumer edge routers don't speak BGP, the edge gets `/28` static routes pointing each LB pool to `192.168.40.12` (the VRRP virtual IP). VyOS handles the rest. This keeps the BGP topology entirely internal. Apply routes only after the VIP is live. Routes applied 2026-10-28; until BGP learns the pools, VyOS drops their traffic at distance-254 blackhole routes instead of looping it back to UniFi. A client on the *same* `/24` as an LB address ARPs for it directly instead of using the edge route (observed: pve-01 resolves `192.168.40.241` on-link), so BGP-only advertisement leaves same-VLAN clients unable to reach it. LB traffic also enters through VyOS but returns via each node's UniFi gateway. Decide an off-link pool, an on-link (L2) advertisement or a documented limitation, the speaker peering path, and the return path before Cilium peers: [HOMELAB-42](https://daltonbuilds.youtrack.cloud/issue/HOMELAB-42).

---


**pve-01 storage replacement (owner update 2026-09-27):** the 1TB SATA drive failed and was replaced by a 2TB NVMe; pve-01 was reinstalled and rejoined `homelab-pve` on 2026-10-10 ([HOMELAB-20](https://daltonbuilds.youtrack.cloud/issue/HOMELAB-20)). Keep the M920 SFF at `192.168.40.50` and retain all planned workload placements and guest disk budgets. Additional capacity adds headroom, not disk redundancy or a new failure domain. The failure-domain table above describes the intended completed platform, not currently deployed guests. See [recovery checklist](pve-01-recovery.md).
