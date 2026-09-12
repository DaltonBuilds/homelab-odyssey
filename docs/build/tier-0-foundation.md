[← Docs index](../README.md) · **Operation Long Haul v5**

[← Network Reference](02-network-reference.md)  ·  [Tier 1 · Platform Provisioning →](tier-1-platform-provisioning.md)

---

## Tier 0 — Foundation

**Purpose:** Establish the substrate everything else depends on. By the end of Tier 0, you have all seven physical hypervisors online (pve-01/02 standing platform + dev, pve-05 spare + vault-02 host, pve-06/07/08 hosting the homelab-prod node VMs, pve-09 GPU + build + mgmt-02 host), a redundant BGP routing fabric, and a fully-configured OpenBao HA cluster with PKI, Transit, SSH OTP, and Database engines ready to issue credentials. **No Kubernetes exists yet.** Nothing in higher tiers can begin until Tier 0 verification passes.

**Why this tier exists separately:** v3 treated Vault as an application — Phase 6, after the cluster existed. That created a circular dependency (Ansible needed secrets to build the cluster; Vault lived in the cluster Ansible built). v4 inverts this: Vault is foundation, every later tier consumes it.

### Tier 0 Phases

- **0.1** — Proxmox installation on all seven physical hypervisors *(v5.4: pve-09 added)*
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

