[← Docs index](../README.md) · **Operation Long Haul v5**

**Proxmox cluster baseline (ADR-012):** all seven hosts share `homelab-pve`. Keep explicit target-node placement, use cluster-wide unique VM/CT IDs, and reconcile cluster-scoped users/tokens once. Existing endpoint examples can target different members of the same cluster; local storage is still node-specific (`local-lvm` on ext4 hosts, `local-zfs` on pve-09).

[← Tier 0 · Foundation](tier-0-foundation.md)  ·  [Tier 2 · Platform Services →](tier-2-platform-services.md)

---

# Tier 1 — Platform Provisioning

**Purpose:** With Vault as substrate, build out every remaining piece of infrastructure declaratively. By the end of Tier 1, you have all VMs provisioned via Terraform (Vault-authenticated), all hosts configured via Ansible (Vault-authenticated, zero `ansible-vault`), three RKE2 clusters operational with CIS profile + encryption-at-rest + audit logging, and storage tier (NFS+ZFS, Garage) online.

**Why this tier exists separately from Tier 0:** Tier 0 was about *the substrate that secrets management itself depends on*. Tier 1 is the first tier that *consumes* Tier 0. Everything in Tier 1 demonstrates the right way to use Vault from the very tools that provision infrastructure.

**What changes from v3:**
- Terraform reads its provider credentials from Vault at runtime — no `terraform.tfvars` with secrets, no env vars set by hand
- Ansible authenticates to Vault via AppRole — no `ansible-vault` encrypted files, no `--ask-vault-pass`
- RKE2 replaces k3s with CIS profile mode enabled, secrets encryption-at-rest in etcd, and a real audit policy
- Three clusters instead of two: **homelab-prod** (prod, all VMs — one per M920q on pve-06/07/08 plus prod-w-03 on pve-01), **homelab-dev** (dev/staging, all VMs on M920x), **homelab-mgmt** upgraded from 1-node k3s to 3-node Talos HA *(v5; v5.2: prod is no longer bare metal — ADR-008)*
- Hosts enroll with Vault SSH OTP for privileged operations (deferred config from Phase 0.9 lands here)

## Tier 1 Phases

- **1.1** — Terraform refactor: Vault-authenticated provider chain
- **1.2** — Ansible refactor: Vault lookups replace `ansible-vault`
- **1.3** — VM provisioning via Terraform (all workload + mgmt VMs, **including all four homelab-prod nodes** — v5.2 — **plus `prod-gpu-01` on pve-09** — v5.4)
- **1.4** — *Removed (v5.2).* Formerly baremetal preparation for the 3 prod nodes; now that they are Proxmox VMs, they are provisioned in 1.3 and configured by the same Ansible/hardening path as every other host. Section retained as a stub for traceability.
- **1.5** — OS hardening playbook (CIS-adjacent baseline, all hosts)
- **1.6** — Vault SSH OTP enrollment (`vault-ssh-helper` everywhere)
- **1.7** — Storage tier: NFS+ZFS VM, Garage S3 LXC
- **1.8** — RKE2 installation: homelab-prod (prod, 4 nodes; `prod-gpu-01` provisioned but joined in Tier 5 — v5.4)
- **1.9** — RKE2 installation: homelab-dev (dev/staging, 3 nodes, all VMs)
- **1.10** — Talos installation: homelab-mgmt (3 nodes HA, all VMs)
- **1.11** — Etcd **+ OpenBao** snapshot off-host replication (Garage + AWS S3 with Object Lock) *(v5.1: OpenBao Raft snapshots added)*
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
    ├── homelab-prod/                      # all 4 prod VMs: prod-cp-01/w-01/w-02 (pve-06/07/08) + prod-w-03 (pve-01)
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

> **State backend note:** v3 used local state. v5 keeps local state with explicit backup discipline (committed encrypted state snapshots, or eventual migration to Garage S3 backend in Tier 2 once Garage exists). For Tier 1, local state is fine — we'll add the S3 backend once Garage is online in Phase 1.7.

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

# NOTE (v5.1): the server is OpenBao, but the hashicorp/vault provider remains
# the supported Terraform client — OpenBao is API-compatible. Address, auth_login,
# and vault_* data sources work unchanged.
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
# Create the automation token once in homelab-pve and assign the required ACLs.
# Membership shares users/tokens; scope permissions to the intended resources.

# Then write them into Vault under the path the Terraform provider expects
bao kv put secret/terraform/proxmox \
  endpoint="https://192.168.40.50:8006/" \
  api_token="root@pam!terraform=<the-token-secret>"

