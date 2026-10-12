# Phase 0.1 — Proxmox baseline and secure remote management

Owner-approved scope, 2026-10-03; see ADR-013 in [Architecture decisions](01-adrs.md). This is planned work, not evidence that automation or remote access is deployed. YouTrack is the source of truth for execution status.

Work belongs to [Epic HOMELAB-3 — Phase 0.1](https://daltonbuilds.youtrack.cloud/issue/HOMELAB-3):

| Issue | Outcome |
| --- | --- |
| [HOMELAB-36](https://daltonbuilds.youtrack.cloud/issue/HOMELAB-36) | Ansible baseline implementation and canary |
| [HOMELAB-37](https://daltonbuilds.youtrack.cloud/issue/HOMELAB-37) | Two-hour Tailscale placement investigation |
| [HOMELAB-38](https://daltonbuilds.youtrack.cloud/issue/HOMELAB-38) | Fleet adoption, including recovered pve-01 |
| [HOMELAB-39](https://daltonbuilds.youtrack.cloud/issue/HOMELAB-39) | Restricted remote access and recovery verification |

Reuse [HOMELAB-20](https://daltonbuilds.youtrack.cloud/issue/HOMELAB-20) for hardware recovery. Fleet adoption depends on baseline implementation and recovery; remote verification depends on placement and fleet adoption. The existing bgp-01 rebuild and BGP configuration tickets depend on remote verification.

## Boundaries and bootstrap

Keep firmware setup, disk selection and the initial USB installation manual for now. Manage repeatable post-install configuration with Ansible from the administrator workstation. OpenTofu provisions later guests; it does not own hypervisor installation or cluster membership. Use the seven-host addresses and storage distinctions in the [day-one inventory](proxmox-day-one.md#1-confirm-labels-and-addresses).

The baseline must work before OpenBao, VyOS, Kubernetes, internal PKI and internal DNS services exist. Bootstrap over the existing UniFi management path using verified SSH host keys and an administrator key held outside Git. Store recovery credentials in the workstation password store; supply sensitive values at execution time with log suppression. Never put private keys, passwords, enrollment tokens or Ansible output containing them in Git or tickets. Later OpenBao authentication can build on this bootstrap path without removing local recovery access.

Inspect existing host configuration before adopting it. Record PVE/Debian versions, APT sources, physical NICs, bridges, DNS/time configuration, storage, cluster membership and pve-07's ARC/GPU configuration. Use that evidence to populate inventory and detect unexpected differences. Do not reinstall working hosts merely to bring them under Ansible.

## Ansible baseline

Implement a repository-owned inventory, pinned tooling/collections and roles with documented workstation prerequisites and commands. Include:

- Version-aware APT configuration: disable all enterprise entries, enable one supported `pve-no-subscription` entry, retain Debian/security sources, disable unused Ceph and test repositories, and verify signature checking and a clean `apt update`. Detect both legacy `.list` and deb822 `.sources` entries rather than assuming one filename. Keep the subscription reminder; do not patch packaged UI files.
- Verified administrator SSH access, hostname/IP assertions, America/Denver timezone and functioning time synchronization/DNS using the existing bootstrap services. Hostnames and management addresses are final before joining; a normal baseline run must not rename a clustered host.
- Reviewed management access rules, notification destination/channel configuration and a delivered test notification. Keep notification credentials outside the repository. Preserve member-to-member cluster traffic, update egress and the existing local administrator path. Do not enable a restrictive firewall until required flows and rollback have been tested.
- Host-specific settings, initially the documented pve-07 ARC cap. Inspect and preserve its established GPU binding, bootloader and storage configuration; expanding GPU automation belongs to its existing phase. Verify effective settings after reboot.
- Read-only checks of VLAN-aware bridges, gateway, node-local storage, default Corosync/HA services, quorum and absence of HA-managed guests. Preserve local-lvm on ext4 hosts and local-zfs on pve-07. A cluster is not shared storage.

Separate convergence from maintenance: a normal baseline run must not upgrade/reboot hosts, change bridges, repartition disks, create/rejoin clusters or recreate guests. Put necessary network/firewall changes and updates in explicit procedures with config backups, console access, rollback and one-host-at-a-time execution. Stop if the cluster loses quorum or a host fails post-change verification. Match a rebuilt node's supported update level to surviving members before joining.

Acceptance: syntax checks pass; check/diff output is reviewed; an actual canary run succeeds; a second convergence run reports no unintended changes; UI/SSH, DNS, time and repositories work afterward. Repeat on all seven hosts, recording non-sensitive results. Document check-mode limitations. Seven-member completion waits for pve-01's NVMe delivery and recovery; inventory/role preparation and adoption of surviving hosts can proceed now.

The changing third-party post-install helper is historical context, not the new repeatable baseline. Review previous helper changes, including any UI patches or disabled cluster services, during adoption.

## Remote management — managed Tailscale Personal

Use managed Tailscale's free Personal plan; defer Headscale. Pricing checked 2026-10-03: six users, unlimited user devices, three ACL groups and fifty included tagged resources are sufficient for this management scope. Recheck limits before expanding use; no paid add-ons are required by this plan.

Prefer an always-on subnet router outside the Proxmox cluster. Before deployment, time-box a placement investigation to two hours: identify available hardware, network attachment, power dependency and capacity. The eight-port Flex switch is full, so do not assume a spare port or a new independent device exists. If none is available, document a small dedicated guest (VM or LXC container) on a healthy host as the initial compromise, with measured resources, a unique guest ID, verified unused IP/DHCP exclusion and explicit host placement. Record how loss of that host affects access. Direct Tailscale installation on selected PVE hosts is a fallback to evaluate, not an instruction to install it everywhere.

Keep the access path independent of VyOS, OpenBao, Kubernetes and lab-hosted identity/DNS. An existing external identity provider with MFA authenticates the administrator; retain Proxmox authentication and configure supported MFA for UI login. Ordinary SSH continues to use verified host keys and administrator keys. Tailscale supplies network access, not replacement PVE authorization.

Version the tailnet policy and subnet-router configuration. Advertise only the seven PVE management addresses as /32 routes initially; allow the administrator identity access to TCP 8006 and 22 only. Leave other VLAN40 services and guest VLANs out of scope. Remove broad default allow rules and include positive/negative policy tests. Approve routes and router tags explicitly; do not configure an exit node, public management forwarding or public application publishing. Document forwarding, SNAT behavior, host/UniFi firewall interaction, return traffic and client route acceptance for the chosen design. The LAN leg from router to PVE still uses HTTPS/SSH.

Enrollment uses short-lived credentials supplied outside Git, with logging suppressed. Record router device-key expiry/renewal choices and a revocation/re-enrollment procedure so unattended access does not silently expire. Keep local console/LAN administration and securely stored recovery credentials usable when Tailscale or its identity provider is unavailable.

### Placement decision — HOMELAB-37 (2026-10-11)

**Selected:** `ts-router-01`, an unprivileged Debian 13 LXC container, guest ID 110, on **pve-03** at `192.168.40.13/24` (native VLAN 40 on `vmbr0`, gateway `192.168.40.1`). Starting allocation 1 core, 256MB RAM, 256MB swap, 4GB on `local-lvm`; measure real use after deployment and record it here.

**Equipment inventory.** The fleet is the seven PVE hosts plus UniFi network gear; no independent always-on device (Pi, NUC, spare laptop) exists. The Flex switch's eight ports are all used (seven hosts plus uplink). An independent device would need a new purchase, and a port on the UniFi gateway or elsewhere in the UniFi fabric, not the Flex switch. Running Tailscale on the UniFi gateway itself relies on unsupported community scripts and was rejected for the recovery path.

**Why a container, not a VM.** `tailscaled` needs tens of megabytes; a VM adds a guest kernel and OS for roughly 512MB. The container gets the host's `/dev/net/tun` through Proxmox device passthrough (`dev0`) and enables IPv4 forwarding inside its own network namespace, so pve-03's host configuration is unchanged. Trade-off: it shares pve-03's kernel. It accepts no inbound connections from outside the LAN, so this is accepted. garage-01 already sets the LXC precedent.

**Why pve-03.** pve-03 is the designated spare-capacity host; its only planned guest is vault-02 (2GB of 32GB), and it had no guests on 2026-10-11 (about 30GB free, quorate seven-vote cluster, PVE 9.2). pve-01 already carries the largest blast radius (bgp-01, vault-01, mgmt-01, nfs-01, garage-01, prod-w-03); pve-02 carries the dev cluster plus bgp-02, vault-03 and mgmt-03 on 32GB; pve-04–06 are 16GB with one prod node each by design; pve-07 is the GPU/ZFS exception.

**Pre-assignment checks (2026-10-11).** Cluster guest IDs in use: 100 (bgp-01), 102 (bgp-02); 110 is free. `192.168.40.13` did not answer ARP from pve-03 and is not in the planned address table. **Owner to confirm** `.13` is outside the UniFi VLAN 40 DHCP range before deployment. The deployment play re-checks both and refuses a used ID or an answering address.

**Network path.** The router advertises only the seven PVE management `/32` routes, auto-approved by the tailnet policy for `tag:pve-mgmt-router` only. SNAT stays on (Tailscale default), so PVE hosts see connections from `.13` and reply on-link; no UniFi static route, port forward or inbound rule is needed. PVE host firewalls, if enabled, must allow 8006/22 from `.13`. The router does not accept tailnet DNS or routes and runs no Tailscale SSH. Clients must accept subnet routes (macOS app: **Use Tailscale subnets**, which was off on the workstation; Linux: `--accept-routes`). While accepted, PVE traffic uses the router even on the LAN; for LAN or outage management, turn subnet use off or quit Tailscale. No exit node.

**Failure dependencies and fallback.** Losing pve-03 or the container removes remote access and takes vault-02 down (OpenBao keeps quorum). Recovery: LAN workstation to each host's UI/SSH, or the local console; then `pct start 110` on pve-03 or recreate the container from the playbook. Tagged-node key expiry is disabled by default, so the router does not expire unattended. Out-of-band recovery of a powered-off or network-broken host remains physical access.

**Automation.** `homelab-infra` owns the router (`ansible/playbooks/ts-router.yaml`, role `ts_router`) and the tailnet policy (`tailscale/policy.hujson`, tested on pull request and applied on merge by a GitHub Actions workflow authenticated with GitHub OIDC federation, not a stored Tailscale secret). Like the VyOS and OpenBao bootstrap VMs, this guest is Tier 0 infrastructure created before OpenTofu exists; it must keep working when OpenBao and OpenTofu do not. When OpenTofu arrives, import guest 110 rather than recreating it. The enrollment key is single-use, pre-approved, tagged and short-lived, supplied only in the environment of the enrolling run.

**Unresolved hardware needs.** None for this decision. An independent device on separate power would remove the pve-03 dependency; it is a possible future purchase, not a requirement.

Acceptance: from an external network, the authorized workstation reaches UI, browser shell/noVNC and ordinary SSH on every online PVE host using verified identities/certificates; unauthorized identities cannot reach management; other destinations/ports are denied. Access survives a router reboot. Test revocation with a temporary enrolled client. With the router stopped, local LAN/console administration still works; record host/router failure behavior and recovery steps. VPN access cannot start a powered-off host or repair a broken host network; these mini PCs have no IPMI.

## Build sequence and recovery

1. Prepare inventory/roles and decide router placement. *(Placement decided 2026-10-11, above.)*
2. Apply the baseline to a healthy canary, then adopt surviving hosts individually without disturbing quorum or retained guests.
3. Recover pve-01 through [HOMELAB-20](https://daltonbuilds.youtrack.cloud/issue/HOMELAB-20): manual install, repository/version alignment, baseline bootstrap and existing-cluster rejoin following the recovery checklist. Verify seven members and complete fleet convergence. *(Recovery completed 2026-10-10.)*
4. Deploy and test remote access and local fallback before resuming substantial BGP/OpenBao build work.

The owner accepts replaying the early BGP work for learning. A full hypervisor/cluster wipe is unnecessary for this scope. If replaying VyOS, record existing config, VM IDs and any active routes first, then use the existing Phase 0.3 tickets to rebuild deliberately; preserve the UniFi management gateway and completed VLAN work.

Sources: [Proxmox repositories](https://github.com/proxmox/pve-docs/blob/master/pve-package-repos.adoc), [cluster management](https://github.com/proxmox/pve-docs/blob/master/pvecm.adoc), [Tailscale pricing](https://tailscale.com/pricing), [subnet routers](https://tailscale.com/docs/features/subnet-routers), [direct Proxmox integration](https://tailscale.com/docs/integrations/proxmox).