**Goal:** Every physical machine running Proxmox VE, accessible from workstation, ready to host VMs. *(v5.2: this now includes the M920q trio and M920x #2, which formerly ran bare-metal Ubuntu — see ADR-008. v5.4: and pve-09, the former workstation tower — see ADR-011.)*

#### pve-01 (existing M920 SFF, 64GB / 1TB)

If already installed from v3, skip to verification. Otherwise follow the v3 Phase 0 procedure.

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
- [ ] Set DHCP reservation on edge router for `192.168.40.55`
- [ ] Upload Ubuntu Server 24.04 ISO and VyOS LTS ISO to local storage

#### pve-05 (M920x #2, 32GB / 1TB — spare + quorum) *(v5.2)*

Formerly the unassigned "spare" M920x. Now a standing Proxmox host: idle capacity plus the home of the relocated **`vault-02`** *(v5.4: decided — `mgmt-02` went to pve-09 instead, so the two relocated quorum nodes sit on different hosts. See ADR-011 and the resolved failure-domain note in Network Architecture.)*

- [ ] Install Proxmox VE on the 1TB SSD, ext4 root
- [ ] Management IP `192.168.40.58`, gateway `192.168.40.1` (UniFi, confirmed); hostname `pve-05`; apt update + dist-upgrade
- [ ] Configure `vmbr0` to accept trunked VLAN 40 (add VLAN 50 if you place a prod-tier VM here)
- [ ] Upload Ubuntu Server 24.04 cloud image to local storage
- [ ] DHCP reservation on the edge router

#### pve-06 / pve-07 / pve-08 (3× M920q, 16GB / 512GB each — homelab-prod node hosts) *(v5.2)*

Each M920q hosts exactly **one** homelab-prod node VM (pve-06 → prod-cp-01, pve-07 → prod-w-01, pve-08 → prod-w-02), provisioned by OpenTofu in Phase 1.3 — one VM per box preserves the per-machine failure boundary the bare-metal layout had, while making the node reproducible and snapshottable.

- [ ] Install Proxmox VE on each 512GB SSD, ext4 root (no ZFS — keeps host RAM overhead to ~1–1.5GB on these 16GB boxes)
- [ ] Management IPs: `192.168.40.59` (pve-06), `192.168.40.64` (pve-07), `192.168.40.65` (pve-08), gateway `192.168.40.1` (UniFi, confirmed)
- [ ] Hostnames `pve-06` / `pve-07` / `pve-08`; apt update + dist-upgrade
- [ ] Configure `vmbr0` to accept trunked VLAN 50 (the homelab-prod cluster VLAN) — and VLAN 40 for the management interface
- [ ] Upload Ubuntu Server 24.04 cloud image to local storage on each
- [ ] DHCP reservations on the edge router for all three

#### pve-09 (Tower — Ryzen 9 7900X, 64GB / 2× 1TB NVMe / RTX 5070) *(v5.4)*

The former home-office workstation, reassigned to the fleet (ADR-011). This is the fleet's only GPU host, only ZFS-root host, and the most capable single machine in the inventory. It carries three standing roles: `mgmt-02` (relocated quorum node), the amd64 build host, and — from Tier 5 — `prod-gpu-01`.

**Pre-install (do these before flashing — order matters):**

- [ ] Confirm nothing on the existing Fedora install is needed. *(Confirmed at planning time: nothing to rescue. Both NVMe sticks get wiped.)*
- [ ] **Verify both NVMe sticks are the same model and capacity** — a ZFS mirror across mismatched sticks works but sizes to the smaller and inherits the slower one's write characteristics
- [ ] **Verify both M.2 slots run at full lanes with the RTX 5070 populated.** On AM5, the second M.2 is often chipset-attached; a mirror across one CPU-attached and one chipset-attached slot is workable but caps mirror write throughput. Check the board manual's lane-sharing table — this is a "know it now" item, not a blocker
- [ ] Enable **IOMMU / AMD-Vi** and **SVM** in UEFI; disable Secure Boot (or enroll keys) as required for the passthrough path
- [ ] Note the onboard NIC's link speed (Ryzen 7000 boards commonly ship 2.5GbE). If it is 2.5GbE and the switch port is 1GbE, that ceiling matters later if a Garage replica or nfs-01 lands here

**Install:**

- [ ] Install Proxmox VE selecting **ZFS RAID1 (mirror)** across both 1TB NVMe sticks — **~900GB practically usable** after ZFS overhead. *(Deliberate exception to ADR-008's ext4-on-single-disk pattern; rationale and the full space budget are in ADR-011.)*
- [ ] **Plan the space budget before provisioning VMs.** ~50GB Proxmox + 60GB `mgmt-02` + ~200GB build VM + 250GB `prod-gpu-01` leaves roughly 340GB for snapshots and the local model cache. This pool is adequate but not roomy — keep model weights on Garage/NFS with a bounded local cache, and size any future Garage replica here deliberately rather than assuming it's free
- [ ] Management IP `192.168.40.66`, gateway `192.168.40.1` (UniFi, confirmed); hostname `pve-09`; apt update + dist-upgrade
- [ ] **Cap the ARC:** write `options zfs zfs_arc_max=10737418240` (10GB) to `/etc/modprobe.d/zfs.conf`, then `update-initramfs -u` and reboot. 64GB shared between `mgmt-02`, a build VM, `prod-gpu-01`, and an uncapped ARC will otherwise get tight
- [ ] Configure `vmbr0` to accept trunked VLANs **40 and 50** (40 for `mgmt-02` and management, 50 for `prod-gpu-01`)
- [ ] Upload the Ubuntu Server 24.04 cloud image **and** the Talos `metal-amd64.iso` (this host runs both a Talos mgmt node and Ubuntu-based RKE2/build VMs)
- [ ] DHCP reservation on the edge router

**GPU passthrough prep** *(config only — no VM consumes the GPU until Tier 5):*

- [ ] Add `amd_iommu=on iommu=pt` to the kernel cmdline; `update-grub`; reboot
- [ ] Confirm the GPU sits in its own IOMMU group: `for d in /sys/kernel/iommu_groups/*/devices/*; do echo "$(basename $(dirname $(dirname $d))) $(basename $d)"; done | sort -n`
- [ ] Blacklist the host drivers (`nouveau`, `nvidia`) and bind `vfio-pci` to the GPU's PCI IDs (both the VGA function and its HDMI audio function) via `/etc/modprobe.d/`
- [ ] `lspci -nnk` shows `Kernel driver in use: vfio-pci` on the GPU after reboot
- [ ] **Do not install NVIDIA drivers on the Proxmox host** — the driver belongs inside the guest that receives the passthrough

> **Sequencing note.** Roles 1–2 (mgmt-02, build host) need only the install above. The GPU is *prepared* here and *consumed* in Tier 5. Deliberately do not make `prod-gpu-01` the first node you prove the RKE2 CIS profile on — GPU Operator driver container + `profile: cis` + SELinux enforcing on a fresh Blackwell driver branch is a known-friction stack, and you want the CIS profile already working on boring hardware (pve-06/07/08) before adding a new variable. See ADR-011.

#### Verification

- [ ] All seven Proxmox web UIs load from workstation
- [ ] `ping` succeeds to every hypervisor management IP (`.50`, `.55`, `.58`, `.59`, `.64`, `.65`, `.66` on VLAN 40)
- [ ] Ubuntu 24.04 cloud image + VyOS/Talos ISOs visible in the relevant Proxmox storage pools
- [ ] All seven hosts joined to `homelab-pve`; `pvecm status` reports seven nodes, seven expected votes, quorum four, and `Quorate: Yes`; no HA-managed guests
- [ ] `zpool status` on pve-09 shows a healthy 2-way mirror; `arc_summary` reflects the capped `zfs_arc_max` *(v5.4)*
- [ ] `lspci -nnk` on pve-09 shows the RTX 5070 bound to `vfio-pci` *(v5.4)*

---

### Phase 0.2: Switch / VLAN Configuration

**Goal:** The managed switches trunk all required VLANs to every Proxmox host and your workstation.

This is the most boring and most critical phase. BGP, cluster separation, everything downstream assumes VLAN trunking is correct.

> **Topology (v5.4):** two managed UniFi switches — an upstream switch feeding the home-office wall jacks, and an 8-port switch in the office. **pve-09 lands on its own office jack, not on the office switch**, so its trunk is configured on the upstream switch and must survive the inter-switch path. Getting this right on the office switch alone leaves pve-09 reachable on the native VLAN while silently missing 40/50 — which surfaces much later as a VM that never gets an address. Verify the jack, not just the switch port. Also sanity-check port count: seven hypervisors plus the workstation plus the edge uplink is nine endpoints across the two switches.

- [ ] Identify port assignments across **both** switches for pve-01, pve-02, pve-05, pve-06, pve-07, pve-08, and pve-09, the workstation, and the uplink to the edge router *(v5.2: five more hypervisor ports than the two-host layout — the M920q prod hosts pve-06/07/08 in particular must trunk VLAN 50. v5.4: pve-09 added, on an office jack fed by the upstream switch.)*
- [ ] In UniFi Port Manager, set hypervisor ports to **Native VLAN 40** and custom **Tagged VLAN Management** for guest VLANs: pve-01/02 need 50 and 60 for the VyOS routers; pve-06/07/08/09 need 50; pve-05 needs no extra guest VLAN initially. Add 70 to the chosen ephemeral host and every upstream link before a drill. Workstation access port: native VLAN 10.
- [ ] Confirm the **inter-switch link** carries 10/40/50/60 and matches native VLAN settings at both ends; add 70 before ephemeral use. Preserve existing switch/AP management.
- [ ] Create VLAN interfaces on the edge router for VLANs 50 and 60 (if not already present for 10/40)
- [ ] Add temporary DHCP scopes on VLANs 50 and 60 (you'll replace with static cloud-init later; useful for first-boot testing)
- [ ] Add static routes on edge router (these point at VyOS VRRP IP once it's up; for now, you can defer until Phase 0.3 is complete):
  - `192.168.50.240/28 → 192.168.40.12`
  - `192.168.60.240/28 → 192.168.40.12`
  - `192.168.40.240/28 → 192.168.40.12`

#### Verification

- [ ] From a test VM on pve-01 tagged to VLAN 50, can reach the edge router and the internet
- [ ] From a test VM on pve-02 tagged to VLAN 60, same
- [ ] **From a test VM on pve-09 tagged to VLAN 50, same** — this is the one that proves the office-jack trunk, so do not skip it *(v5.4)*
- [ ] Delete test VMs

> **Blog note:** This phase rarely makes it into homelab writeups but is exactly the kind of L2 hygiene that breaks "production-grade" claims when skipped. Document your switch model and config — the next time you replace it, future-you will thank you.

---

> ### ⏱ Interstitial: Stand up Huly now (project tracking) — *recommended*
>
> With Proxmox up (Phase 0.1) and the management VLAN reachable (Phase 0.2), you have exactly what you need to run **Huly**, the project-management system for this build — and nothing else has to exist yet. Standing it up here means the rest of Operation Long Haul is tracked as real work items (Milestones → Epics → Stories/Spikes → Tasks) from the very first phase.
>
> - **Follow:** [`../bootstrap/huly-bootstrap.md`](../bootstrap/huly-bootstrap.md) — one Ubuntu VM, Docker Compose, LAN-only.
> - **Then seed the backlog** from [`../../huly/work-breakdown.md`](../../huly/work-breakdown.md) (Tier 0 is fully broken down; later tiers are skeletoned).
> - **Why here, and why manual:** Huly is a *deliberate second manual-provisioning exception* — a sibling to the hand-provisioned OpenBao VMs in Phase 0.4. It comes up **before** OpenBao and OpenTofu exist, so it cannot yet be provisioned the "proper" IaC way. That's fine and intentional; it is bootstrap infrastructure, later migrated onto `homelab-mgmt` (see the bootstrap doc's *Future Migration*). Treat its generated `huly_v7.conf` as sensitive — never commit it.
>
> This is optional in the strict dependency sense (Tier 0 does not technically require it), but it is the intended workflow. Do just enough Huly to make Tier 0 work items usable, then continue with Phase 0.3.

---

### Phase 0.3: VyOS BGP Fabric

**Goal:** Two VyOS routers running, peered with each other via iBGP, providing a VRRP next hop for the LoadBalancer routes on VLAN 40, ready to peer with Cilium speakers in Tier 2.

**Confirmed gateway correction (2026-09-12):** UniFi owns `192.168.40.1`; the planned VyOS VLAN 40 VIP is now `192.168.40.12`. Before assigning .12, confirm it is unused in UniFi clients/reservations and exclude it from DHCP. Proxmox and platform guests retain UniFi as their gateway. Before deploying the VLAN 50/60 VRRP examples below, verify their .1 addresses are not already owned by UniFi; their ownership has not yet been confirmed.

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
set high-availability vrrp group VLAN40 address 192.168.40.12/24

set high-availability vrrp group VLAN50 interface eth0.50
set high-availability vrrp group VLAN50 vrid 50
set high-availability vrrp group VLAN50 priority 200
set high-availability vrrp group VLAN50 address 192.168.50.1/24

set high-availability vrrp group VLAN60 interface eth0.60
set high-availability vrrp group VLAN60 vrid 60
set high-availability vrrp group VLAN60 priority 200
set high-availability vrrp group VLAN60 address 192.168.60.1/24

# Default route to the confirmed UniFi VLAN 40 gateway
set protocols static route 0.0.0.0/0 next-hop 192.168.40.1

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
- [ ] From your workstation, `ping 192.168.40.12` succeeds (you're hitting the VRRP virtual IP)
- [ ] Test failover: power off bgp-01 in Proxmox → bgp-02 becomes VRRP master within ~3 seconds → `ping 192.168.40.12` continues working. Power bgp-01 back on, master role returns to it.
- [ ] Keep all Proxmox host gateways at `192.168.40.1` (UniFi); do not move them to the VyOS VIP.

> **Blog note — VRRP vs ECMP:** A more sophisticated production setup uses ECMP with both routers active simultaneously rather than VRRP active/passive. For homelab scale, VRRP is dramatically simpler to reason about and the failover latency is acceptable. Document this tradeoff in an ADR — it's exactly the kind of "I considered X but chose Y because" reasoning interviewers probe.

---

### Phase 0.4: Vault VM Provisioning (Bootstrap Mode)

**Goal:** Three Vault VMs (vault-01/02/03) running Ubuntu Server 24.04, hardened baseline, OpenBao binary installed (pinned 2.6.x), ready to initialize.

> **Bootstrap pragmatism:** We're going to hand-provision these three VMs in the Proxmox UI rather than via Terraform. Reason: Terraform will be Vault-authenticated starting in Tier 1, and the Vault that authenticates it has to exist first. After Tier 0 completes, all future infrastructure provisioning (including replacing or scaling these Vault VMs) goes through Terraform-with-Vault. This is the *only* manual provisioning in the entire build.

> **OpenBao naming convention (read once — applies to the whole doc):** The secrets server is **OpenBao** (Linux Foundation fork of HashiCorp Vault, API-compatible — ADR-006). Everything else keeps the familiar Vault naming on purpose: hostnames stay `vault-01/02/03`, DNS stays `vault.homelab.internal`, `pass` paths stay `homelab/vault/*`, and prose references to "Vault" / "the Vault tier" mean this OpenBao cluster. Only three things differ day-to-day: the CLI is **`bao`**, the systemd unit is **`openbao`**, and config lives in **`/etc/openbao/`**. Env vars stay `VAULT_*` throughout — the `bao` CLI falls back to them when `BAO_*` is unset, and every downstream client (Terraform provider, Ansible `hashi_vault`, ESO, cert-manager, cosign) expects them anyway.

#### 0.4a — Create the three Vault VMs

For each (specs are identical):

| VM         | Hypervisor | vCPU | RAM | Disk | IP             |
| ---------- | ---------- | ---- | --- | ---- | -------------- |
| vault-01   | pve-01  | 2    | 2GB | 20GB | 192.168.40.20  |
| vault-02   | **pve-05** *(v5.4: was pve-01)* | 2    | 2GB | 20GB | 192.168.40.21  |
| vault-03   | pve-02  | 2    | 2GB | 20GB | 192.168.40.22  |

> **One Raft node per hypervisor *(v5.4 — ADR-011)*.** `vault-02` moved off pve-01 so no single hypervisor hosts two of the three OpenBao nodes. Do not "simplify" this back onto pve-01 while hand-creating the VMs — the whole point of the Tier 1 single-host-loss drill is that this spread holds. `mgmt-02` moves to pve-09 in the same change.

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

- [ ] All seven Proxmox hosts operational, accessible from workstation, joined to `homelab-pve` with healthy quorum and no HA-managed guests *(v5.4: pve-09 included — plus a healthy ZFS mirror and the GPU bound to `vfio-pci`)*
- [ ] Both switches use the Phase 0.2 native/tagged port matrix; inter-switch links carry 10/40/50/60 (and 70 when used), with matching native VLAN settings. Test guest traffic through pve-09’s actual wall jack.
- [ ] `ping 192.168.40.12` from workstation succeeds (VRRP virtual IP responds)

#### BGP fabric

- [ ] bgp-01 and bgp-02 both running on separate hypervisors
- [ ] iBGP session between them is `Established`
- [ ] VRRP failover test passes (kill master → backup takes over within 5 seconds → restore master → role returns)
- [ ] Edge router has static routes for all three LB pools pointing to `192.168.40.12`

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