# Cloud-init SSH key for new VMs (your workstation's public key)
bao kv put secret/terraform/cloud-init \
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
tofu plan
tofu apply
```

#### Verification

- [ ] `tofu init` in any environment directory succeeds
- [ ] `tofu plan` after `source scripts/vault-login.sh` shows the provider authenticating to Vault and reading the Proxmox token without error
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
│   ├── homelab-prod/                     # VMs: prod-cp-01, prod-w-01, prod-w-02 (pve-06/07/08), prod-w-03 (pve-01)
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
│   ├── 32-rke2-workloads.yml   # mgmt is Talos (talosctl, not Ansible)
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

Ansible itself authenticates to Vault via env vars set by the wrapper script. Each `hashi_vault` lookup automatically uses `VAULT_ADDR`, `VAULT_ROLE_ID`, `VAULT_SECRET_ID` from the environment. The `community.hashi_vault` collection is OpenBao-compatible (same API, same env vars) — no changes needed.

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
bao kv put secret/ansible/sudo-password password="<strong-password-generated-here>"

# GitHub deploy keys for cloning gitops repo from inside cluster nodes (used in Tier 2)
bao kv put secret/ansible/github-deploy-key \
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

**Goal:** All Tier 1 VMs (storage, homelab-mgmt, homelab-dev workers, and **all four homelab-prod nodes** — v5.2 — **plus `prod-gpu-01` on pve-09, provisioned here but joined in Tier 5** — v5.4) created via Terraform with cloud-init bootstrap. Reproducible, version-controlled, Vault-authenticated.

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

#### 1.3b — Environment: homelab-prod (all four nodes) *(v5.2)*

Before v5.2 this env provisioned only prod-w-03 (the sole prod VM); the three M920q were bare metal. Now every prod node is a VM: prod-cp-01/w-01/w-02 each get a dedicated M920q host (pve-06/07/08 — one VM per box), and prod-w-03 stays on pve-01. Each M920q VM takes ~14GB of its host's 16GB, leaving ~1.5GB for the ext4 Proxmox host.

```hcl
# environments/homelab-prod/main.tf
locals {
  homelab_prod_nodes = {
    prod-cp-01 = { node = "pve-06", ip = "192.168.50.30", role = "control-plane", cpu = 4, mem = 14336, disk = 200 }
    prod-w-01   = { node = "pve-07", ip = "192.168.50.31", role = "worker",        cpu = 4, mem = 14336, disk = 200 }
    prod-w-02   = { node = "pve-08", ip = "192.168.50.32", role = "worker",        cpu = 4, mem = 14336, disk = 200 }
    prod-w-03   = { node = "pve-01", ip = "192.168.50.33", role = "worker",        cpu = 4, mem = 8192,  disk = 80  }  # shares the busy 64GB pve-01
    # v5.4 (ADR-011) — GPU worker on the tower. Provisioned here; the GPU is not
    # attached and the node is not joined to the cluster until Tier 5. Tainted on
    # join so nothing schedules here by accident.
    prod-gpu-01 = { node = "pve-09", ip = "192.168.50.34", role = "worker",        cpu = 8, mem = 32768, disk = 250 }
  }
}

data "vault_kv_secret_v2" "cloud_init" {
  mount = "secret"
  name  = "terraform/cloud-init"
}

module "homelab_prod_node" {
  source   = "../../modules/proxmox-vm"
  for_each = local.homelab_prod_nodes

