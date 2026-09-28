# pve-01 — failed-drive recovery

Tracked by [HOMELAB-20](https://daltonbuilds.youtrack.cloud/issue/HOMELAB-20); it blocks [HOMELAB-15](https://daltonbuilds.youtrack.cloud/issue/HOMELAB-15), the bgp-01 reinstall.

Owner report, 2026-09-27: the M920 SFF's 1TB SATA drive failed and appears unrecoverable. A 2TB NVMe was ordered today and is expected in a few days. Replacement, Proxmox installation and VyOS reinstallation are pending. YouTrack is the source of truth for execution status.

Retain `pve-01`, `192.168.40.50/24`, and UniFi gateway `192.168.40.1`. Keep ext4 root and the existing workload placements and guest disk budgets. A nominal 2TB disk provides about 1.82TiB before partitioning and overhead; measure actual local/local-lvm capacity after installation. Extra capacity does not provide redundancy. Preserve the OpenBao and management-node distribution across physical hosts.

## Preparation while the drive is in transit

- Confirm the surviving cluster is quorate from a healthy node. Keep the failed node powered off.
- Record surviving cluster membership, storage IDs and cluster-wide guest IDs. Preserve any remaining pve-01 guest configuration from the cluster filesystem in a secure off-host location; configuration may survive even though local guest disks did not. Do not paste secrets into tickets or Git.
- Confirm the exact replacement NVMe fits the M920 SFF slot and mounting hardware and is supported for booting; record model and capacity on arrival.
- Prepare verified Proxmox and VyOS installation media. Inventory any independent backups before assuming all guest data is lost.

## Restore the host after the drive arrives

- Follow the official cluster-node removal procedure from a surviving quorate member before reusing the node identity. Review retained guest configs and storage references before cleanup; never erase the surviving cluster or force expected votes as routine recovery.
- Physically remove the failed SATA drive and install the NVMe. Fresh-install Proxmox with ext4 root, original hostname/IP, correct gateway and DNS. Match the surviving cluster's supported version and update level.
- Join the existing `homelab-pve` cluster while the replacement is empty, before creating guests. Do not use the original day-one Create Cluster step.
- Reconcile stale node configuration and SSH fingerprints as described in the official guide; use `pvecm updatecerts` on the re-added node if required for an SSH fingerprint error.
- Restore VLAN-aware vmbr0, native management VLAN40 and tagged VLAN50/60. Verify UI/SSH access, actual disk capacity, local/local-lvm configuration and media availability.
- Verify all seven members online and quorate, no HA-managed guests, and a disposable pve-01 VLAN50 guest reaches the edge/internet; delete that test guest.
- Reinstall bgp-01 from VyOS media under Phase 0.3. Preserve unique guest IDs and reconcile any retained old config before creating it. A VM snapshot on this disk is not an off-host backup.

Reference: [Proxmox cluster manager source documentation](https://github.com/proxmox/pve-docs/blob/master/pvecm.adoc), especially removing and rejoining a cluster node.
