[← Docs index](../README.md) · **Operation Long Haul v5**

[← Network Reference](02-network-reference.md)  ·  [Tier 1 · Platform Provisioning →](tier-1-platform-provisioning.md)

---

## Tier 0 — Foundation

**Purpose:** Establish the substrate everything else depends on. By the end of Tier 0, you have all seven physical hypervisors online (pve-01/02 standing platform + dev, pve-03 spare + vault-02 host, pve-04/05/06 hosting the homelab-prod node VMs, pve-07 GPU + build + mgmt-02 host), a redundant BGP routing fabric, and a fully-configured OpenBao HA cluster with PKI, Transit, SSH OTP, and Database engines ready to issue credentials. **No Kubernetes exists yet.** Nothing in higher tiers can begin until Tier 0 verification passes.

**Why this tier exists separately:** v3 treated Vault as an application — Phase 6, after the cluster existed. That created a circular dependency (Ansible needed secrets to build the cluster; Vault lived in the cluster Ansible built). v4 inverts this: Vault is foundation, every later tier consumes it.

### Tier 0 Phases

- **0.1** — Proxmox installation, Ansible host baseline and secure remote management on all seven physical hypervisors
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

### Phase 0.1: Proxmox Installation (All Physical Hypervisors)

**Start with [Day one — Proxmox + UniFi](proxmox-day-one.md): prepare management networking first, install the seven confirmed hosts, and join `homelab-pve` before provisioning guests.** The host-specific checklist below supplements that procedure. Host management keeps the working UniFi gateway; later VyOS gateway changes require explicit routing verification.