  name           = each.key
  description    = "homelab-prod ${each.value.role} (RKE2)"
  tags           = ["homelab-prod", "rke2-${each.value.role}", "v5"]
  proxmox_node   = each.value.node
  cpu_cores      = each.value.cpu
  memory_mb      = each.value.mem
  disk_size_gb   = each.value.disk
  datastore_id   = "local-lvm"
  cloud_image_id = "local:iso/ubuntu-24.04-server-cloudimg-amd64.img"
  vlan_id        = 50
  ip_address     = each.value.ip
  gateway        = "192.168.50.1"
  dns_servers    = ["192.168.40.1", "1.1.1.1"]
  ssh_public_key = data.vault_kv_secret_v2.cloud_init.data["ssh_authorized_keys"]
}
```

> **One VM per M920q — why not pack more?** Keeping a single prod node per physical box preserves the failure boundary the bare-metal layout had (one hardware failure = one lost K8s node, which the cluster tolerates) while gaining reproducibility, snapshots, and noVNC console. Bin-packing multiple prod nodes onto one M920q would reintroduce a correlated-failure domain — don't.

> **`prod-gpu-01` sizing and staging *(v5.4 — ADR-011)*.** It gets 8 vCPU / 32GB / **250GB**. The disk is deliberately modest: pve-09's mirror yields only **~900GB usable** (2× 1TB, mirrored), which after Proxmox (~50GB), `mgmt-02` (60GB), and the build VM (~200GB) leaves roughly 340GB for snapshots *and* the local model cache. So **model weights live on Garage/NFS with a bounded local cache**, not staged wholesale on this VM's disk — 250GB is sized for the OS, container images, and a working cache. If model-serving genuinely needs more local NVMe, that is the signal to add disks or a NAS (see [Future Upgrades](future-upgrades.md)), not to grow this VM until the pool is full. Two staging rules:
>
> 1. **The GPU is not attached at this phase.** Provision the VM here with the rest of the fleet, but add the `hostpci0` passthrough entry and join the node to the cluster in Tier 5. Roles 1–2 of pve-09 (`mgmt-02`, build host) do not need the GPU and should not wait on it.
> 2. **Taint on join** so the general workload pool never lands here:
>
> ```yaml
> # RKE2 config on prod-gpu-01
> node-taint:
>   - "nvidia.com/gpu=true:NoSchedule"
> node-label:
>   - "topology.kubernetes.io/zone=homelab-prod-gpu"
>   - "node.homelab.internal/pool=gpu"
>   - "nvidia.com/gpu.present=true"
> ```
>
> Tier 5 workloads then opt in with a matching `toleration` plus `nodeSelector`. This is the "node pool by resource type" pattern — with the caveat from ADR-011 that the pool has exactly one member, and in-cluster GPU sharing is device-plugin time-slicing with no memory or fault isolation.

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
  tags           = ["homelab-dev", "rke2-${each.value.role}", "v5"]
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
    mgmt-02  = { ip = "192.168.40.61", proxmox = "pve-09", cpu = 4, mem = 6144, disk = 60 }  # v5.4: was pve-01 (ADR-011)
    mgmt-03   = { ip = "192.168.40.62", proxmox = "pve-02", cpu = 4, mem = 6144, disk = 60 }
  }
}

module "mgmt_node" {
  source   = "../../modules/proxmox-vm"
  for_each = local.homelab_mgmt_nodes

  name           = each.key
  description    = "homelab-mgmt Talos HA control-plane node"
  tags           = ["homelab-mgmt", "talos-controlplane", "v5"]
  proxmox_node   = each.value.proxmox
  cpu_cores      = each.value.cpu
  memory_mb      = each.value.mem
  disk_size_gb   = each.value.disk
  # ... (same pattern as homelab-dev)
  vlan_id        = 40
  ip_address     = each.value.ip
  gateway        = "192.168.40.1"
  # v5: boot the Talos metal image, NOT the Ubuntu cloud image. No cloud-init user,
  # no qemu-guest-agent reliance for config — Talos is configured via talosctl in Phase 1.10.
  boot_image     = "local:iso/talos-metal-amd64.iso"
  agent_enabled  = false
}
```

> **v5 — these are Talos nodes.** They are provisioned as VMs here but configured declaratively in Phase 1.10 via `talosctl`, not by Ansible. They have no SSH, are excluded from `roles/hardening` (1.5) and Vault SSH OTP (1.6), and carry no cloud-init OS user.

> **HA topology *(rewritten in v5.4 — ADR-011)*.** The three mgmt nodes sit on **three different hypervisors**: `mgmt-01` → pve-01, `mgmt-02` → **pve-09**, `mgmt-03` → pve-02. Any single hypervisor loss leaves 2 of 3 alive and etcd keeps quorum. This is already set in the `homelab_mgmt_nodes` map above — note the key there is `proxmox`, not `node` as in the homelab-prod map, so `mgmt-02` must read `proxmox = "pve-09"`.
>
> *Superseded reasoning, kept for traceability:* through v5.3 this was 2 nodes on pve-01 and 1 on pve-02, documented as deliberate "asymmetric availability" on the grounds that pve-01 was the prod-adjacent host. That was a rationalization of a hardware constraint — with only two hypervisors there was nowhere else to put the third node. The constraint disappeared at v5.2 (Proxmox everywhere) and the concentration was left as an open decision through v5.3; v5.4 closes it. `vault-02` moves to pve-05 in the same change, so the two relocated quorum nodes land on *different* hosts rather than both on one. See the resolved failure-domain note in [Network Reference](02-network-reference.md).

#### 1.3e — Environment: storage

