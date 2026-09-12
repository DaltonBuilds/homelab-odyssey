# Day one — Seven Proxmox hosts managed from the laptop

Accepted inventory and clustering decision: [ADR-012](01-adrs.md#adr-012--seven-confirmed-hosts-one-proxmox-cluster-unifi-bootstrap-2026-09-12). This checklist is the installation-day entry point; finish the remaining [Tier 0](tier-0-foundation.md) work afterward.

## 1. Confirm labels and addresses

| Host | Physical machine | Static management address | Root storage |
| --- | --- | --- | --- |
| pve-01 | M920 SFF, 64GB | 192.168.40.50/24 | 1TB, ext4 |
| pve-02 | M920x #1, 32GB | 192.168.40.55/24 | 1TB, ext4 |
| pve-05 | M920x #2, 32GB | 192.168.40.58/24 | 1TB, ext4 |
| pve-06 | M920q #1, 16GB | 192.168.40.59/24 | 512GB, ext4 |
| pve-07 | M920q #2, 16GB | 192.168.40.64/24 | 512GB, ext4 |
| pve-08 | M920q #3, 16GB | 192.168.40.65/24 | 512GB, ext4 |
| pve-09 | Ryzen tower, 64GB, RTX 5070 | 192.168.40.66/24 | Both 1TB NVMe, ZFS RAID1 |

The tower is the seventh machine. pve-03/pve-04 and .56/.57 are unused, not installation targets. Record MAC addresses, disk identities, and switch ports/wall jacks. Save passwords outside Git.

## 2. Prepare UniFi before relying on remote access

- [ ] In UniFi Network, confirm VLAN 40 / 192.168.40.0/24 exists; its gateway is **192.168.40.1 (UniFi, owner-confirmed)**. Verify DNS service at that address before using it as the resolver. Verify the planned static addresses are unused and excluded from DHCP allocation.
- [ ] Use **192.168.40.1** as the installation gateway and retain it after VyOS deployment. The future VyOS VIP is **192.168.40.12**, reserved in this plan for LoadBalancer routing; verify it is unused and exclude it from DHCP before assigning it. VyOS itself routes upstream through UniFi at .1.
- [ ] Permit laptop access from its actual LAN/SSID (planned VLAN 10) to host TCP 8006 and 22 plus ICMP, with return traffic. Allow host DNS, NTP, and HTTP/HTTPS egress for updates. Do not expose management ports to the WAN.
- [ ] In each switch's Port Manager, set host-facing **Native VLAN / Network** to VLAN 40. Set **Tagged VLAN Management** to Custom using the table below. UI wording may vary by UniFi Network version.

| Host-facing ports | Native | Allowed tagged guest VLANs |
| --- | --- | --- |
| pve-01 and pve-02 | 40 | 50, 60 (both will host VyOS routers) |
| pve-05 | 40 | None initially |
| pve-06, pve-07, pve-08, pve-09 | 40 | 50 |
| Selected ephemeral host, when needed | 40 | Add 70 to that host's existing list |

- [ ] Carry 10/40/50/60 across the switch-to-switch and gateway uplinks; add 70 end to end before using it. Keep uplink native VLANs consistent and preserve the existing management network for switches/APs. A host-facing native-40 profile must not be blindly applied to every uplink or AP port.
- [ ] Verify the actual upstream port serving pve-09's wall jack. Confirm the documented two-switch layout against physical cabling.
- [ ] Permit member-to-member TCP 22 and 8006 and UDP 5405–5412 on the trusted management network. Verify reliable wired connectivity and low latency; schedule bulk transfers so they do not starve Corosync. A dedicated physical cluster NIC is the recommended future improvement if available.

Native VLAN 40 means the host sends management traffic untagged. The management IP belongs on vmbr0, not vmbr0.40. Guest NICs for VLAN 50/60/70 use the corresponding Proxmox VLAN tag. A VLAN-40 guest can use an untagged NIC with this bridge setup. VyOS trunk NICs need deliberate guest-side tagging as described in Phase 0.3; do not combine a Proxmox access tag with duplicate guest subinterface tagging.

## 3. Install and validate each host

- [ ] Start with pve-01; preserve an existing usable installation if present. Confirm data backups before erasing any disk. Check the official ISO checksum and successful USB validation.
- [ ] Enable VT-x/SVM and VT-d/IOMMU in firmware; boot the USB in UEFI mode. Use Terminal UI if graphical installation fails.
- [ ] Select the correct internal disks and filesystem from the table. Only pve-09 uses ZFS RAID1, across both NVMes.
- [ ] Enter America/Denver, notification email, and a stored root password. Use the final FQDN, e.g. pve-01.homelab.internal, static /24 address, existing working gateway, and DNS resolver.
- [ ] Remove USB and reboot. From the laptop open https://192.168.40.50:8006 (substitute each host IP); verify the expected host before accepting the initial self-signed certificate. Log in as root with Linux PAM authentication.
- [ ] Verify browser shell and SSH. Under System → Network, confirm vmbr0 uses the connected physical NIC, carries the host IP/default gateway, and is VLAN aware. Keep console access during changes.
- [ ] Configure appropriate package repositories in the UI: enterprise with subscription, otherwise disable subscription-only entries and enable No-Subscription. Disable unused subscription-only Ceph entries. Run apt update and apt dist-upgrade, review the transaction, then reboot. Bring every member to the same Proxmox version before joining.
- [ ] Check hostname -f, ip -br address, ip route, timedatectl, and pveversion -v. Confirm DNS resolution and synchronized clocks. Verify UI and SSH access after reboot before repeating on the next machine.
- [ ] On pve-09 verify zpool status shows an ONLINE two-disk mirror. Apply the documented ARC limit and verify it after reboot. GPU binding/passthrough can wait until remote access works; it is not part of this day's acceptance gate.

## 4. Create the cluster before creating guests

- [ ] Keep installed members powered on throughout joining. Have at least three ready so the initial two-member stage is brief. Do not power off the first member while installing the rest.
- [ ] On pve-01: Datacenter → Cluster → Create Cluster; name **homelab-pve**; select 192.168.40.50 as Link 0. Final names and management IPs must already be correct.
- [ ] Copy Join Information. On each other empty host: Datacenter → Cluster → Join Cluster; paste the information, authenticate to the existing member, verify its fingerprint, and select the joining host's VLAN 40 management address for Link 0.
- [ ] Reload after the certificate/session changes. Verify membership before joining the next host. Joining replaces /etc/pve configuration; if a joining host already has guests, back them up and plan their restore with unique IDs before proceeding.
- [ ] Under Datacenter → Storage, restrict local-lvm to pve-01/02/05/06/07/08 and add/reconcile local-zfs for pve-09 using its actual rpool/data dataset. Verify local storage on each host. Shared storage configuration does not make local disks shared; do not mark them Shared.
- [ ] Allocate VM/CT IDs uniquely across the entire cluster. Keep planned workload placement; configure no HA resources and no Ceph for this milestone. Joining hosts does not enable automatic guest failover.
- [ ] On completion, pvecm status must show Nodes: 7, Expected votes: 7, Quorum: 4, Quorate: Yes. Confirm all seven members appear through pve-01's UI and another member's UI.

Seven equal-vote members need four communicating votes. Loss of quorum restricts management and makes configuration read-only; existing non-HA guests generally continue running. Never use forced expected-vote changes as a normal workaround. Perform maintenance one host at a time. Mixed Intel/AMD hosts can share management, but do not assume live migration across vendors or with GPU passthrough.

## 5. Day-one acceptance

- [ ] All seven hosts boot without the USB and remain reachable from the laptop after individual reboots.
- [ ] One member's UI manages all seven; a second member's UI works as an alternate entry point.
- [ ] Cluster quorum, DNS, time synchronization, package updates, and pve-09's mirror are healthy.
- [ ] Record switch ports, MACs, hostnames, IPs, and versions; save bookmarks and credentials securely.
- [ ] Before production guest use, test VLAN 50 on pve-01 and pve-09 and VLAN 60 on pve-02 using disposable guests with unique IDs. Test VLAN 70 when first configured. Management reachability alone does not prove guest VLAN paths.

Continue with Tier 0's guest-network tests, images, Huly, VyOS, OpenBao, and GPU preparation. Those are separate from this day-one completion gate.

Sources: [Proxmox installation](https://github.com/proxmox/pve-docs/blob/master/pve-installation.adoc), [cluster manager](https://github.com/proxmox/pve-docs/blob/master/pvecm.adoc), [network configuration](https://github.com/proxmox/pve-docs/blob/master/pve-network.adoc), [UniFi port VLAN assignment](https://help.ui.com/hc/en-us/articles/26136855808919-Switch-Port-VLAN-Assignment-Trunk-Access-Ports).