**Goal:** Every physical machine running Proxmox VE, accessible from workstation, ready to host VMs. *(v5.2: this now includes the M920q trio and M920x #2, which formerly ran bare-metal Ubuntu — see ADR-008. v5.4: and pve-07, the former workstation tower — see ADR-011.)*

**Ubuntu media baseline (2026-09):** use the Ubuntu Server **26.04.1 live-server amd64 ISO** for manual Vault VM installs, and the separate Ubuntu Server **26.04 amd64 cloud image** (`ubuntu-26.04-server-cloudimg-amd64.img`) for later cloud-init VMs. The 26.04.1 point release is the install ISO version; Ubuntu publishes the cloud image under the 26.04 filename. The live-server ISO was previously staged on pve-01; re-upload it after the failed-drive rebuild. Because `local` storage is node-local, stage media on each host that will use it:

| Media | Hosts | Planned use |
| --- | --- | --- |
| Ubuntu Server 26.04.1 live-server ISO | pve-01, pve-02, pve-03 | Manual installs of vault-01, vault-03, vault-02 |
| VyOS LTS ISO | pve-01, pve-02 | bgp-01, bgp-02 |
| Talos `metal-amd64.iso` | pve-01, pve-02, pve-07 | mgmt-01, mgmt-03, mgmt-02 |
| Ubuntu Server 26.04 amd64 cloud image | pve-01 through pve-07, before those VMs are provisioned | Later Ubuntu cloud-init VMs |

Record the downloaded image builds and checksums. The [Ubuntu Server ISO](https://ubuntu.com/download/server) and [Ubuntu cloud image](https://cloud-images.ubuntu.com/releases/resolute/release/) are different artifacts.

**Expanded foundation scope (2026-10-03, ADR-013):** implement the [Ansible baseline and managed Tailscale remote-access plan](proxmox-baseline.md) before resuming substantial BGP/OpenBao work. Adopt existing hosts in place; pve-01 was recovered on 2026-10-10. The baseline works without OpenBao or VyOS. Keep the subscription reminder and replace recurring use of the community post-install helper with repository-owned roles. Router placement was decided on 2026-10-11 ([HOMELAB-37](https://daltonbuilds.youtrack.cloud/issue/HOMELAB-37)): an unprivileged LXC on pve-03; see the baseline specification.

#### pve-01 (M920 SFF, 64GB / 2TB NVMe — recovered 2026-10-10)

Owner update 2026-09-27: the 1TB SATA drive failed and is considered unrecoverable. It was replaced by a 2TB NVMe and pve-01 rejoined the cluster on 2026-10-10 ([HOMELAB-20](https://daltonbuilds.youtrack.cloud/issue/HOMELAB-20)). For any future reinstall, use Proxmox with ext4 root, preserving hostname `pve-01` and IP `192.168.40.50`; follow the [recovery checklist](pve-01-recovery.md) to rejoin the existing cluster before recreating bgp-01. Do not create a new cluster.

- [ ] Confirm pve-01 reachable at `192.168.40.50`
- [ ] Update Proxmox to latest stable patch release: `apt update && apt dist-upgrade`
- [ ] Verify VLAN-aware `vmbr0`, native management VLAN 40, and tagged guest VLANs 50/60 for VyOS

#### pve-02 (new M920x, 32GB / 1TB)

- [ ] Download latest stable Proxmox VE ISO, flash to USB
- [ ] Install Proxmox on the 1TB SSD, ext4 root filesystem (not ZFS — ZFS lives in the NFS VM only)
- [ ] Set management IP: `192.168.40.55`, gateway `192.168.40.1` (UniFi, confirmed)
- [ ] Hostname: `pve-02`
- [ ] Complete installation, reboot
- [ ] Access UI from workstation: `https://192.168.40.55:8006`
- [ ] Apt update + dist-upgrade
- [ ] Configure VLAN-aware `vmbr0`, native management VLAN 40, and tagged guest VLANs 50/60 for VyOS
- [ ] Confirm `192.168.40.55` is outside the edge-router DHCP range
- [ ] Upload the Ubuntu Server 26.04.1 live-server amd64 ISO and VyOS LTS ISO to local storage; re-stage the Ubuntu ISO on pve-01 after recovery

#### pve-03 (M920x #2, 32GB / 1TB — spare + quorum) *(v5.2)*

Formerly the unassigned "spare" M920x. Now a standing Proxmox host: idle capacity plus the home of the relocated **`vault-02`** *(v5.4: decided — `mgmt-02` went to pve-07 instead, so the two relocated quorum nodes sit on different hosts. See ADR-011 and the resolved failure-domain note in Network Architecture.)*

- [ ] Install Proxmox VE on the 1TB SSD, ext4 root
- [ ] Management IP `192.168.40.58`, gateway `192.168.40.1` (UniFi, confirmed); hostname `pve-03`; apt update + dist-upgrade
- [ ] Configure `vmbr0` to accept trunked VLAN 40 (add VLAN 50 if you place a prod-tier VM here)
- [ ] Stage the Ubuntu Server 26.04.1 live-server amd64 ISO and 26.04 amd64 cloud image on local storage
- [ ] Confirm the management IP is outside the edge-router DHCP range

#### pve-04 / pve-05 / pve-06 (3× M920q, 16GB / 512GB each — homelab-prod node hosts) *(v5.2)*

Each M920q hosts exactly **one** homelab-prod node VM (pve-04 → prod-cp-01, pve-05 → prod-w-01, pve-06 → prod-w-02), provisioned by OpenTofu in Phase 1.3 — one VM per box preserves the per-machine failure boundary the bare-metal layout had, while making the node reproducible and snapshottable.

- [ ] Install Proxmox VE on each 512GB SSD, ext4 root (no ZFS — keeps host RAM overhead to ~1–1.5GB on these 16GB boxes)
- [ ] Management IPs: `192.168.40.59` (pve-04), `192.168.40.64` (pve-05), `192.168.40.65` (pve-06), gateway `192.168.40.1` (UniFi, confirmed)
- [ ] Hostnames `pve-04` / `pve-05` / `pve-06`; apt update + dist-upgrade
- [ ] Configure `vmbr0` to accept trunked VLAN 50 (the homelab-prod cluster VLAN) — and VLAN 40 for the management interface
- [ ] Stage the Ubuntu Server 26.04 amd64 cloud image on local storage on each
- [ ] Confirm all three management IPs are outside the edge-router DHCP range

#### pve-07 (Tower — Ryzen 9 7900X, 64GB / 2× 2TB WD_BLACK SN850X NVMe / RTX 5070) *(v5.4)*

The former home-office workstation, reassigned to the fleet (ADR-011). This is the fleet's only GPU host, only ZFS-root host, and the most capable single machine in the inventory. It carries three standing roles: `mgmt-02` (relocated quorum node), the amd64 build host, and — from Tier 5 — `prod-gpu-01`.

**Pre-install (do these before flashing — order matters):**

- [ ] Confirm nothing on the existing Fedora install is needed. *(Confirmed at planning time: nothing to rescue. Both NVMe sticks get wiped.)*
- [x] **Matching drives verified 2026-09-13:** two WD_BLACK SN850X 2000GB NVMes; owner-provided `lsblk` confirms both models and capacities.
- [ ] **Verify both M.2 slots run at full lanes with the RTX 5070 populated.** On AM5, the second M.2 is often chipset-attached; a mirror across one CPU-attached and one chipset-attached slot is workable but caps mirror write throughput. Check the board manual's lane-sharing table — this is a "know it now" item, not a blocker
- [ ] Enable **IOMMU / AMD-Vi** and **SVM** in UEFI; disable Secure Boot (or enroll keys) as required for the passthrough path
- [ ] Note the onboard NIC's link speed (Ryzen 7000 boards commonly ship 2.5GbE). If it is 2.5GbE and the switch port is 1GbE, that ceiling matters later if a Garage replica or nfs-01 lands here

**Install:**

- [ ] Install Proxmox VE selecting **ZFS RAID1 (mirror)** across both 2TB WD_BLACK SN850X NVMe sticks — **~1.8TiB practically usable** after ZFS overhead. *(Deliberate exception to ADR-008's ext4-on-single-disk pattern; rationale and the full space budget are in ADR-011.)*
- [ ] **Retain the VM budget (ADR-011):** ~50GiB host allowance + 60GiB `mgmt-02` + 200GiB build VM + 250GiB `prod-gpu-01`. The verified ~1.8TiB mirror leaves roughly 1.2–1.3TiB uncommitted before future data and free-space reserve. Keep that headroom for snapshots, caches, and measured growth; defer extra standing storage services.
- [ ] Management IP `192.168.40.66`, gateway `192.168.40.1` (UniFi, confirmed); hostname `pve-07`; apt update + dist-upgrade
- [ ] **Cap the ARC:** write `options zfs zfs_arc_max=10737418240` (10GB) to `/etc/modprobe.d/zfs.conf`, then `update-initramfs -u` and reboot. 64GB shared between `mgmt-02`, a build VM, `prod-gpu-01`, and an uncapped ARC will otherwise get tight
- [ ] Configure `vmbr0` to accept trunked VLANs **40 and 50** (40 for `mgmt-02` and management, 50 for `prod-gpu-01`)
- [ ] Stage the Ubuntu Server 26.04 amd64 cloud image **and** the Talos `metal-amd64.iso` (this host runs both a Talos mgmt node and Ubuntu-based RKE2/build VMs)
- [ ] Confirm the management IP is outside the edge-router DHCP range

**GPU passthrough prep** *(config only — no VM consumes the GPU until Tier 5):*

- [ ] Follow the [GPU passthrough preflight](pve-07-gpu-passthrough.md). Verify firmware IOMMU support and the active bootloader before changing kernel parameters. AMD IOMMU is normally enabled by the kernel when firmware exposes it; `iommu=pt` is optional. Use `update-grub` for GRUB or `proxmox-boot-tool refresh` for systemd-boot after editing the appropriate configuration.
- [ ] Confirm the GPU sits in its own IOMMU group: `for d in /sys/kernel/iommu_groups/*/devices/*; do echo "$(basename $(dirname $(dirname $d))) $(basename $d)"; done | sort -n`
- [ ] Blacklist the host drivers (`nouveau`, `nvidia`) and bind `vfio-pci` to the GPU's PCI IDs (both the VGA function and its HDMI audio function) via `/etc/modprobe.d/`
- [ ] `lspci -nnk` shows `Kernel driver in use: vfio-pci` on the GPU after reboot
- [ ] **Do not install NVIDIA drivers on the Proxmox host** — the driver belongs inside the guest that receives the passthrough

> **Sequencing note.** Roles 1–2 (mgmt-02, build host) need only the install above. The GPU is *prepared* here and *consumed* in Tier 5. Deliberately do not make `prod-gpu-01` the first node you prove the RKE2 CIS profile on — GPU Operator driver container + `profile: cis` + SELinux enforcing on a fresh Blackwell driver branch is a known-friction stack, and you want the CIS profile already working on boring hardware (pve-04/05/06) before adding a new variable. See ADR-011.

#### Verification

- [ ] All seven hosts pass the Ansible baseline checks; a second convergence run has no unintended changes. Updates/reboots and disruptive operations remain explicit.
- [ ] Restricted Tailscale remote UI, browser console and SSH access passes external-network tests; unauthorized access is denied and local recovery works with the router stopped. See the [baseline acceptance criteria](proxmox-baseline.md).
- [ ] All seven Proxmox web UIs load from workstation
- [ ] `ping` succeeds to every hypervisor management IP (`.50`, `.55`, `.58`, `.59`, `.64`, `.65`, `.66` on VLAN 40)
- [ ] Ubuntu 26.04 cloud image + VyOS/Talos ISOs visible in the relevant Proxmox storage pools
- [ ] All seven hosts joined to `homelab-pve`; `pvecm status` reports seven nodes, seven expected votes, quorum four, and `Quorate: Yes`; no HA-managed guests
- [ ] `zpool status` on pve-07 shows a healthy 2-way mirror; `arc_summary` reflects the capped `zfs_arc_max` *(v5.4)*
- [ ] `lspci -nnk` on pve-07 shows the RTX 5070 bound to `vfio-pci` *(v5.4)*

---

### Phase 0.2: Switch / VLAN Configuration

**Goal:** The managed switches trunk all required VLANs to every Proxmox host and your workstation.

This is the most boring and most critical phase. BGP, cluster separation, everything downstream assumes VLAN trunking is correct.

> **Current topology (owner update 2026-09-19):** the two office wall-jack ports feed the AP and the 8-port UniFi Flex switch separately. All seven Proxmox hosts, including pve-07, connect directly to the Flex switch. Its eighth port is the uplink to the upstream switch, leaving no spare Flex port. Configure the Flex host ports and shared inter-switch uplink for the required VLANs; verify the two wall-jack paths and actual port numbers.

- [ ] Identify port assignments across **both** switches for pve-01 through pve-07 on the Flex switch, its inter-switch uplink, the AP's separate wall-jack path, the workstation's actual network path, and the edge-router uplink. The M920q prod hosts pve-04/05/06 and pve-07 need tagged VLAN 50.
- [ ] In UniFi Port Manager, set hypervisor ports to **Native VLAN 40** and custom **Tagged VLAN Management** for guest VLANs: pve-01/02 need 50 and 60 for the VyOS routers; pve-04/05/06/07 need 50; pve-03 needs no extra guest VLAN initially. Add 70 to the chosen ephemeral host and every upstream link before a drill. Workstation access port: native VLAN 10.
- [ ] Confirm the **inter-switch link** carries 10/40/50/60 and matches native VLAN settings at both ends; add 70 before ephemeral use. Preserve existing switch/AP management.
- [ ] Create VLAN interfaces on the edge router for VLANs 50 and 60 (if not already present for 10/40)
- [ ] Confirm the owner-adjusted DHCP ranges on VLANs 40, 50, 60, and 70 leave planned static addresses and VIPs outside the pools. VLANs 50 and 60 need DHCP for disposable first-boot tests; later workload VMs use static cloud-init addressing. Exclude `192.168.40.12` and each planned `*.240–255` LoadBalancer block. A future VIP has no client MAC to reserve in UniFi; an out-of-range address is sufficient.
- [x] Prepare `/28` static routes on the edge router for the three LoadBalancer blocks below. These `/28` destinations sit inside the VLAN `/24` networks and do not change their subnet masks. Apply the routes only after the VyOS VRRP next hop is live in Phase 0.3. *Applied 2026-10-28 ([HOMELAB-18](https://daltonbuilds.youtrack.cloud/issue/HOMELAB-18)) in UniFi under Settings → Routing → Create New Route → Static, type Next Hop. Clients on the same VLAN as a block do not use these routes; see [HOMELAB-42](https://daltonbuilds.youtrack.cloud/issue/HOMELAB-42).*
  - `192.168.50.240/28 → 192.168.40.12`
  - `192.168.60.240/28 → 192.168.40.12`
  - `192.168.40.240/28 → 192.168.40.12`

#### Verification

- [ ] From a test VM on pve-01 tagged to VLAN 50, can reach the edge router and the internet
- [ ] From a test VM on pve-02 tagged to VLAN 60, same
- [ ] **From a test VM on pve-07 tagged to VLAN 50, same** — this checks pve-07's Flex host port and the shared inter-switch uplink, so do not skip it
- [ ] Delete test VMs

> **Blog note:** This phase rarely makes it into homelab writeups but is exactly the kind of L2 hygiene that breaks "production-grade" claims when skipped. Document your switch model and config — the next time you replace it, future-you will thank you.

---

> ### Project tracking
>
> Use YouTrack Cloud project `Homelab` (`HOMELAB`) and the [work breakdown](work-breakdown.md). Custom issue types are configured; the YouTrack MCP integration is connected. No tracker VM is required for Tier 0. Continue with Phase 0.3.

---

### Phase 0.3: VyOS BGP Fabric

**Goal:** Two VyOS routers running, peered with each other via iBGP, providing a VRRP next hop for the LoadBalancer routes on VLAN 40, ready to peer with Cilium speakers in Tier 2.

**Confirmed gateway correction (2026-09-12):** UniFi owns `192.168.40.1`; the planned VyOS VLAN 40 VIP is now `192.168.40.12`. Before assigning .12, confirm it is unused in UniFi and outside the DHCP range; no preexisting client MAC is needed for a DHCP-range exclusion. Proxmox and platform guests retain UniFi as their gateway. **Confirmed 2026-10-28:** UniFi also owns `.1` and is the gateway on VLANs 50 and 60, so VyOS runs a VRRP group on VLAN 40 only.

> **As built (2026-10-28, [HOMELAB-17](https://daltonbuilds.youtrack.cloud/issue/HOMELAB-17)–[19](https://daltonbuilds.youtrack.cloud/issue/HOMELAB-19)).** Both routers run VyOS `2026.10.07-0712-rolling` and are configured by the `vyos_router` Ansible role in [homelab-infra](https://github.com/DaltonBuilds/homelab-infra) (`ansible/playbooks/vyos-router.yaml`). That role is the source of truth for the configuration; 0.3b below shows the equivalent commands. Ansible reaches the routers over SSH through the Tailscale subnet router, which advertises `.10`/`.11` (never the VIP `.12`). Open Tier 2 decisions on LoadBalancer reachability and the peering path are tracked in [HOMELAB-42](https://daltonbuilds.youtrack.cloud/issue/HOMELAB-42).

#### 0.3a — Provision both VyOS VMs

For each VyOS VM, use the Proxmox UI for this one (Terraform won't manage Tier 0 infrastructure — that would create the same circular dependency we're eliminating with Vault):

- [x] **bgp-01** (guest 100) on pve-01: 1 vCPU, 1GB RAM, 8GB disk, virtual NIC on `vmbr0` with untagged/native VLAN 40 and tagged VLANs 50/60 passed as a trunk (no Proxmox access VLAN tag). The trunk leaves room for VLAN 50/60 sub-interfaces; none are configured yet (see 0.3b). Boot from VyOS ISO.
- [x] **bgp-02** (guest 102) on pve-02: same specs
- [x] Install VyOS to disk on both (`install image` in the live ISO console)
- [x] On first reboot, set a different password on each router, establish SSH access, and add a known SSH public key using the bootstrap sequence below
- [x] Snapshot both VMs in Proxmox after verifying the fresh install and access (`fresh-install`) — gives you a clean restore point before VRRP/BGP changes
- [x] Run the same build on both routers. Rolling builds change between snapshots. bgp-02 was installed from an older ISO (`2026.09.17`) and upgraded on 2026-10-28 with `add system image <iso-url>` and a reboot; the ISO left in a VM's CD drive is not what it boots (disk is first in the boot order). `show system image` shows the installed images. The Ansible preflight refuses a router that is not on the pinned build.

**Validated console-to-SSH bootstrap (2026-09-20):** Proxmox noVNC did not provide usable paste into the VyOS text console. Do the short network setup in each VM's console, then use the workstation's terminal for the longer configuration. In Proxmox, check **VM → Hardware → Network Device**: bridge `vmbr0`, no Proxmox VLAN access tag. Check **host → System → Network**: `vmbr0` is VLAN aware. The switch path must carry native VLAN 40 and tagged VLANs 50/60. `vmbr0` alone does not prove the trunk is correct.

After `install image` and reboot, use the VyOS console on **bgp-01** (`.10`) and **bgp-02** (`.11`) respectively. Confirm both addresses are unused before assigning them. Set a unique password for each router during install, or change one from configuration mode with `set system login user vyos authentication plaintext-password '<unique-password>'`, followed by `commit` and `save`. Do not put passwords or private keys in Git. The commands below show bgp-01; substitute `.11` in both address lines for bgp-02.

```bash
configure
set interfaces ethernet eth0 address '192.168.40.10/24'
set protocols static route 0.0.0.0/0 next-hop 192.168.40.1
set service ssh port '22'
set service ssh listen-address '192.168.40.10'
commit
save
exit
```

The default route is needed for replies to a workstation on another VLAN, such as VLAN 10. Without it, both SSH and ping to the new router address timed out in the first deployment. From each VyOS console, confirm `show interfaces ethernet eth0` shows the assigned address and an up link, then ping `192.168.40.1`. From the workstation, run `ssh vyos@192.168.40.10` (or `.11`) and authenticate with that router's password. If it still times out, check the VM NIC, VLAN path, and UniFi policy before troubleshooting SSH credentials.

In the workstation terminal, read the **public** key (for example, `cat ~/.ssh/id_ed25519.pub`) and add it on both routers. For an `ssh-ed25519 AAAA... comment` line, the VyOS `type` is `ssh-ed25519` and the `key` value is **only** the middle `AAAA...` field; including the type or comment in `key` fails validation. Paste the full base64 field on one line:

```bash
configure
set system login user vyos authentication public-keys workstation type ssh-ed25519
set system login user vyos authentication public-keys workstation key '<base64-field-only>'
commit
save
exit
```

Open a new SSH session to each router to verify key login before relying on it. Take named fresh-install snapshots after this access check; a snapshot is a rollback point on that VM's storage, not a backup of the Proxmox host. Rolling back also restores the credentials saved in the snapshot.

#### 0.3b — Base VyOS configuration

Apply with Ansible from homelab-infra, standby router first:

```bash
mise exec -- ansible-playbook ansible/playbooks/vyos-router.yaml --check --diff --limit bgp-02
mise exec -- ansible-playbook ansible/playbooks/vyos-router.yaml --diff --limit bgp-02
mise exec -- ansible-playbook ansible/playbooks/vyos-router.yaml --diff
```

The role sends only the lines missing from the running config, commits them with a comment, and saves. A second run reports no changes. The equivalent configuration on **bgp-01**:

```bash
configure

# Hostname, and a resolver: without one the default time*.vyos.net NTP servers never resolve
set system host-name 'bgp-01'
set system name-server '192.168.40.1'

# Management is untagged/native VLAN 40 on eth0; UniFi stays the default gateway
set interfaces ethernet eth0 address '192.168.40.10/24'
set protocols static route 0.0.0.0/0 next-hop '192.168.40.1'

# LoadBalancer blocks UniFi routes to the VIP. Until BGP learns them, drop them here instead of
# looping back to UniFi through the default route. Distance 254 loses to any BGP route.
set protocols static route 192.168.40.240/28 blackhole distance '254'
set protocols static route 192.168.50.240/28 blackhole distance '254'
set protocols static route 192.168.60.240/28 blackhole distance '254'

# VRRP on VLAN 40 only: bgp-01 is master (priority 200), bgp-02 backup (priority 100)
set high-availability vrrp group VLAN40 interface 'eth0'
set high-availability vrrp group VLAN40 vrid '40'
set high-availability vrrp group VLAN40 priority '200'
set high-availability vrrp group VLAN40 address 192.168.40.12/24

# BGP: ASN 65000, iBGP to the other VyOS router
set protocols bgp system-as '65000'
set protocols bgp parameters router-id '192.168.40.10'
set protocols bgp neighbor 192.168.40.11 remote-as '65000'
set protocols bgp neighbor 192.168.40.11 description 'iBGP to bgp-02'
set protocols bgp neighbor 192.168.40.11 address-family ipv4-unicast

# eBGP peer groups, staged empty for the Tier 2 Cilium speakers (VyOS calls these peer-group)
set protocols bgp peer-group homelab-prod remote-as '65001'
set protocols bgp peer-group homelab-prod address-family ipv4-unicast
set protocols bgp peer-group homelab-dev remote-as '65002'
set protocols bgp peer-group homelab-dev address-family ipv4-unicast

commit
save
exit
```

SSH (`service ssh listen-address`) stays as set during the bootstrap. For **bgp-02**: host name `bgp-02`, address and router ID `192.168.40.11`, VRRP priority `100`, iBGP neighbor `192.168.40.10`.

**Changes from the original plan:**

- **No VLAN50/VLAN60 VRRP groups.** UniFi owns `.1` on those VLANs, so groups claiming those addresses would conflict with the gateway.
- **No VLAN 50/60 sub-interfaces (`.2`/`.3`) yet.** With a leg on those VLANs, VyOS would route between them and bypass UniFi's inter-VLAN firewall. How the Tier 2 speakers peer (sub-interfaces with VyOS firewall rules, multihop over VLAN 40, or UniFi as a BGP peer) is decided in [HOMELAB-42](https://daltonbuilds.youtrack.cloud/issue/HOMELAB-42).
- **`peer-group`, not `neighbor-group`.** `neighbor-group` is not VyOS syntax, so VyOS rejects the `set` command. Neighbors and peer groups also need `address-family ipv4-unicast` to exchange IPv4 routes.
- **Resolver and blackholes added**, for the reasons in the comments above.

#### 0.3c — Verify BGP fabric

`vyos-router-verify.yaml` checks hostname, VRRP group and priority, the default route via UniFi, the blackholes and name resolution, plus the MASTER/BACKUP roles, which router holds the VIP, and iBGP in both directions. Results on 2026-10-28:

- [x] SSH to bgp-01: `show ip bgp summary` — confirms iBGP session to bgp-02 is `Established`
- [x] SSH to bgp-02: same
- [x] `show vrrp` on both — confirms bgp-01 is master and bgp-02 is backup for the VLAN40 group
- [x] `ping 192.168.40.12` succeeds from a VLAN 40 host (pve-01), whose ARP entry resolves the VIP to bgp-01's NIC. The workstation reaches the routers over Tailscale, which deliberately does not route the VIP.
- [x] Test failover: power off bgp-01 in Proxmox → bgp-02 becomes VRRP master → `ping 192.168.40.12` resumes. **Measured 3.53 s** with a 0.2 s ping from pve-02: within the 5 s gate. The default 1 s advertisement interval gives about 3 × 1 s plus skew ≈ 3.6 s; shorten `advertise-interval` if faster failover is needed. Power bgp-01 back on: it preempts back to master with no lost pings, and iBGP re-establishes within about 30 s.
- [x] Keep all Proxmox host gateways at `192.168.40.1` (UniFi); do not move them to the VyOS VIP.

After a silent peer loss, iBGP stays listed as up until its hold timer expires (180 s by default). That is expected: BGP plays no part in VIP failover.

> **Blog note — VRRP vs ECMP:** A more sophisticated production setup uses ECMP with both routers active simultaneously rather than VRRP active/passive. For homelab scale, VRRP is dramatically simpler to reason about and the failover latency is acceptable. Document this tradeoff in an ADR — it's exactly the kind of "I considered X but chose Y because" reasoning interviewers probe.

---

### Phase 0.4: Vault VM Provisioning (Bootstrap Mode)

**Goal:** Three Vault VMs (vault-01/02/03) running Ubuntu Server 26.04.1, hardened baseline, OpenBao binary installed (pinned 2.6.x), ready to initialize.

> **Bootstrap pragmatism:** We're going to hand-provision these three VMs in the Proxmox UI rather than via Terraform. Reason: Terraform will be Vault-authenticated starting in Tier 1, and the Vault that authenticates it has to exist first. After Tier 0 completes, all future infrastructure provisioning (including replacing or scaling these Vault VMs) goes through Terraform-with-Vault. This is the *only* manual provisioning in the entire build.

> **OpenBao naming convention (read once — applies to the whole doc):** The secrets server is **OpenBao** (Linux Foundation fork of HashiCorp Vault, API-compatible — ADR-006). Everything else keeps the familiar Vault naming on purpose: hostnames stay `vault-01/02/03`, DNS stays `vault.homelab.internal`, `pass` paths stay `homelab/vault/*`, and prose references to "Vault" / "the Vault tier" mean this OpenBao cluster. Only three things differ day-to-day: the CLI is **`bao`**, the systemd unit is **`openbao`**, and config lives in **`/etc/openbao/`**. Env vars stay `VAULT_*` throughout — the `bao` CLI falls back to them when `BAO_*` is unset, and every downstream client (Terraform provider, Ansible `hashi_vault`, ESO, cert-manager, cosign) expects them anyway.

#### 0.4a — Create the three Vault VMs

For each (specs are identical):

| VM         | Hypervisor | vCPU | RAM | Disk | IP             |
| ---------- | ---------- | ---- | --- | ---- | -------------- |
| vault-01   | pve-01  | 2    | 2GB | 20GB | 192.168.40.20  |
| vault-02   | **pve-03** *(v5.4: was pve-01)* | 2    | 2GB | 20GB | 192.168.40.21  |
| vault-03   | pve-02  | 2    | 2GB | 20GB | 192.168.40.22  |

> **One Raft node per hypervisor *(v5.4 — ADR-011)*.** `vault-02` moved off pve-01 so no single hypervisor hosts two of the three OpenBao nodes. Do not "simplify" this back onto pve-01 while hand-creating the VMs — the whole point of the Tier 1 single-host-loss drill is that this spread holds. `mgmt-02` moves to pve-07 in the same change.

- [ ] Create each VM in Proxmox UI from the Ubuntu Server 26.04.1 live-server amd64 ISO
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
sudo ufw allow from 192.168.10.0/24 to any port 8200 proto tcp  # workstation → Vault API (v5.1: was missing; every Tier 0 `bao` command runs from here)
sudo ufw allow from 192.168.50.0/24 to any port 8200 proto tcp  # homelab-prod → Vault
sudo ufw allow from 192.168.60.0/24 to any port 8200 proto tcp  # homelab-dev → Vault
sudo ufw allow from 192.168.40.20,192.168.40.21,192.168.40.22 to any port 8201 proto tcp  # Raft cluster (inter-node)
sudo ufw enable
```

#### 0.4c — Install OpenBao binary

On each Vault VM:

```bash
# OpenBao ships signed .deb packages on its GitHub releases (no vendor apt repo).
# Pin the version explicitly — upgrades happen deliberately, never via blanket
# `apt upgrade`. Check https://github.com/openbao/openbao/releases for the
# latest 2.6.x patch release before starting, and use that.
BAO_VERSION="2.6.0"

wget "https://github.com/openbao/openbao/releases/download/v${BAO_VERSION}/bao_${BAO_VERSION}_linux_amd64.deb"
wget "https://github.com/openbao/openbao/releases/download/v${BAO_VERSION}/checksums.txt"
grep "bao_${BAO_VERSION}_linux_amd64.deb" checksums.txt | sha256sum -c -

sudo dpkg -i "bao_${BAO_VERSION}_linux_amd64.deb"

# The package installs the `bao` binary, an `openbao` system user/group, config
# at /etc/openbao/openbao.hcl, and an `openbao.service` systemd unit.
# Service is installed but not enabled yet — we need to write config first
sudo systemctl disable openbao
```

> **Air-gap note:** The download-verify-install flow (vs. a live apt repo) is itself the air-gapped delivery pattern. Once Garage exists (Tier 1), vendor the pinned `.deb` + `checksums.txt` into a bucket so a Vault-tier rebuild never depends on GitHub being reachable.

#### Verification

- [ ] All three Vault VMs reachable via SSH from workstation
- [ ] `bao version` on each shows the pinned 2.6.x version, identical across all three
- [ ] `ufw status` on each shows the expected rules
- [ ] `timedatectl` shows synced clocks within a few hundred ms across all three

---

### Phase 0.5: Vault HA Cluster Initialization

**Goal:** Vault HA cluster operational with Raft storage and Shamir-key unseal. We migrate to GCP KMS auto-unseal in Phase 0.6 — initialize with Shamir first so the migration is exercised, not assumed.

> **Why Shamir first, then migrate to auto-unseal:** Practicing the migration is the whole point. Going straight to auto-unseal hides the failure modes and the recovery procedure. The migration from Shamir → auto-unseal is the same operation you'd run to *change* KMS providers in the future (e.g., GCP KMS → AWS KMS for a disaster scenario, or rotating the KMS key). It's a high-value rehearsal.

#### 0.5a — Vault configuration file (each node)

Create `/etc/openbao/openbao.hcl` on each Vault VM. Substitute `NODE_HOSTNAME` and `NODE_IP` per node:

```hcl
# /etc/openbao/openbao.hcl  (vault-01 example)

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
  path    = "/opt/openbao/data"
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

- [ ] Create `/opt/openbao/data` on each node, owned by the `openbao` user:
  ```bash
  sudo install -d -o openbao -g openbao -m 0750 /opt/openbao/data
  ```
- [ ] Enable and start Vault on **vault-01 first**, then vault-02, then vault-03:
  ```bash
  sudo systemctl enable --now openbao
  sudo systemctl status openbao   # should show running
  ```

#### 0.5b — Initialize the cluster (vault-01 only)

```bash
export VAULT_ADDR=http://127.0.0.1:8200

bao operator init \
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

bao operator unseal <unseal-key-1>
bao operator unseal <unseal-key-2>
bao operator unseal <unseal-key-3>

bao status
# Expect: Sealed=false, HA Enabled=true, Raft Applied Index increasing
```

#### 0.5d — Verify Raft cluster health

```bash
# Log in as root to inspect
export VAULT_ADDR=http://192.168.40.20:8200
bao login <initial-root-token>

bao operator raft list-peers
# Expect three nodes: vault-01 (leader), vault-02 (follower), vault-03 (follower)
```

#### 0.5e — Enable the file audit device *(v5.1 — gap fix)*

Later tiers assume an audit trail exists (Phase 1.6's OTP verification, the Tier 1/2 gates, the Sloth SLO on `vault_audit_log_request_failure`) — but nothing previously enabled one. Enable it now, immediately after init, so everything from PKI bootstrap onward is on the record:

```bash
# Audit-log directory on ALL three nodes (each node writes its own copy)
sudo install -d -o openbao -g openbao -m 0750 /opt/openbao/audit

# Enable once, from any node — audit devices are cluster-wide config
bao audit enable file file_path=/opt/openbao/audit/audit.log
```

> **Failure semantics — know this before it bites:** with a single audit device, if OpenBao cannot write to it (disk full, permissions), it **blocks all requests** rather than proceed unaudited. That is the compliance-correct behavior — and the reason the Vault-VM disk alerts in Phase 3.5e are not optional. Keep audit-disk headroom alerting tight.

Logrotate on each node (audit logs grow fast; a HUP makes OpenBao reopen the file):

```bash
sudo tee /etc/logrotate.d/openbao-audit << 'LOGEOF'
/opt/openbao/audit/audit.log {
  daily
  rotate 14
  compress
  delaycompress
  missingok
  notifempty
  postrotate
    systemctl kill -s HUP openbao
  endscript
}
LOGEOF
```

Downstream: the raw audit log ships to Loki via Alloy on the substrate VMs (Phase 3.5a) and joins the immutable audit-retention story (3.12). Secrets never appear in it — request/response fields are HMAC'd by design.

#### Verification

- [ ] `bao status` on all three nodes: unsealed, HA enabled
- [ ] `bao operator raft list-peers`: 3 voters listed
- [ ] Kill the Raft leader (e.g., `sudo systemctl stop openbao` on vault-01) — a new leader is elected within ~5 seconds. Restart vault on vault-01 and confirm it rejoins as a follower.
- [ ] `vault-init.json` encrypted in `pass` AND a paper copy of 3 unseal keys exists physically
- [ ] `bao audit list` shows the file device; entries appear in `/opt/openbao/audit/audit.log` as you run commands; logrotate config present on all three nodes

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
  ssh dalton@${HOST} 'sudo install -o openbao -g openbao -m 0400 /tmp/vault-unseal-sa.json /etc/openbao/gcp-kms.json && rm /tmp/vault-unseal-sa.json'
done

# Securely delete from your workstation
shred -u ~/vault-unseal-sa.json
```

#### 0.6d — Update Vault config with `seal` stanza

On each Vault VM, edit `/etc/openbao/openbao.hcl` and add:

```hcl
seal "gcpckms" {
  credentials = "/etc/openbao/gcp-kms.json"
  project     = "homelab-vault"
  region      = "us-central1"
  key_ring    = "vault-unseal"
  crypto_key  = "vault-unseal-key"
}
```

> **DO NOT** restart Vault yet. The seal stanza alone doesn't migrate — it sets up the new seal mechanism. The migration is a one-time command.

> **OpenBao seal deprecation gate (v5.1):** The built-in `gcpckms` seal used above is **deprecated in OpenBao 2.6 and removed in 2.7** — from 2.7 it exists only as an external KMS plugin (openbao-plugins repo). This build pins 2.6.x, where the stanza works as-is. **Migrating the seal to the external plugin is a hard prerequisite before any upgrade past 2.6.x** — it is the same seal-migration operation rehearsed in this phase, so it is a feature, not a chore. Tracked in Future Upgrades. Related caution: OpenBao 2.5.0 shipped a seal-breaking bug (auto-unseal failed with "cipher: message authentication failed"; fixed in 2.5.1) — always pin exact versions and rehearse upgrades on a scratch single-node instance before touching this cluster.

#### 0.6e — Perform the seal migration

```bash
# On vault-01, with Vault still running under Shamir keys
export VAULT_ADDR=http://127.0.0.1:8200

# Restart Vault to load the new seal stanza (it will come up sealed — expected)
sudo systemctl restart openbao

# Provide unseal keys with -migrate flag
bao operator unseal -migrate <unseal-key-1>
bao operator unseal -migrate <unseal-key-2>
bao operator unseal -migrate <unseal-key-3>

# Vault is now unsealed AND migrated. From this point forward, restarts auto-unseal.
bao status
# Look for: Recovery Seal Type: gcpckms

# Repeat the restart on vault-02 and vault-03 (they don't need the -migrate flag since
# the cluster state already migrated; they just need to pick up the new seal config)
sudo systemctl restart openbao   # on vault-02 — auto-unseals
sudo systemctl restart openbao   # on vault-03 — auto-unseals
```

> **What happens during migration:** OpenBao rewraps its master key with the GCP KMS key. The Shamir unseal keys are retired and replaced by *recovery keys*. Recovery keys are still required for operations like `bao operator generate-root` — keep them safe — but they aren't needed for routine unseal.

#### 0.6f — Generate new recovery keys output

After migration, Vault generated 5 new recovery keys (printed during the migrate operation). Save them:

- [ ] Capture the recovery keys from the migration output
- [ ] Store the recovery keys encrypted in `pass` under `homelab/vault-recovery-keys`
- [ ] Print a paper copy of recovery keys 1, 2, 3 for the physical safe
- [ ] Archive the old `vault-init.json` Shamir entry — it's now historical

#### Verification

- [ ] Power off all three Vault VMs simultaneously, wait 30 seconds, power them back on. They auto-unseal without any manual intervention. `bao status` from your workstation against each shows unsealed.
- [ ] `bao status` shows `Recovery Seal Type: gcpckms`
- [ ] Recovery keys safely stored in two places (encrypted digital + physical paper)
- [ ] Running version is pinned 2.6.x (built-in `gcpckms` seal still present; seal-plugin migration is a hard gate before any 2.7+ upgrade — see Future Upgrades)

---

### Phase 0.7: PKI Engine — Internal Root + Intermediate CA

**Goal:** Vault becomes the internal certificate authority. cert-manager will use this CA (via the Vault issuer) to issue short-lived certs to internal services starting in Tier 2.

> **Two-tier CA pattern:** A root CA signs an intermediate CA; the intermediate signs leaf certificates. The root stays offline-style (we'll generate it, use it once, then disable the mount until rotation time). The intermediate handles day-to-day issuance. This matches the X.509 best practice that "root keys are precious; intermediates are operational."

#### 0.7a — Enable and configure the root PKI

```bash
export VAULT_ADDR=http://192.168.40.20:8200
bao login <root-token>

# Mount the root PKI with a 10-year max lease
bao secrets enable -path=pki_root pki
bao secrets tune -max-lease-ttl=87600h pki_root

# Generate the self-signed root certificate (returns the public cert; private key never leaves Vault)
bao write -field=certificate pki_root/root/generate/internal \
  common_name="Homelab Root CA" \
  ttl=87600h \
  key_type=ed25519 \
  > ~/homelab-root-ca.crt

# Configure URLs (where consumers fetch the cert and check revocation)
bao write pki_root/config/urls \
  issuing_certificates="http://192.168.40.20:8200/v1/pki_root/ca" \
  crl_distribution_points="http://192.168.40.20:8200/v1/pki_root/crl"
```

#### 0.7b — Enable and configure the intermediate PKI

```bash
# Mount the intermediate at a separate path
bao secrets enable -path=pki_int pki
bao secrets tune -max-lease-ttl=43800h pki_int   # 5 years max

# Generate a CSR — private key stays in Vault
bao write -format=json pki_int/intermediate/generate/internal \
  common_name="Homelab Intermediate CA" \
  key_type=ed25519 \
  | jq -r '.data.csr' > ~/pki_int.csr

# Sign the CSR using the root
bao write -format=json pki_root/root/sign-intermediate \
  csr=@~/pki_int.csr \
  format=pem_bundle \
  ttl=43800h \
  | jq -r '.data.certificate' > ~/pki_int.cert.pem

# Import the signed cert back into the intermediate mount
bao write pki_int/intermediate/set-signed certificate=@~/pki_int.cert.pem

# Configure URLs for the intermediate
bao write pki_int/config/urls \
  issuing_certificates="http://192.168.40.20:8200/v1/pki_int/ca" \
  crl_distribution_points="http://192.168.40.20:8200/v1/pki_int/crl"
```

#### 0.7c — Create issuance roles

These define what certs the intermediate is allowed to sign. We start with one role for internal services; add more later as needs emerge.

```bash
bao write pki_int/roles/internal-services \
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
bao write -format=json pki_int/issue/internal-services \
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
    sudo install -o openbao -g openbao -m 0444 /tmp/vault-bundle.crt /etc/openbao/vault.crt &&
    sudo install -o openbao -g openbao -m 0400 /tmp/vault.key /etc/openbao/vault.key &&
    rm /tmp/vault-bundle.crt /tmp/vault.key
  '
done

# Securely clean workstation tempfiles
shred -u /tmp/vault.crt /tmp/vault.key /tmp/vault-ca.crt /tmp/vault-bundle.crt ~/vault-tls.json
```

Update `/etc/openbao/openbao.hcl` on each node — change the listener block:

```hcl
listener "tcp" {
  address          = "0.0.0.0:8200"
  cluster_address  = "0.0.0.0:8201"
  tls_cert_file    = "/etc/openbao/vault.crt"
  tls_key_file     = "/etc/openbao/vault.key"
  tls_min_version  = "tls13"
}
```

Restart Vault on each node, one at a time (rolling, so the cluster stays available):

```bash
sudo systemctl restart openbao
# Wait for auto-unseal and rejoin, verify with: bao status (should show unsealed, HA active)
# Then move to next node
```

Update `api_addr` and `cluster_addr` in each node's config from `http://` to `https://`. **Also update all three `retry_join` blocks** — they still point at `http://` from Phase 0.5a and will fail to rejoin after any restart once TLS is on *(v5.1 fix)*:

```hcl
storage "raft" {
  path    = "/opt/openbao/data"
  node_id = "vault-01"

  retry_join {
    leader_api_addr         = "https://192.168.40.20:8200"
    leader_ca_cert_file     = "/etc/openbao/vault.crt"   # bundle includes the intermediate
  }
  retry_join {
    leader_api_addr         = "https://192.168.40.21:8200"
    leader_ca_cert_file     = "/etc/openbao/vault.crt"
  }
  retry_join {
    leader_api_addr         = "https://192.168.40.22:8200"
    leader_ca_cert_file     = "/etc/openbao/vault.crt"
  }
}
```

One more rolling restart applies the change.

From your workstation:

```bash
export VAULT_ADDR=https://192.168.40.20:8200
export VAULT_CACERT=~/homelab-root-ca.crt   # the file from Phase 0.7a
bao status
# Should connect over TLS, show all three nodes healthy
```

#### Verification

- [ ] `curl --cacert ~/homelab-root-ca.crt https://192.168.40.20:8200/v1/sys/health` returns 200 OK
- [ ] `bao read pki_int/cert/ca` returns the intermediate cert chain
- [ ] Test issuance: `bao write pki_int/issue/internal-services common_name=test.homelab.internal ttl=1h` returns a valid cert
- [ ] Distribute `~/homelab-root-ca.crt` to your workstation's trust store and `~/.config/vault/ca.crt` — future commands can drop the `--cacert` flag
- [ ] Back up the root CA cert file to `pass` under `homelab/vault/root-ca-cert`

---

### Phase 0.8: Transit Engine — Encryption as a Service

**Goal:** Applications can encrypt and decrypt arbitrary blobs using Vault-managed keys without ever holding the key material themselves. Will be used in Tier 4 by your custom OTel-instrumented app (and notably by Harbor for Cosign signing key storage).

```bash
bao secrets enable -path=transit transit

# Create one key per use case rather than reusing a single key
bao write -f transit/keys/cosign-harbor \
  type=ecdsa-p256 \
  exportable=false \
  allow_plaintext_backup=false

bao write -f transit/keys/app-data-encryption \
  type=aes256-gcm96 \
  exportable=false

# Smoke test
echo -n "hello" | base64 | xargs -I {} bao write transit/encrypt/app-data-encryption plaintext={}
# Returns: ciphertext = vault:v1:...
```

> **Why `exportable=false`:** The key material never leaves Vault. Apps make API calls to encrypt/decrypt — they can't snapshot the key, persist it, or leak it via a memory dump. The encryption operation itself becomes auditable.

#### Verification

- [ ] `bao list transit/keys` returns `cosign-harbor` and `app-data-encryption`
- [ ] Round-trip encrypt → decrypt of a test string succeeds

---

### Phase 0.9: SSH OTP Engine — Ephemeral Host Access

**Goal:** Replace static SSH key access for sudo operations on the cluster and platform VMs with one-time passwords issued by Vault. Every privileged SSH session is audited. *(The Vault SSH role keeps the name `otp-baremetal` for continuity — the enrolled nodes are Linux VMs, not literal bare metal; see ADR-008.)*

> **Scope clarification:** We're enabling the SSH OTP engine in Vault and pre-staging the configuration. Actually *enrolling* hosts (installing `vault-ssh-helper` on each, setting up PAM) happens in Tier 1 alongside the rest of OS hardening — it requires Ansible to be Vault-authenticated, which needs Phase 0.11 done first. This phase just gets the engine ready.

```bash
bao secrets enable -path=ssh ssh

# Create the OTP role — defines who can request OTPs for which hosts
bao write ssh/roles/otp-baremetal \
  key_type=otp \
  default_user=dalton \
  cidr_list=192.168.40.0/24,192.168.50.0/24,192.168.60.0/24
```

#### Verification

- [ ] `bao read ssh/roles/otp-baremetal` returns the role config
- [ ] (Full end-to-end OTP test deferred to Tier 1 after vault-ssh-helper is installed)

---

### Phase 0.10: Database Engine — Enabled and Pre-Staged

**Goal:** The database secrets engine is mounted and ready. Specific Postgres connection definitions land in Tier 4 when CloudNativePG creates the actual databases.

```bash
bao secrets enable -path=database database
```

That's all for this phase — no connections to configure yet. The engine is ready to accept connection definitions when CloudNativePG instances exist in Tier 4.

---

### Phase 0.11: AppRole Authentication for Terraform & Ansible

**Goal:** Terraform and Ansible can authenticate to Vault using AppRole. The `secret_id` for each lives in `pass` on your workstation. No more `ansible-vault`, no more credentials in `terraform.tfvars`.

#### 0.11a — Enable AppRole and create policies

```bash
bao auth enable approle

# Policy for Terraform — needs to read SSH keys, cloud-init secrets, GCP credentials, etc.
bao policy write terraform-provisioner - <<EOF
path "secret/data/terraform/*" {
  capabilities = ["read"]
}
path "ssh/creds/otp-baremetal" {
  capabilities = ["create", "read", "update"]
}
EOF

# Policy for Ansible — broader read access for OS-level secrets, plus SSH OTP for privileged ops
bao policy write ansible-orchestrator - <<EOF
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
bao secrets enable -version=2 -path=secret kv
```

#### 0.11b — Create AppRoles

```bash
bao write auth/approle/role/terraform \
  token_policies="terraform-provisioner" \
  token_ttl=1h \
  token_max_ttl=4h \
  secret_id_ttl=0 \
  secret_id_num_uses=0

bao write auth/approle/role/ansible \
  token_policies="ansible-orchestrator" \
  token_ttl=1h \
  token_max_ttl=4h \
  secret_id_ttl=0 \
  secret_id_num_uses=0

# Fetch the role IDs (these are not secret — they identify which AppRole you're authenticating as)
bao read -field=role_id auth/approle/role/terraform/role-id > ~/terraform-role-id.txt
bao read -field=role_id auth/approle/role/ansible/role-id   > ~/ansible-role-id.txt

# Generate secret IDs (these ARE secret — the AppRole "password")
bao write -force -field=secret_id auth/approle/role/terraform/secret-id > ~/terraform-secret-id.txt
bao write -force -field=secret_id auth/approle/role/ansible/secret-id   > ~/ansible-secret-id.txt
```

> **`secret_id_ttl=0` and `secret_id_num_uses=0`:** Long-lived secret IDs that don't expire and have no use count limit. Appropriate for workstation-resident automation credentials. For *workload* AppRoles (issued to ESO running inside clusters), use short TTLs and require periodic re-issuance — but that's a Tier 2 concern.

#### Verification

- [ ] Test Terraform AppRole login:
  ```bash
  ROLE_ID=$(cat ~/terraform-role-id.txt)
  SECRET_ID=$(cat ~/terraform-secret-id.txt)
  bao write auth/approle/login role_id="$ROLE_ID" secret_id="$SECRET_ID"
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

- [ ] All seven Proxmox hosts operational, accessible from workstation, joined to `homelab-pve` with healthy quorum and no HA-managed guests *(v5.4: pve-07 included — plus a healthy ZFS mirror and the GPU bound to `vfio-pci`)*
- [ ] Both switches use the Phase 0.2 native/tagged port matrix; the Flex-to-upstream link carries 10/40/50/60 (and 70 when used), with matching native VLAN settings. Test guest traffic from pve-07 through its Flex host port and the inter-switch uplink.
- [x] `ping 192.168.40.12` succeeds (VRRP virtual IP responds). *Verified 2026-10-28 from VLAN 40 hosts; Tailscale does not route the VIP to a remote workstation.*

#### BGP fabric

*Verified 2026-10-28 ([HOMELAB-19](https://daltonbuilds.youtrack.cloud/issue/HOMELAB-19)); rerun `vyos-router-verify.yaml` before passing the gate.*

- [x] bgp-01 and bgp-02 both running on separate hypervisors
- [x] iBGP session between them is `Established`
- [x] VRRP failover test passes (kill master → backup takes over within 5 seconds → restore master → role returns). *Measured 3.53 s.*
- [x] Edge router has static routes for all three LB pools pointing to `192.168.40.12`

#### Vault HA

- [ ] All three Vault VMs healthy: `bao status` from each shows unsealed, HA enabled, Raft index advancing
- [ ] `bao operator raft list-peers` shows three voters
- [ ] Cold-restart test passes (power off all three, power on, all auto-unseal without intervention)
- [ ] Raft leader-loss test passes (stop leader, new leader elected within ~5s, old leader rejoins as follower on restart)
- [ ] Vault listener is on TLS with cert issued by Vault's own intermediate CA (`https://`, not `http://`)

#### Engines configured

- [ ] PKI: `bao list pki_int/roles` shows `internal-services`
- [ ] Transit: `bao list transit/keys` shows `cosign-harbor` and `app-data-encryption`
- [ ] SSH: `bao read ssh/roles/otp-baremetal` returns the role
- [ ] Database: engine is enabled (no connections yet — expected)
- [ ] KV v2: `bao secrets list` shows `secret/` at version 2
- [ ] Audit: `bao audit list` shows the file device; `/opt/openbao/audit/audit.log` present and rotating on all three nodes

#### Authentication

- [ ] AppRole login for `terraform` succeeds and returns a token with only `terraform-provisioner` policy
- [ ] AppRole login for `ansible` succeeds and returns a token with only `ansible-orchestrator` policy
- [ ] Both `role_id`s and `secret_id`s stored in `pass`, paper recovery keys in physical safe, root CA cert in `pass`

#### Hygiene

- [ ] No plaintext Vault credentials anywhere on workstation (`shred -u` confirmed on all generated key files)
- [ ] GCP KMS service account has *only* `roles/cloudkms.cryptoKeyEncrypterDecrypter` on *only* the `vault-unseal-key` resource (verify in GCP IAM Policy Analyzer or `gcloud projects get-iam-policy`)
- [ ] Vault VM firewalls (`ufw`) restrict API access to the three workload VLANs only

When all of the above pass: **Tier 0 is complete.** The substrate exists. Everything from Tier 1 onward stands on it.