```hcl
# environments/storage/main.tf
module "nfs_server" {
  source = "../../modules/proxmox-vm"

  name           = "nfs-01"
  description    = "ZFS-backed NFS for cluster persistent storage"
  tags           = ["storage", "v5"]
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
  tags         = ["storage", "garage", "v5"]

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

- [ ] `tofu plan` for each environment shows the expected number of resources
- [ ] `tofu apply` succeeds for each environment in this order: `storage` → `mgmt` → `homelab-dev` → `homelab-prod`
- [ ] All VMs reachable via SSH from workstation (`ssh dalton@<ip>` works for every host)
- [ ] No secrets in any tfvars or state file (`grep -r 'api_token\|password' .` returns only the variable declarations and Vault data sources)
- [ ] Tag all VMs with `v5` in Proxmox UI for easy bulk-management

---

### Phase 1.4: ~~Baremetal Preparation~~ — Removed *(v5.2)*

> **This phase no longer exists.** Through v5.1, prod-cp-01/prod-w-01/prod-w-02 were bare-metal M920q machines that needed a separate manual Ubuntu install and prep step here. As of **ADR-008**, each M920q runs Proxmox (pve-06/07/08) and its prod node is an OpenTofu-provisioned VM created in **Phase 1.3** — identical cloud-init bootstrap to every other VM. There is nothing bespoke left to do:
>
> - **Provisioning** → Phase 1.3b (the `homelab-prod` env now covers all four nodes).
> - **Baseline packages / chrony / SSH key-only** → the `roles/common` play, same as every host. `qemu-guest-agent` *is* now wanted (they're VMs) and is enabled via the `agent { enabled = true }` block in the VM module.
> - **OS hardening** → Phase 1.5 (the CIS-adjacent playbook already targets the RKE2 nodes).
>
> The section number is retained as a stub so downstream cross-references and the phase list stay stable. Skip straight to Phase 1.5.

---

### Phase 1.5: OS Hardening Playbook

**Goal:** A single Ansible playbook hardens every host — all VMs now (v5.2), no bare metal left — to a CIS-adjacent baseline. Idempotent, re-runnable, drift-correcting.

> **Why "CIS-adjacent" instead of full CIS:** Full DISA STIG or CIS Level 2 hardening on a homelab introduces real toil for things you'll rarely need (mandatory FIPS modules, audit daemon retention, kernel boot parameters that break some hardware). We implement the *useful* portions and document what we skipped and why. That's the same engineering judgment you'd apply in a regulated environment — apply controls where they earn their cost.

> **Scope (v5):** This playbook targets the Ubuntu substrate VMs and the **RKE2 workload nodes** only. The Talos `homelab-mgmt` nodes are excluded — Talos is immutable and has no shell or package manager to harden; its security posture comes from the machine config in Phase 1.10 and Talos's built-in KSPP/CIS defaults.

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

> **Scope (v5):** SSH OTP applies to the Ubuntu substrate VMs and RKE2 nodes. The Talos `homelab-mgmt` nodes have no SSH daemon and are managed exclusively via `talosctl` (mutually authenticated with the Talos PKI from the cluster secret bundle in Vault) — there is nothing to enroll here for them.

#### 1.6a — Role: `roles/vault-ssh-helper`

The role's tasks (applied to every host):

1. Install `vault-ssh-helper` binary (download from HashiCorp releases, or vendor into Garage S3 once it exists). *(v5.1 note: vault-ssh-helper is MPL-2.0 and effectively in maintenance mode, but it only speaks the SSH-OTP verify API, which OpenBao implements identically — pin the release and vendor the binary.)*
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
bao write ssh/creds/otp-baremetal ip=192.168.50.30
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

OTP="$(bao write -field=key ssh/creds/otp-baremetal ip="$IP")"
sshpass -p "$OTP" ssh dalton@"$IP"
```

#### Verification

- [ ] OTP issuance via `bao write ssh/creds/otp-baremetal ip=192.168.40.20` returns a key
- [ ] SSH to a host using the OTP as password succeeds
- [ ] Re-using the same OTP fails (single-use enforcement)
- [ ] `vault audit list` shows audit device, and `tail -f /opt/openbao/audit/audit.log` shows OTP issuance events with timestamp + requester
- [ ] Public-key SSH still works for normal automation (Terraform, Ansible) — OTP is for *interactive privileged sessions*, not for routine programmatic access

---

### Phase 1.7: Storage Tier

**Goal:** NFS-backed persistent storage available to all clusters, plus S3-compatible object storage via Garage for Velero backups, Harbor blob storage, and Loki long-term retention.

#### 1.7a — NFS server (Ansible role: `roles/nfs-server`)

On `nfs-01` (192.168.40.51), provisioned in Phase 1.3:

1. Attach a second virtual disk in Proxmox if not already present (size to taste — 500GB minimum for v5 with three clusters)
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
   bao kv put secret/garage/velero-homelab-prod access_key=... secret_key=...
   bao kv put secret/garage/velero-homelab-dev      access_key=... secret_key=...
   bao kv put secret/garage/harbor            access_key=... secret_key=...
   # ...etc
   ```

#### 1.7c — `csi-driver-nfs` + the `nfs-csi` StorageClass *(v5.1 — gap fix)*

The pre-flight checklist promised "CSI via `csi-driver-nfs`" and every PVC in Tiers 2–3 asks for `storageClass: nfs-csi` (Prometheus, Alertmanager, Grafana, Loki, Tempo, Keycloak, Harbor) — but no phase ever installed the driver or created the class. Without this, those PVCs sit `Pending` forever.

Install per cluster **after** each cluster exists (i.e. revisit this step following Phases 1.8/1.9/1.10; it is listed here to keep the storage story in one place):

```bash
# Repeat with each kube context: homelab-prod, homelab-dev, homelab-mgmt
helm --kube-context homelab-prod repo add csi-driver-nfs \
  https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts

helm --kube-context homelab-prod upgrade --install csi-driver-nfs \
  csi-driver-nfs/csi-driver-nfs \
  -n kube-system \
  --version <latest>          # verify current stable at build time
```

StorageClass per cluster — each points at that cluster's own ZFS filesystem and matching export:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-csi
provisioner: nfs.csi.k8s.io
parameters:
  server: 192.168.40.51
  share: /tank/homelab-prod      # homelab-dev → /tank/homelab-dev; mgmt → /tank/mgmt
reclaimPolicy: Delete
volumeBindingMode: Immediate
mountOptions:
  - nfsvers=4.1
  - hard
  - noatime
```

> **Talos note:** the mgmt cluster needs no host-side NFS packages — `csi-driver-nfs` mounts from inside its own pods, which is exactly why it suits an immutable OS. Confirm the Talos machine config doesn't block the required `SYS_ADMIN` mount capability for the node plugin.

> **Not the default class:** deliberately no `storageclass.kubernetes.io/is-default-class` annotation — every PVC in this build names its class explicitly, so a forgotten `storageClassName` fails loudly instead of silently landing on NFS.

#### Verification

- [ ] From any host in VLAN 50: `showmount -e 192.168.40.51` lists `/tank/homelab-prod`
- [ ] Mount test: `mount -t nfs 192.168.40.51:/tank/homelab-prod /mnt && touch /mnt/test && umount /mnt`
- [ ] ZFS snapshot script runs successfully and `zfs list -t snapshot` shows snapshots being created
- [ ] Garage `garage status` shows healthy single-node cluster
- [ ] Garage S3 API reachable: `aws --endpoint http://192.168.40.53:3900 s3 ls` (after configuring `~/.aws/credentials` with one of the keys) shows the pre-created buckets
- [ ] *(after clusters exist)* `kubectl get sc nfs-csi` on each cluster; a scratch PVC binds and a pod writes to it, and the file appears under the matching `/tank/<cluster>` path on nfs-01 *(v5.1)*

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

> **WireGuard pod-to-pod encryption:** v3 didn't enable this. v5 does. The performance hit is small (~5-10% throughput on a homelab), and "all east-west traffic encrypted at the network layer" is a strong defense-relevant property. Same key principle as TLS-everywhere but at L3.

#### 1.8c — Install RKE2 on prod-cp-01

The `roles/rke2-control-plane` Ansible role:

1. Fetches RKE2 cluster token from Vault: `bao kv get -field=homelab_prod_token secret/ansible/rke2-tokens`
2. Writes `/etc/rancher/rke2/config.yaml`, `audit-policy.yaml`, and the Cilium HelmChartConfig
3. Runs the official RKE2 install script:
   ```bash
   curl -sfL https://get.rke2.io | INSTALL_RKE2_TYPE=server sh -
   ```
4. Enables and starts the systemd service: `systemctl enable --now rke2-server`
5. Waits for `/etc/rancher/rke2/rke2.yaml` to appear and validates the API is responding

> **Air-gap pattern hook:** v3 pulled RKE2 directly from GitHub. v5 prods (homelab-prod, homelab-dev) will pull from your local Garage mirror starting once Harbor exists in Tier 2. For Tier 1 bootstrap, the direct download is acceptable — note it as a known compromise. The dependency will be inverted in Tier 2 once Harbor proxies the RKE2 release artifacts.

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

### Phase 1.10: Talos Installation — Mgmt-Plane (3-Node HA)

The management plane is the one cluster we want boring and bulletproof, so it runs **Talos**: immutable, API-driven, no SSH. There is no Ansible role and no OS-hardening playbook for these nodes — the machine config *is* the node.

#### 1.10a — Generate cluster secrets and machine configs

```bash
# One-time: generate the cluster's secret bundle (PKI, tokens) — store in Vault, never Git
talosctl gen secrets -o talos-secrets.yaml
bao kv put secret/talos/homelab-mgmt secrets=@talos-secrets.yaml

# All three mgmt nodes are control plane; generate base configs from the secret bundle
talosctl gen config homelab-mgmt https://mgmt-api.homelab.internal:6443 \
  --with-secrets talos-secrets.yaml \
  --install-disk /dev/sda \
  --config-patch @patches/mgmt-common.yaml
```

`patches/mgmt-common.yaml` carries what this build cares about — Cilium as CNI (kube-proxy disabled), the apiserver audit policy that lived in RKE2's `config.yaml` in v4, and a Talos-native VIP for the HA endpoint (no external LB needed):

```yaml
machine:
  network:
    interfaces:
      - interface: eth0
        dhcp: false
        vip:
          ip: 192.168.40.63          # shared mgmt-api VIP, Talos-managed
  install:
    image: ghcr.io/siderolabs/installer:v1.x   # pin; swap to the FIPS image variant if/when entitled
cluster:
  network:
    cni:
      name: none                     # Cilium installed post-bootstrap (kube-proxy replacement)
  proxy:
    disabled: true
  apiServer:
    auditPolicy:
      apiVersion: audit.k8s.io/v1
      kind: Policy
      rules:
        - level: Metadata
```

> **Secrets discipline:** `talos-secrets.yaml` and the rendered machine configs contain cluster CA keys. They live in Vault (KV v2), are rendered to disk only transiently during apply, and are never committed — the same rule v4 applied to RKE2 tokens.

#### 1.10b — Apply config and bootstrap etcd

```bash
# mgmt-01/02/03 are the VMs from Phase 1.3d, booted into Talos maintenance mode
talosctl apply-config --insecure -n 192.168.40.60 --file controlplane.yaml -p @patches/mgmt-60.yaml
talosctl apply-config --insecure -n 192.168.40.61 --file controlplane.yaml -p @patches/mgmt-61.yaml
talosctl apply-config --insecure -n 192.168.40.62 --file controlplane.yaml -p @patches/mgmt-62.yaml

# Bootstrap etcd EXACTLY ONCE, against a single node
talosctl bootstrap -n 192.168.40.60 -e 192.168.40.60

# Pull the admin kubeconfig (replaces RKE2's rke2.yaml retrieval) — talk to the VIP
talosctl kubeconfig ./kubeconfig-mgmt -n 192.168.40.60 -e 192.168.40.63
```

Per-node patches (`patches/mgmt-60.yaml`, etc.) set only `machine.network.hostname` and the static IP; everything else is shared.

#### 1.10c — Install Cilium (kube-proxy replacement, BGP)

Talos ships no CNI (`cni: none`), so Cilium installs exactly as on the workload clusters — the same HelmChartConfig values from Phase 1.8b, with `k8sServiceHost` pointed at the mgmt VIP (`192.168.40.63`) and `kubeProxyReplacement: true`. (The mgmt cluster doesn't advertise LB IPs over BGP the way workload clusters do unless you expose services off-cluster; keep it internal-only unless a service needs external reach.)

#### Verification

- [ ] `talosctl -n 192.168.40.60 -e 192.168.40.63 health` reports the cluster healthy
- [ ] `kubectl --context homelab-mgmt get nodes` shows 3 nodes Ready, all `control-plane`
- [ ] `talosctl -n 192.168.40.60 etcd status` shows a healthy 3-member etcd
- [ ] `talosctl reboot -n 192.168.40.62` — quorum holds (2 of 3), node rejoins clean
- [ ] No SSH on any mgmt node (`ssh mgmt-01` refuses); `talosctl` is the only access path
- [ ] apiserver audit logs are being produced (per the audit policy in the machine config)

> **3-node etcd consideration:** Etcd wants odd-numbered quorum (3, 5, 7). With 3 control-plane nodes you can lose 1 and stay operational — the whole point of the v3→v4 mgmt HA upgrade, now carried forward on Talos.

---


### Phase 1.11: Etcd + OpenBao Snapshot Off-Host Replication

**Goal:** etcd snapshots from every cluster — **and Raft snapshots from the OpenBao cluster** — land in Garage S3 (off-hypervisor) and are replicated to AWS S3 with Object Lock (off-prem, tamper-evident). A hypervisor loss does not take cluster state with it, and a total Vault-tier loss does not take the PKI root, KV secrets, or Transit keys with it.

> **v5 — two snapshot mechanisms.** The **RKE2 workload clusters** (homelab-prod, homelab-dev) use RKE2's built-in S3 snapshotter (below). The **Talos `homelab-mgmt`** cluster has no RKE2 snapshotter; it is backed up with Talos-native etcd snapshots: a scheduled job runs `talosctl -n <mgmt-vip> etcd snapshot db.snapshot` and pushes the file to the same Garage bucket under `homelab-mgmt/`. A small CronJob on homelab-mgmt (using a Talos API credential from Vault) or a systemd timer on the workstation both work; the CronJob keeps it self-contained and is preferred.

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
etcd-s3-folder: homelab-prod   # or homelab-dev per cluster (mgmt uses Talos snapshots, see note)
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
bao kv put secret/rke2/etcd-snapshots \
  access_key=<key-id> \
  secret_key=<secret>
```

Folder structure ends up:
```
rke2-etcd-snapshots/
  homelab-prod/<snapshot-name>.zip      # RKE2 snapshotter
  homelab-dev/<snapshot-name>.zip       # RKE2 snapshotter
  homelab-mgmt/db.snapshot-<ts>         # Talos `talosctl etcd snapshot`
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
              image: harbor.homelab-prod.homelab.internal/rclone/rclone:latest
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
5. Verify with `kubectl get nodes` and smoke-test by triggering a Flux reconcile.

#### 1.11f — OpenBao Raft snapshot schedule *(v5.1 — gap fix)*

The highest-stakes state in the lab had no backup: the Transit signing keys are `exportable=false` (deliberately — Phase 0.8), so **a Raft snapshot is the *only* recovery path** for them; same for the PKI root private key and every KV secret. Velero can't see the Vault tier (it's outside Kubernetes) and Proxmox VM backups were never in scope. Fix: scheduled `bao operator raft snapshot save`, shipped off-host on the same Garage → AWS Object Lock rails as etcd.

A dedicated AppRole with the minimum capability:

```bash
bao policy write snapshot-agent - <<EOF
path "sys/storage/raft/snapshot" {
  capabilities = ["read"]
}
EOF

bao write auth/approle/role/snapshot-agent \
  token_policies="snapshot-agent" token_ttl=15m token_max_ttl=15m \
  secret_id_ttl=0 secret_id_num_uses=0
# role_id/secret_id → /etc/openbao/snapshot-approle.env on each Vault VM (root:root 0400)
# and a copy in pass under homelab/vault/snapshot-approle
```

Snapshot script + systemd timer (Ansible role `roles/openbao-snapshot`, applied to all three Vault VMs; only the current Raft leader acts):

```bash
#!/usr/bin/env bash
# /usr/local/bin/openbao-snapshot.sh — every 6h via systemd timer, offset from the etcd window
set -euo pipefail
export VAULT_ADDR=https://127.0.0.1:8200

# Followers exit quietly; sys/leader is unauthenticated
[ "$(bao read -field=is_self sys/leader)" = "true" ] || exit 0

source /etc/openbao/snapshot-approle.env   # ROLE_ID / SECRET_ID
export VAULT_TOKEN=$(bao write -field=token auth/approle/login role_id="$ROLE_ID" secret_id="$SECRET_ID")

SNAP="/tmp/openbao-$(date +%Y%m%d-%H%M).snap"
bao operator raft snapshot save "$SNAP"
rclone copyto "$SNAP" "garage:openbao-raft-snapshots/$(basename "$SNAP")"
shred -u "$SNAP"
```

Replication to AWS: extend the Phase 1.11d CronJob with a second `rclone sync garage:openbao-raft-snapshots aws:homelab-etcd-snapshots-dr/openbao/` step (Object Lock applies bucket-wide, so the snapshots inherit WORM retention).

> **Snapshot sensitivity:** a Raft snapshot contains the whole barrier — encrypted at rest with the master key, which is wrapped by the GCP KMS seal. A stolen snapshot alone is not plaintext, but treat it as secret-material anyway: dedicated bucket, write-only credentials, WORM retention.

#### 1.11g — OpenBao restoration runbook + drill *(v5.1)*

Lives in `homelab-gitops/docs/runbooks/openbao-restore.md`:

1. Stand up a fresh 3-VM cluster per Phases 0.4–0.5 (same pinned 2.6.x version), init with throwaway keys.
2. Pull the latest snapshot from Garage (AWS DR bucket if Garage is gone too); `bao operator raft snapshot restore <snap>` (add `-force` only if the target cluster's seal config differs).
3. Because the snapshot's master key is wrapped by the *same GCP KMS key*, auto-unseal resumes after restore — this is the payoff of the KMS seal surviving independently of the VMs. Verify: `bao status` unsealed, `bao secrets list` shows all engines.
4. Prove recovery, not just restore: issue a test cert from `pki_int`, and Transit-decrypt a ciphertext captured *before* the snapshot (keep one in `pass` as a canary).
5. Run this drill quarterly, alongside the Velero DR drill (Phase 4.14c).

#### Verification

- [ ] All three clusters writing snapshots to `garage:rke2-etcd-snapshots/<cluster>/` every 6 hours
- [ ] AWS S3 DR bucket receives snapshots within 30 minutes of Garage write (CronJob log shows success)
- [ ] Object Lock confirmed: `aws s3api delete-object --bucket homelab-etcd-snapshots-dr --key <snapshot>` returns AccessDenied
- [ ] Restoration runbook executed end-to-end on homelab-dev (controlled test): cluster killed, restored from snapshot, healthy within 15 minutes
- [ ] OpenBao: leader-only timer writes a new snapshot to `garage:openbao-raft-snapshots/` every 6h; replicated copy appears under `openbao/` in the AWS DR bucket (delete attempt returns AccessDenied)
- [ ] OpenBao restore drill executed once on scratch VMs: auto-unseal resumes post-restore, pre-snapshot Transit ciphertext decrypts, test cert issues

---

### Phase 1.12: Kubeconfig Management

`pass`/Chezmoi pattern from v3 carries forward, expanded:

```bash
# Three kubeconfigs, one per cluster
pass insert -m homelab/kubeconfigs/homelab-prod  < ~/.kube/homelab-prod-rke2.yaml
pass insert -m homelab/kubeconfigs/homelab-dev       < ~/.kube/homelab-dev-rke2.yaml
pass insert -m homelab/kubeconfigs/mgmt        < ~/.kube/mgmt-talos.yaml
pass git push
```

Chezmoi template at `~/.config/chezmoi/dot_config/private_kubeconfigs/kubeconfig.tmpl` merges the three into a single file with three labeled contexts (`homelab-prod`, `homelab-dev`, `homelab-mgmt`), set by `kubectx`. *(v5.1: the mgmt context was called `mgmt` in some places and `homelab-mgmt` in others — standardized on `homelab-mgmt` to match the cluster name.)*

```bash
kubectx homelab-prod   # context for prod
kubectx homelab-dev    # context for dev/staging
kubectx homelab-mgmt   # context for observability + identity
```

---

### Phase 1.13: Tier 1 Verification Gate

**Tier 1 is complete when every item below passes.** Tier 2 cannot begin until then.

#### Provisioning automation

- [ ] All VMs created via Terraform — `tofu state list` in each env shows expected resources
- [ ] All hosts (all VMs — v5.2) configured via Ansible — every playbook is idempotent (re-run shows no changes)
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

#### Etcd + OpenBao disaster recovery

- [ ] All three clusters write etcd snapshots to Garage `rke2-etcd-snapshots/<cluster>/` every 6h
- [ ] CronJob `etcd-snapshots-to-aws` running; AWS DR bucket receives snapshots within 30 min
- [ ] AWS S3 Object Lock verified: deletion attempt on a snapshot returns AccessDenied
- [ ] Etcd restoration runbook executed end-to-end on homelab-dev (controlled drill): cluster restored from snapshot
- [ ] OpenBao Raft snapshots landing in Garage every 6h (leader-only timer) and replicating to the AWS DR bucket *(v5.1)*
- [ ] OpenBao restore drill executed once: fresh cluster, snapshot restored, auto-unseal resumed, pre-snapshot Transit ciphertext decrypted *(v5.1)*

#### Clusters

- [ ] **homelab-prod** (prod): 4 nodes Ready, Cilium healthy, kube-proxy replacement = Strict, WireGuard encryption on, BGP CP enabled, audit log writing, etcd secrets encryption verified. *(v5.4: `prod-gpu-01` is provisioned as a VM but deliberately **not** joined until Tier 5 — so 4 Ready is correct here, becoming 5 at the Tier 5 gate. See ADR-011.)*
- [ ] **homelab-dev** (dev/staging): 3 nodes Ready, same Cilium and audit features active
- [ ] **Mgmt-plane**: 3 nodes Ready (HA), etcd quorum tested by stopping 1 node and confirming continued operation, all 3 nodes back online after restart
- [ ] **Quorum spread verified** *(v5.4)*: `mgmt-01`/`mgmt-02`/`mgmt-03` are on pve-01/pve-09/pve-02 and `vault-01`/`vault-02`/`vault-03` are on pve-01/pve-05/pve-02 — no hypervisor hosts two nodes of either quorum. Confirm in the Proxmox UI, not just in the OpenTofu plan
- [ ] **Single-host loss drill** *(v5.4)*: power off pve-01, confirm OpenBao stays unsealed and serving *and* the mgmt cluster stays responsive (both at 2 of 3), then power it back on and confirm both nodes rejoin. This is the drill the pre-v5.4 layout could not have passed
- [ ] All three kubeconfigs in `pass`, contexts labeled `homelab-prod` / `homelab-dev` / `mgmt`, `kubectx` switches between them cleanly

#### Hygiene

- [ ] No long-lived credentials on workstation outside of `pass`
- [ ] Workstation `~/.bash_history` or `~/.zsh_history` does not contain any unsealed secrets (consider `HISTIGNORE` for `vault*` commands going forward)
- [ ] Every VM tagged `v5` in Proxmox UI for easy bulk-management
- [ ] BGP peers configured in Cilium config but NOT yet established to bgp-01/bgp-02 (that happens in Tier 2 when we deploy the CiliumBGPClusterConfig CRDs)

When all of the above pass: **Tier 1 is complete.** Three operational clusters, fully Vault-authenticated provisioning chain, hardened OS baseline, storage tier ready. Tier 2 layers on the platform services that turn these clusters into a usable platform.
