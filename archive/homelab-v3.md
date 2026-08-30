# Operation Clean Slate v3 — Complete Build Checklist

> **How to use this document:** Work through phases sequentially. Each phase has a verification step — do not move to the next phase until verification passes. Check off items as you complete them.
> 
> 
> **What changed from v2:** Streamlined to an 8-phase MVP. Dropped MetalLB in favor of Cilium L2 announcements. Removed UFW/iptables (conflicts with Cilium eBPF). Added HashiCorp Vault for dynamic secrets. Aligned NFS paths/IPs across all repos. Bumped mgmt-plane RAM to 16GB. Deferred Kyverno, Velero, ARC, Authentik, n8n, pgBackRest, restic, NetworkPolicies, and Trivy to an Upgrades section at the end.
> 
> **Repos involved:**
> - `homelab-gitops` — All Kubernetes manifests, Helm values, ArgoCD apps, Flux config
> - `homelab-ansible` — OS-level configuration for all nodes and VMs
> - `homelab-terraform` — Proxmox VM provisioning via bpg/proxmox provider
> 
> **Cluster naming:**
> - **Workload cluster:** gandalf (CP), aragorn (W1), legolas (W2), gimli (W3)
> - **Management cluster:** mgmt-plane (single-node k3s, Flux-managed)
> - **Infrastructure:** nfs-server (VM), garage (LXC container)
> 

---

## Pre-Flight: Decisions Locked In

Before starting, confirm you’re aligned on all of these:

- [x]  **CNI:** Cilium (replaces Flannel AND kube-proxy via eBPF)
- [x]  **Load Balancing:** Cilium L2 announcements (replaces MetalLB — fewer components, same result)
- [x]  **Ingress:** Cilium Gateway API (replaces Traefik — `-disable traefik` in k3s)
- [x]  **GitOps (workload):** ArgoCD with app-of-apps, custom AppProject
- [x]  **GitOps (mgmt):** Flux — demonstrates multi-tool breadth
- [x]  **Storage (file):** NFS backed by ZFS on dedicated Proxmox VM — CSI driver via `csi-driver-nfs` (provisioner: `nfs.csi.k8s.io`), replaces legacy `nfs-subdir-external-provisioner`
- [x]  **Storage (object):** Garage (S3-compatible, replaces MinIO) — runs as LXC container
- [x]  **Secrets (static):** ESO + GCP Secret Manager (already working)
- [x]  **Secrets (dynamic):** HashiCorp Vault Community Edition — dynamic DB credentials, PKI
- [x]  **Observability:** Prometheus + Loki + Alloy + Hubble + Grafana + Alertmanager (on mgmt cluster)
- [x]  **TLS:** cert-manager with DNS-01 via Cloudflare (already working)
- [x]  **Tunnel:** Cloudflared (already working)

---

## Network & IP Allocation (Reference)

Keep this table handy — everything references it.

| Host | IP | VLAN | Role | Location |
| --- | --- | --- | --- | --- |
| Workstation (Ryzen 9) | 192.168.10.77 | 10 | Daily driver | Physical |
| gandalf (M920q) | 192.168.40.30 | 40 | k3s control plane | Physical |
| aragorn (M920q) | 192.168.40.31 | 40 | k3s worker 1 | Physical |
| legolas (M920q) | 192.168.40.32 | 40 | k3s worker 2 | Physical |
| Proxmox host (M920 SFF) | 192.168.40.50 | 40 | Hypervisor (64GB RAM, 1TB SSD) | Physical |
| nfs-server (VM) | 192.168.40.51 | 40 | NFS + ZFS persistent storage | VM on Proxmox |
| mgmt-plane (VM) | 192.168.40.52 | 40 | Observability stack (independent k3s) | VM on Proxmox |
| garage (LXC) | 192.168.40.53 | 40 | S3-compatible object storage | LXC on Proxmox |
| gimli (VM) | 192.168.40.33 | 40 | k3s worker 3 | VM on Proxmox |

**Service IPs (Cilium L2 pool):** 192.168.40.240–192.168.40.250

---

## Phase 0: Proxmox Installation on SFF PC

**Goal:** Bare-metal Proxmox VE running on the M920 SFF, accessible from the workstation.

- [x]  Download Proxmox VE ISO (latest stable) and flash to USB
- [x]  Boot the M920 SFF from USB, begin Proxmox installation
- [x]  **Disk setup during install:** Select the 1TB SSD, use **ext4** or **XFS** for the Proxmox root filesystem
    - Do NOT select ZFS at the Proxmox level — ZFS will live inside the NFS VM only
    - Proxmox just needs a reliable filesystem for itself and VM disk images
- [x]  Set the management IP: `192.168.40.50`, gateway and DNS per your network
- [x]  Set hostname: `proxmox` (or whatever you prefer)
- [x]  Complete installation, reboot, remove USB
- [x]  Access Proxmox web UI from workstation: `https://192.168.40.50:8006`
- [x]  Configure Proxmox networking:
    - Verify `vmbr0` bridge is bound to the physical NIC
    - Confirm bridge is on VLAN 40 (or trunk — depends on your switch config)
    - VMs will get IPs in the 192.168.40.0/24 range via static assignment
- [x]  Set DHCP reservation on your router/firewall for 192.168.40.50
- [x]  Upload Ubuntu Server 24.04 ISO to Proxmox local storage (or download via URL in the UI)

### Verification

- [x]  Proxmox web UI loads from workstation browser
- [x]  Can ping 192.168.40.50 from workstation
- [x]  Ubuntu 24.04 ISO visible in Proxmox storage

---

## Phase 1: Terraform — VM Provisioning

**Goal:** All VMs and LXC containers created on Proxmox via Terraform (IaC, not clicking through the UI).

### 1a. Set Up homelab-terraform Repo

- [x]  Create `homelab-terraform` repo
- [x]  Initialize Terraform project structure:

```
homelab-terraform/
├── main.tf              # Provider config
├── infra.tf             # VM and LXC resource definitions
├── locals.tf            # Configuration locals and node specs
├── variables.tf         # Variable definitions
├── terraform.tfvars     # Actual values (gitignored if contains secrets)
├── outputs.tf           # Output IP addresses, VM IDs
├── cloud-init/          # Cloud-init templates
│   ├── nfs-server.yaml
│   ├── mgmt-plane.yaml
│   └── gimli.yaml
└── docs/
    └── 01-proxmox-terraform-bootstrap.md
```

- [x]  Configure the bpg/proxmox provider (v0.97.1+):

```hcl
terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = ">= 0.97.0"
    }
  }
}

provider "proxmox" {
  endpoint = "https://192.168.40.50:8006/"
  # Auth via API token — SSH via ssh-agent for SFTP snippet uploads
  insecure = true  # Self-signed cert
}
```

- [x]  Create a Proxmox API token for Terraform (better than using root password)
    - Proxmox UI → Datacenter → Permissions → API Tokens
    - Store token in `terraform.tfvars` (gitignored) or environment variable

### 1b. Define VMs in Terraform

- [x]  Define all resources with cloud-init. Resource sizing:

| Resource | Type | VM ID | vCPU | RAM | Disk | Static IP |
| --- | --- | --- | --- | --- | --- | --- |
| nfs-server | VM (Ubuntu 24.04) | 101 | 2 | 4GB | 600GB | 192.168.40.51 |
| mgmt-plane | VM (Ubuntu 24.04) | 102 | 4 | 16GB | 60GB | 192.168.40.52 |
| gimli | VM (Ubuntu 24.04) | 100 | 4 | 8GB | 50GB | 192.168.40.33 |
| garage | LXC (Debian 13) | 200 | 2 | 2GB | 8GB + 200GB data | 192.168.40.53 |

> **Note on mgmt-plane RAM:** 16GB gives comfortable headroom for kube-prometheus-stack + Loki + Grafana. Proxmox host has 64GB — total VM allocation is ~30GB, leaving plenty of headroom.
> 

> **Note on garage:** LXC container, not a VM. Garage needs minimal resources (~1GB RAM). LXC is lighter weight and faster to provision.
> 
- [x]  Cloud-init templates should set:
    - Hostname
    - Static IP, gateway, DNS
    - SSH public key (your workstation key)
    - Disable password auth
    - Package update on first boot
    - Install `qemu-guest-agent`
- [x]  Run `terraform plan` — review the plan carefully
- [x]  Run `terraform apply` — create all resources
- [x]  Set DHCP reservations on your router for all IPs (belt and suspenders with static cloud-init)

### Verification

- [x]  All VMs and LXC running in Proxmox UI
- [x]  Can SSH to each from workstation using key auth:
    
    ```bash
    ssh dalton@192.168.40.51  # nfs-server (cloud-init creates dalton)
    ssh dalton@192.168.40.52  # mgmt-plane (cloud-init creates dalton)
    ssh root@192.168.40.53    # garage (LXC — Proxmox injects keys for root only)
    ssh dalton@192.168.40.33  # gimli (cloud-init creates dalton)
    ```
    
    > **Note (LXC vs VM access):** Proxmox LXC containers don’t support cloud-init user creation — the `user_account { keys }` block injects SSH keys for `root`, not a named user. Ansible inventory handles this via `ansible_user: root` on the `proxmox_lxc` group. The `common.yaml` base play still creates the `dalton` user on LXC containers for interactive SSH, but Ansible itself always connects as root. This is a deliberate design decision — see the `common.yaml` annotations below.
    > 
- [x]  Each VM/LXC can ping gandalf (192.168.40.30) and vice versa
- [x]  `terraform state list` shows all resources
- [x]  Commit Terraform code (excluding `.tfvars` with secrets)

---

## Phase 2: Ansible — Update Inventory & Roles

**Goal:** `homelab-ansible` updated with new VM inventory and roles for all new machines.

### 2a. Update Inventory

- [x]  Add new hosts to your Ansible inventory:

```yaml
all:
vars:
ansible_user: dalton
ansible_become:true
children:
baremetal:
hosts:
gandalf:
ansible_host:192.168.40.30
aragorn:
ansible_host:192.168.40.31
legolas:
ansible_host:192.168.40.32
proxmox_vms:
hosts:
nfs-server:
ansible_host:192.168.40.51
mgmt-plane:
ansible_host:192.168.40.52
gimli:
ansible_host:192.168.40.33
proxmox_lxc:
vars:
ansible_user: root       # LXC containers only get root SSH from Proxmox
ansible_become:false     # Already root — no sudo needed
hosts:
garage:
ansible_host:192.168.40.53
    # All managed hosts — base config (SSH, user, node-exporter, timezone)
linux_hosts:
children:
baremetal:
proxmox_vms:
proxmox_lxc:
    # Logical service groups
nfs:
hosts:
nfs-server:
object_storage:
hosts:
garage:
fellowship_control_plane:
hosts:
gandalf:
fellowship_workers:
hosts:
aragorn:
legolas:
gimli:
mgmt_control_plane:
hosts:
mgmt-plane:
k3s_all:
children:
fellowship_control_plane:
fellowship_workers:
mgmt_control_plane:
```

### 2b. Update k3s Playbooks for Cilium

- [x]  Update the control plane playbook (`k3s-server.yaml`):

```yaml
-name: Install k3s control plane
hosts: fellowship_control_plane
become:true
tasks:
-name: Install k3s server
      shell:>
        curl -sfL https://get.k3s.io | sh -s - server
        --write-kubeconfig-mode 644
        --disable servicelb
        --disable traefik
        --flannel-backend=none
        --disable-network-policy
        --disable-kube-proxy
        --node-ip {{ ansible_host }}
        --tls-san {{ ansible_host }}
args:
creates: /etc/rancher/k3s/k3s.yaml
```

- [ ]  Add a Gateway API CRD installation task to `k3s-server.yaml` (runs after k3s install, before Cilium):
    
    > **Why here:** Cilium requires these CRDs to already exist when it starts. During a fresh build (Phase 3) you’ll run the `kubectl apply` manually, but codifying it in Ansible ensures future rebuilds and new control plane nodes get the CRDs automatically. The `kubernetes.core.k8s` module is idempotent — safe to run repeatedly.
    > 

```yaml
-name: Wait for k3s API server to be ready
command: kubectl get nodes
environment:
KUBECONFIG: /etc/rancher/k3s/k3s.yaml
register: k3s_ready
retries:10
delay:5
until: k3s_ready.rc == 0

-name: Install Gateway API CRDs (required before Cilium)
kubernetes.core.k8s:
state: present
src:"https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml"
environment:
KUBECONFIG: /etc/rancher/k3s/k3s.yaml
```

```
> **Dependency:** Requires the `kubernetes.core` Ansible collection. Install with: `ansible-galaxy collection install kubernetes.core`. Pin the Gateway API version here to match your Cilium version — update both together when upgrading Cilium.
```

- [x]  Update the worker/agent playbook (`k3s-agent.yaml`):

```yaml
-name: Install k3s workers
hosts: fellowship_workers
become:true
tasks:
-name: Install k3s agent
      shell:>
        curl -sfL https://get.k3s.io | sh -s - agent
        --server https://192.168.40.30:6443
        --token {{ k3s_token }}
        --node-ip {{ ansible_host }}
args:
creates: /etc/rancher/k3s/k3s.yaml
```

### 2c. Create Ansible Playbooks/Roles

- [x]  **Playbook: `common.yaml`** — two plays in one file:
    
    **Play 1: Base configuration (`linux_hosts`)** — every managed host gets this:
    
    - Update apt cache
    - Install base packages (curl, wget, vim, htop, jq, prometheus-node-exporter)
    - Enable and start `prometheus-node-exporter`
    - Ensure `dalton` user exists with sudo and SSH authorized key
    - Set timezone (America/Denver)
    - Harden SSH: disable password auth (all hosts), disable root login (skipped on LXC where `ansible_user == root`)
    
    **Play 2: k3s node configuration (`k3s_all`)** — only k3s cluster members:
    
    - Full package upgrade (`apt dist-upgrade`)
    - Install `nfs-common`
    - Disable and remove swap
    - **No UFW or iptables** — Cilium eBPF manages network policy. Host-level firewalling would conflict with Cilium’s dataplane.
    
    > **Blog note — LXC bootstrap pattern:** Proxmox LXC containers don’t support cloud-init user creation (only VMs do). The `proxmox_lxc` inventory group overrides `ansible_user: root` because that’s the only SSH access Terraform can provision. The `common.yaml` base play creates the `dalton` user for interactive SSH but Ansible always connects as root. The “disable root login” hardening task uses a `when: ansible_user != 'root'` guard to avoid locking Ansible out — this is an intentional tradeoff where the security delta is negligible (VMs use NOPASSWD sudo, so key compromise gives root either way). This is a good architectural decision to discuss in the blog post.
    > 
- [ ]  **Playbook: `nfs-server.yaml`**
    - Install ZFS: `apt install zfsutils-linux`
    - Create ZFS pool: `zpool create tank /dev/sdX` (where sdX is the data disk)
    - Create dataset: `zfs create tank/k8s`
    - Set compression: `zfs set compression=lz4 tank/k8s`
    - Install NFS server: `apt install nfs-kernel-server`
    - Configure `/etc/exports`:
        
        ```
        /tank/k8s 192.168.40.0/24(rw,sync,no_subtree_check,root_squash)
        ```
        
    - Enable and start NFS server
    - Install `zfs-auto-snapshot` or create systemd timers for snapshots:
        - Hourly snapshots, keep 24
        - Daily snapshots, keep 30
        - Weekly snapshots, keep 8

> **Canonical NFS path:** `/tank/k8s` on `192.168.40.51`. All StorageClasses, cloud-init configs, and Ansible playbooks must reference this exact path and IP.
> 
- [ ]  **Playbook: `garage.yaml`**
    - Download Garage binary (latest stable release)
    - Ensure `/mnt/data` (Terraform’s 200GB data volume) is writable
    - Create Garage config file (`/etc/garage.toml`):
        
        ```toml
        metadata_dir = "/var/lib/garage/meta"
        data_dir = "/mnt/data"
        db_engine = "lmdb"
        
        replication_factor = 1
        
        [s3_api]
        s3_region = "garage"
        api_bind_addr = "[::]:3900"
        root_domain = ".s3.garage.local"
        
        [s3_web]
        bind_addr = "[::]:3902"
        root_domain = ".web.garage.local"
        
        [admin]
        api_bind_addr = "[::]:3903"
        
        [rpc]
        bind_addr = "[::]:3901"
        secret = "GENERATE_A_SECRET_HERE"
        ```
        
    - Create systemd service with `DynamicUser=true` and `StateDirectory=garage` (per [Garage docs](https://garagehq.deuxfleurs.fr/documentation/cookbook/systemd/))
    - Enable and start Garage
    - Initialize cluster layout: `garage layout assign -z dc1 -c 200G <node-id>`
    - Apply layout: `garage layout apply`
    - Create access key: `garage key create homelab-service-key`
    - Create buckets:
        - `garage bucket create loki-chunks`
    - Grant key permissions on each bucket:
        - `garage bucket allow --read --write --owner loki-chunks --key homelab-service-key`

> **Note:** Additional buckets (velero-backups, pgbackrest) will be created when those features are added in the Upgrades section.
> 

> **Blog note — Garage DynamicUser hardening:** The systemd unit uses `DynamicUser=true` + `StateDirectory=garage` per the official Garage docs. This means Garage runs as a transient non-root user with a dynamic UID — it can only write to `/var/lib/garage` (metadata, managed by systemd) and `/mnt/data` (object storage, the 200GB Terraform volume via `ReadWritePaths`). Do NOT pre-create `/var/lib/garage` — systemd manages it. The `data_dir` was corrected from `/var/lib/garage/data` (8GB root disk) to `/mnt/data` (the actual 200GB data volume from Terraform). This is a good example of defense-in-depth to discuss alongside the Kyverno `require-non-root` policy in the blog post.
> 
- [ ]  **Playbook: `mgmt-plane.yaml`**
    - Install k3s in single-node server mode:
        
        ```bash
        curl -sfL https://get.k3s.io | sh -s - server \
          --write-kubeconfig-mode 644 \
          --disable servicelb \
          --disable traefik
        ```
        
        > Note: mgmt cluster does NOT need Cilium/Gateway API — it’s a simple single-node cluster for internal observability. Default Flannel is fine here.
        > 
    - Copy kubeconfig to a known location for Flux bootstrap

### 2d. Run Ansible

- [ ]  Run the `common` playbook against all hosts (bare-metal, VMs, and LXC containers):
    
    ```bash
    ansible-playbook -i inventory.yaml playbooks/common.yaml --ask-vault-pass
    ```
    
- [ ]  Run the `nfs-server` playbook:
    
    ```bash
    ansible-playbook -i inventory.yaml playbooks/nfs-server.yaml
    ```
    
- [ ]  Run the `garage` playbook:
    
    ```bash
    ansible-playbook -i inventory.yaml playbooks/garage.yaml
    ```
    
- [ ]  Run the `mgmt-plane` playbook:
    
    ```bash
    ansible-playbook -i inventory.yaml playbooks/mgmt-plane.yaml
    ```
    
- [ ]  Do NOT run k3s install on any workers yet — no workers should join until Cilium is running on the control plane

### Verification

- [ ]  NFS: From any existing cluster node, test mount:
    
    ```bash
    sudo mount -t nfs 192.168.40.51:/tank/k8s /mnt/test
    touch /mnt/test/hello
    ls /mnt/test/hello  # Should exist
    sudo umount /mnt/test
    ```
    
- [ ]  ZFS: On nfs-server:
    
    ```bash
    zpool status tank          # Pool healthy
    zfs list                    # Dataset visible
    zfs get compression tank/k8s  # Shows lz4
    ```
    
- [ ]  Garage: From your **workstation**, test S3 access:
    
    ```bash
    aws --endpoint-url http://192.168.40.53:3900 s3 ls
    # Should list your buckets
    ```
    
    > **Note:** `aws` CLI only needs to be on your workstation — k3s nodes don’t need it. If you want a quick reachability check from a node, use curl against the admin health endpoint instead (curl is installed on all nodes by `common.yaml`):
    > 
    > 
    > ```bash
    > curl http://192.168.40.53:3903/health
    > # Should return 200 OK
    > ```
    > 
- [ ]  mgmt-plane: SSH in and verify k3s:
    
    ```bash
    kubectl get nodes  # Single node, Ready
    ```
    
- [ ]  node_exporter: On each node, curl `http://localhost:9100/metrics` returns Prometheus metrics
- [ ]  Commit all Ansible changes to `homelab-ansible`

---

## Phase 3: Workload Cluster Rebuild — Cilium Migration

**Goal:** Workload cluster (gandalf, aragorn, legolas, gimli) rebuilt with Cilium as CNI, kube-proxy replaced, Gateway API enabled, L2 load balancing active.

> ⚠️ **This is destructive.** You are reinstalling k3s on all existing nodes. Back up anything you need from the current cluster first. Since your GitOps repo has all manifests, the cluster state is recoverable, but be deliberate.
> 

### 3a. Back Up Current State

- [ ]  Export any resources not yet in your Git repo:
    
    ```bash
    kubectl get all --all-namespaces -o yaml > cluster-backup.yaml
    ```
    
- [ ]  Verify your `homelab-gitops` repo has all the manifests you need
- [ ]  Note down your cert-manager ClusterIssuer config, ESO ClusterSecretStore — these will be redeployed via ArgoCD

### 3b. Tear Down Existing Cluster

- [ ]  On each worker (aragorn, legolas):
    
    ```bash
    /usr/local/bin/k3s-agent-uninstall.sh
    ```
    
- [ ]  On control plane (gandalf):
    
    ```bash
    /usr/local/bin/k3s-uninstall.sh
    ```
    
- [ ]  Verify k3s is fully removed from all nodes:
    
    ```bash
    which k3s         # Should not exist
    ls /etc/rancher/  # Should not exist
    ```
    

### 3c. Reinstall k3s with Cilium Flags

- [ ]  Run updated Ansible playbook for control plane (gandalf):
    
    ```bash
    ansible-playbook -i inventory.yaml playbooks/k3s-server.yaml
    ```
    
    This installs k3s with: `--flannel-backend=none --disable-network-policy --disable-kube-proxy --disable traefik --disable servicelb`
    
- [ ]  Verify gandalf is up (node will be `NotReady` — this is expected, no CNI yet):
    
    ```bash
    kubectl get nodes
    # NAME      STATUS     ROLES                  AGE   VERSION
    # gandalf   NotReady   control-plane,master   30s   v1.xx.x
    ```
    

### 3d. Install Gateway API CRDs

> **Why this step exists:** Cilium’s `gatewayAPI.enabled=true` flag tells the Cilium operator to *watch* for Gateway API resources — it does **not** install the CRDs themselves. The upstream Gateway API CRDs are maintained by [kubernetes-sigs/gateway-api](https://github.com/kubernetes-sigs/gateway-api) and must be installed before Cilium starts, or the operator will log errors about missing resource types and the gateway controller will not function. The only CRD Cilium installs itself is its own `ciliumgatewayclassconfigs.cilium.io`.
> 
> 
> **Lifecycle strategy:** This manual `kubectl apply` handles bootstrap. The same step is codified in the Ansible `k3s-server.yaml` playbook (see step 2b) for automated rebuilds. In Phase 4d, ArgoCD adopts the CRDs for ongoing GitOps-managed drift detection and version upgrades.
> 
- [ ]  Install the standard Gateway API CRDs (check your target Cilium version’s docs for the matching Gateway API version — Cilium 1.17.x supports v1.2.x, latest Cilium supports v1.4.1):
    
    ```bash
    kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml
    ```
    
    > **Version pinning:** Always match the Gateway API CRD version to what your Cilium version supports. Check the [Cilium Gateway API docs](https://docs.cilium.io/en/stable/network/servicemesh/gateway-api/gateway-api.html) for the Prerequisites section — it states the exact version required.
    > 
- [ ]  Verify the CRDs are installed:
    
    ```bash
    kubectl get crd | grep gateway.networking.k8s.io
    # gatewayclasses.gateway.networking.k8s.io
    # gateways.gateway.networking.k8s.io
    # grpcroutes.gateway.networking.k8s.io
    # httproutes.gateway.networking.k8s.io
    # referencegrants.gateway.networking.k8s.io
    ```
    

### 3e. Install Cilium

- [ ]  Install Cilium CLI on your workstation:
    
    ```bash
    CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
    curl -L --fail --remote-name-all \
      https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-amd64.tar.gz
    sudo tar xzvfC cilium-linux-amd64.tar.gz /usr/local/bin
    ```
    
- [ ]  Install Cilium via Helm (bootstrap manually — ArgoCD will adopt it in Phase 4):
    
    ```bash
    helm repo add cilium https://helm.cilium.io/
    helm repo update
    
    helm install cilium cilium/cilium --version 1.17.x \
      --namespace kube-system \
      --set kubeProxyReplacement=true \
      --set k8sServiceHost=192.168.40.30 \
      --set k8sServicePort=6443 \
      --set gatewayAPI.enabled=true \
      --set l2announcements.enabled=true \
      --set externalIPs.enabled=true \
      --set hubble.enabled=true \
      --set hubble.relay.enabled=true \
      --set hubble.ui.enabled=true \
      --set operator.replicas=1 \
      --set ipam.operator.clusterPoolIPv4PodCIDRList="10.42.0.0/16"
    ```
    
    > Adjust `--version` to the latest stable 1.17.x release. The `k8sServiceHost` and port point to your control plane since kube-proxy is disabled. `l2announcements.enabled` and `externalIPs.enabled` replace MetalLB entirely.
    > 
- [ ]  Wait for Cilium to be ready:
    
    ```bash
    cilium status --wait
    ```
    
- [ ]  Verify gandalf becomes `Ready`:
    
    ```bash
    kubectl get nodes
    # NAME      STATUS   ROLES                  AGE    VERSION
    # gandalf   Ready    control-plane,master   5m     v1.xx.x
    ```
    

### 3f. Apply Cilium L2 Configuration

- [ ]  Create the LoadBalancer IP pool and L2 announcement policy:
    
    ```bash
    kubectl apply -f - <<EOF
    apiVersion: cilium.io/v2alpha1
    kind: CiliumLoadBalancerIPPool
    metadata:
      name: homelab-pool
    spec:
      blocks:
        - start: 192.168.40.240
          stop: 192.168.40.250
    ---
    apiVersion: cilium.io/v2alpha1
    kind: CiliumL2AnnouncementPolicy
    metadata:
      name: default-l2
    spec:
      loadBalancerIPs: true
    EOF
    ```
    
- [ ]  Verify the pool is recognized:
    
    ```bash
    kubectl get ciliumloadbalancerippool
    # NAME           DISABLED   CONFLICTING   IPS AVAILABLE   AGE
    # homelab-pool   false      False         11              10s
    ```
    

### 3g. Join All Workers

> **Important:** No workers should join until Cilium is running. This applies to all workers equally — aragorn, legolas, and gimli.
> 
- [ ]  Run Ansible for all workers:
    
    ```bash
    ansible-playbook -i inventory.yaml playbooks/k3s-agent.yaml
    ```
    
- [ ]  Wait for all workers to become `Ready`:
    
    ```bash
    kubectl get nodes
    # NAME      STATUS   ROLES                  AGE    VERSION
    # gandalf   Ready    control-plane,master   10m    v1.xx.x
    # aragorn   Ready    <none>                 2m     v1.xx.x
    # legolas   Ready    <none>                 2m     v1.xx.x
    # gimli     Ready    <none>                 2m     v1.xx.x
    ```
    
- [ ]  Label gimli as a Proxmox-hosted node:
    
    ```bash
    kubectl label node gimli topology.kubernetes.io/zone=proxmox
    ```
    

### 3h. Verify Cilium, Hubble & L2

- [ ]  Run Cilium connectivity test:
    
    ```bash
    cilium connectivity test
    ```
    
    > This creates test pods across nodes and verifies networking, DNS, NetworkPolicy enforcement. It takes a few minutes.
    > 
- [ ]  Verify Hubble is working:
    
    ```bash
    cilium hubble port-forward &
    hubble observe --follow
    ```
    
    > You should see flow logs appearing in real time.
    > 
- [ ]  Verify Gateway API CRDs are installed (these came from step 3d, not from Cilium):
    
    ```bash
    kubectl get crd | grep gateway
    # Should show:
    #   ciliumgatewayclassconfigs.cilium.io          (installed by Cilium)
    #   gatewayclasses.gateway.networking.k8s.io     (installed in step 3d)
    #   gateways.gateway.networking.k8s.io           (installed in step 3d)
    #   grpcroutes.gateway.networking.k8s.io         (installed in step 3d)
    #   httproutes.gateway.networking.k8s.io         (installed in step 3d)
    #   referencegrants.gateway.networking.k8s.io    (installed in step 3d)
    ```
    
- [ ]  Verify L2 announcements are working — create a test LoadBalancer service:
    
    ```bash
    kubectl create deployment nginx-test --image=nginx:1.27
    kubectl expose deployment nginx-test --type=LoadBalancer --port=80
    kubectl get svc nginx-test
    # Should show an EXTERNAL-IP from 192.168.40.240-250
    curl http://<EXTERNAL-IP>
    # Should return nginx welcome page
    kubectl delete deployment nginx-test
    kubectl delete svc nginx-test
    ```
    

### Verification

- [ ]  All 4 nodes `Ready`
- [ ]  `cilium status` shows all agents healthy
- [ ]  `cilium connectivity test` passes
- [ ]  `hubble observe` shows flows
- [ ]  `kubectl get crd | grep gateway` shows Gateway API CRDs
- [ ]  No kube-proxy pods running: `kubectl get pods -n kube-system | grep kube-proxy` returns nothing
- [ ]  LoadBalancer services get IPs from Cilium L2 pool
- [ ]  No MetalLB components anywhere in the cluster

---

## Phase 4: ArgoCD & Core Platform Bootstrap

**Goal:** ArgoCD redeployed, core platform services restored and operational.

### 4a. Install ArgoCD

- [ ]  Install ArgoCD via Helm (bootstrap — ArgoCD will manage itself after):
    
    ```bash
    kubectl create namespace argocd
    
    helm repo add argo https://argoproj.github.io/argo-helm
    helm repo update
    
    helm install argocd argo/argo-cd \
      --namespace argocd \
      --set server.insecure=true  # TLS terminates at Gateway
    ```
    
- [ ]  Verify ArgoCD pods are running:
    
    ```bash
    kubectl get pods -n argocd
    ```
    
- [ ]  Get initial admin password:
    
    ```bash
    kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
    ```
    

### 4b. Deploy Root Application (App of Apps)

- [ ]  Ensure your `homelab-gitops` repo has the updated `argocd/root.yaml` pointing to the correct repo URL and path
- [ ]  Apply the AppProject (update to remove MetalLB, add Gateway API CRDs):
    
    ```yaml
    apiVersion: argoproj.io/v1alpha1
    kind: AppProject
    metadata:
    name: homelab
    namespace: argocd
    spec:
    description: Homelab GitOps project
    sourceRepos:
    - https://github.com/DaltonBuilds/homelab-gitops
    - https://charts.jetstack.io
    - https://charts.external-secrets.io
    - https://helm.cilium.io
    - https://helm.releases.hashicorp.com
    destinations:
    -server: https://kubernetes.default.svc
    namespace:'*'
    clusterResourceWhitelist:
    -group:''
    kind: Namespace
    -group: cert-manager.io
    kind: ClusterIssuer
    -group: external-secrets.io
    kind: ClusterSecretStore
    -group: cilium.io
    kind: CiliumLoadBalancerIPPool
    -group: cilium.io
    kind: CiliumL2AnnouncementPolicy
    -group: gateway.networking.k8s.io
    kind: Gateway
    -group: gateway.networking.k8s.io
    kind: GatewayClass
    -group: gateway.networking.k8s.io
    kind: HTTPRoute
    -group: storage.k8s.io
    kind: StorageClass
    ```
    
- [ ]  Apply the root app:
    
    ```bash
    kubectl apply -f argocd/apps/app-project-homelab.yaml
    kubectl apply -f argocd/root.yaml
    ```
    

### 4c. Adopt Cilium into ArgoCD

> **Critical:** Cilium was installed manually via Helm in Phase 3. ArgoCD needs to take over management without disrupting the running CNI. The Gateway API CRDs (installed in step 3d) are cluster-scoped prerequisites — ArgoCD manages Cilium, but the CRDs themselves are a cluster-admin concern (see the options note at the end of step 3d).
> 
- [ ]  Create `argocd/apps/cilium.yaml` ArgoCD Application pointing to the Cilium Helm chart
- [ ]  Create `apps/cilium/values.yaml` with the **exact same Helm values** used in Phase 3e:
    
    ```yaml
    kubeProxyReplacement:true
    k8sServiceHost:"192.168.40.30"
    k8sServicePort:6443
    gatewayAPI:
    enabled:true
    l2announcements:
    enabled:true
    externalIPs:
    enabled:true
    hubble:
    enabled:true
    relay:
    enabled:true
    ui:
    enabled:true
    operator:
    replicas:1
    ipam:
    operator:
    clusterPoolIPv4PodCIDRList:
    -"10.42.0.0/16"
    ```
    
- [ ]  Move the L2 pool and announcement policy into `apps/cilium/`:
    - `apps/cilium/ip-pool.yaml` — CiliumLoadBalancerIPPool
    - `apps/cilium/l2-policy.yaml` — CiliumL2AnnouncementPolicy
- [ ]  Set sync policy with `ServerSideApply` and `Replace=true` to cleanly adopt existing resources:
    
    ```yaml
    syncPolicy:
    automated:
    prune:true
    selfHeal:true
    syncOptions:
    - CreateNamespace=false
    - ServerSideApply=true
    - Replace=true
    ```
    
- [ ]  Sync — ArgoCD should show `Synced` and `Healthy` without restarting Cilium pods
- [ ]  Verify cluster connectivity is uninterrupted after sync

### 4d. Adopt Gateway API CRDs into ArgoCD

> **Why adopt CRDs into ArgoCD?** During Phase 3d you installed the Gateway API CRDs manually via `kubectl apply`. That works for bootstrap, but leaves the CRDs unmanaged — no drift detection, no version tracking in Git, no visibility in ArgoCD. Adopting them as an ArgoCD Application gives you GitOps-managed lifecycle: version upgrades go through Git PRs, accidental CRD drift self-heals, and the CRD version is visible alongside everything else in the ArgoCD UI.
> 
- [ ]  Create `argocd/apps/gateway-api-crds.yaml`:
    
    ```yaml
    apiVersion: argoproj.io/v1alpha1
    kind: Application
    metadata:
    name: gateway-api-crds
    namespace: argocd
    annotations:
    argocd.argoproj.io/sync-wave:"-1"
    spec:
    project: homelab
    source:
    repoURL: https://github.com/kubernetes-sigs/gateway-api
    path: config/crd/standard
    targetRevision: v1.2.1
    destination:
    server: https://kubernetes.default.svc
    syncPolicy:
    automated:
    prune:false
    selfHeal:true
    syncOptions:
    - ServerSideApply=true
    ```
    
    > **Sync wave `-1`:** Ensures CRDs are applied before Cilium (wave 0) and all other applications. This mirrors the bootstrap ordering from Phase 3.
    > 
    > 
    > **`prune: false`:** Deliberately disabled. CRDs are cluster-scoped, highly-privileged resources — accidental pruning would break every Gateway, HTTPRoute, and GRPCRoute in the cluster. The [Gateway API CRD management guide](https://gateway-api.sigs.k8s.io/guides/crd-management) explicitly states implementations must never remove Gateway API CRDs. `selfHeal: true` still corrects drift without the deletion risk.
    > 
    > **Upgrading:** To upgrade Gateway API CRDs (e.g., when upgrading Cilium), update `targetRevision` in this file and the version in the Ansible playbook simultaneously. Always check the Cilium release notes for the supported Gateway API version.
    > 
- [ ]  Update the AppProject `clusterResourceWhitelist` to include the CRD resource type (if not already permitted):
    
    ```yaml
    -group: apiextensions.k8s.io
    kind: CustomResourceDefinition
    ```
    
- [ ]  Sync the application and verify ArgoCD shows it as `Synced` and `Healthy`
- [ ]  Verify CRDs are still present: `kubectl get crd | grep gateway.networking.k8s.io`

### 4e. Restore Core Services (in ArgoCD sync order)

ArgoCD will begin syncing applications. Use sync waves to control ordering:

1. **External Secrets Operator** (sync wave: 1):
    - [ ]  Sync `external-secrets.yaml` and `external-secrets-store.yaml`
    - [ ]  Verify ClusterSecretStore: `kubectl get clustersecretstore`
2. **cert-manager** (sync wave: 2):
    - [ ]  Sync `cert-manager.yaml` and `cert-manager-config.yaml`
    - [ ]  Verify ClusterIssuer: `kubectl get clusterissuer`
    - [ ]  Verify Cloudflare secret syncs: `kubectl get externalsecret -A`
3. **NFS CSI Driver** (sync wave: 2) + **StorageClasses** (sync wave: 3):
    
    > **Provisioner decision:** Migrated from `nfs-subdir-external-provisioner` to the official Kubernetes CSI NFS driver (`nfs.csi.k8s.io`). The CSI driver is a proper Container Storage Interface implementation with active upstream maintenance, whereas `nfs-subdir-external-provisioner` is a legacy out-of-tree provisioner. The CSI driver uses `subDir` (not `pathPattern`) for per-PVC subdirectory templating and installs into `kube-system`.
    > 
    - [x]  Create `argocd/apps/nfs-provisioner-helm.yaml` — deploys `csi-driver-nfs` Helm chart (wave 2):
        
        ```yaml
        repoURL: https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts
        chart: csi-driver-nfs
        targetRevision:"4.13.1"
        helm:
        releaseName: csi-driver-nfs
          values:|
            storageClass:
              create: false
        destination:
        namespace: kube-system
        ```
        
    - [x]  Create `argocd/apps/nfs-provisioner.yaml` pointing to `apps/nfs-provisioner/` (wave 3)
    - [x]  StorageClasses use `provisioner: nfs.csi.k8s.io` and `subDir` parameter:
        
        ```yaml
        apiVersion: storage.k8s.io/v1
        kind: StorageClass
        metadata:
        name: nfs-zfs-retain
        annotations:
        storageclass.kubernetes.io/is-default-class:"true"
        provisioner: nfs.csi.k8s.io
        parameters:
        server:"192.168.40.51"
        share:"/tank/k8s"
        subDir:"${pvc.metadata.namespace}/${pvc.metadata.name}"
        reclaimPolicy: Retain
        allowVolumeExpansion:true
        mountOptions:
        - nfsvers=4.1
        ---
        apiVersion: storage.k8s.io/v1
        kind: StorageClass
        metadata:
        name: nfs-zfs-delete
        provisioner: nfs.csi.k8s.io
        parameters:
        server:"192.168.40.51"
        share:"/tank/k8s"
        subDir:"${pvc.metadata.namespace}/${pvc.metadata.name}"
        reclaimPolicy: Delete
        allowVolumeExpansion:true
        mountOptions:
        - nfsvers=4.1
        ```
        
    - [ ]  Sync (wave 2 first — CSI driver must be running before StorageClasses are created)
    - [ ]  Test dynamic provisioning:
        
        ```bash
        kubectl apply -f - <<EOF
        apiVersion: v1
        kind: PersistentVolumeClaim
        metadata:
          name: test-pvc
        spec:
          accessModes: [ReadWriteMany]
          storageClassName: nfs-zfs-retain
          resources:
            requests:
              storage: 1Gi
        EOF
        kubectl get pvc test-pvc  # Should be Bound
        kubectl delete pvc test-pvc
        ```
        
4. **Gateway + Cloudflared** (sync wave: 4):
    - [ ]  Create `apps/gateway/` directory with:
        - `gateway.yaml` — the shared Gateway resource (Cilium GatewayClass, HTTPS listener, cert-manager annotation)
        - No GatewayClass needed — Cilium auto-creates one named `cilium`
    - [ ]  Create `argocd/apps/gateway.yaml` ArgoCD Application
    - [ ]  Sync
    - [ ]  Verify Gateway has an external IP from Cilium L2 pool:
        
        ```bash
        kubectl get gateway -A
        # homelab-gateway   cilium   True   Programmed   192.168.40.24X
        ```
        
    - [ ]  Note the Gateway’s LoadBalancer IP — Cloudflared needs this
    - [ ]  Update Cloudflared config to point tunnel at the Gateway’s LoadBalancer IP
    - [ ]  Create `argocd/apps/cloudflared.yaml` and `apps/cloudflared/` with deployment
    - [ ]  Sync Cloudflared

### 4f. Deploy Platform Ingress (as HTTPRoutes)

- [ ]  Rewrite all files in `apps/platform-ingress/` from `kind: Ingress` to `kind: HTTPRoute`:
    
    ```yaml
    apiVersion: gateway.networking.k8s.io/v1
    kind: HTTPRoute
    metadata:
    name: argocd-route
    namespace: argocd
    spec:
    parentRefs:
    -name: homelab-gateway
    namespace: gateway
    hostnames:
    - argocd.daltonbuilds.com
    rules:
    -backendRefs:
    -name: argocd-server
    port:80
    ```
    
- [ ]  Routes to create:
    - [ ]  `argocd-route.yaml`
    - [ ]  `hubble-route.yaml` (new — expose Hubble UI)
- [ ]  Sync platform-ingress ArgoCD app
- [ ]  Verify ArgoCD is accessible via its hostname through Cloudflared tunnel

### Verification

- [ ]  ArgoCD UI accessible via browser (through tunnel)
- [ ]  All synced ArgoCD applications show `Healthy` and `Synced`
- [ ]  Cilium L2 assigning IPs to LoadBalancer services
- [ ]  cert-manager issuing certificates: `kubectl get certificates -A`
- [ ]  ESO secrets syncing from GCP
- [ ]  NFS StorageClass provisioning PVCs
- [ ]  Gateway has an external IP and is `Programmed`
- [ ]  Cloudflared tunnel routing traffic to Gateway IP

---

## Phase 5: Management Cluster — Observability Stack

**Goal:** Independent Prometheus + Loki + Grafana + Alertmanager on mgmt-plane, managed by Flux.

### 5a. Bootstrap Flux on mgmt-plane

- [x]  Install Flux CLI on your workstation:
    
    ```bash
    curl -s https://fluxcd.io/install.sh | sudo bash
    ```
    
- [x]  Create `mgmt-cluster/` directory in `homelab-gitops` repo
- [x]  Bootstrap Flux against the mgmt-plane cluster:
    
    ```bash
    # Point kubectl at the mgmt-plane cluster
    export KUBECONFIG=/path/to/mgmt-plane-kubeconfig
    
    flux bootstrap github \
      --owner=DaltonBuilds \
      --repository=homelab-gitops \
      --branch=main \
      --path=mgmt-cluster \
      --personal
    ```
    
    > This creates the `flux-system/` directory inside `mgmt-cluster/` and configures Flux to watch that path.
    > 

### 5b. Deploy Observability Stack via Flux

- [x]  Create `mgmt-cluster/infrastructure/sources.yaml` — HelmRepository definitions:
    
    ```yaml
    apiVersion: source.toolkit.fluxcd.io/v1
    kind: HelmRepository
    metadata:
    name: prometheus-community
    namespace: flux-system
    spec:
    interval: 1h
    url: https://prometheus-community.github.io/helm-charts
    ---
    apiVersion: source.toolkit.fluxcd.io/v1
    kind: HelmRepository
    metadata:
    name: grafana
    namespace: flux-system
    spec:
    interval: 1h
    url: https://grafana.github.io/helm-charts
    ```
    
- [x]  Create `mgmt-cluster/infrastructure/prometheus/helmrelease.yaml`:
    
    ```yaml
    apiVersion: helm.toolkit.fluxcd.io/v2
    kind: HelmRelease
    metadata:
    name: kube-prometheus-stack
    namespace: monitoring
    spec:
    interval: 1h
    chart:
    spec:
    chart: kube-prometheus-stack
    sourceRef:
    kind: HelmRepository
    name: prometheus-community
    namespace: flux-system
    values:
    prometheus:
    prometheusSpec:
    retention: 15d
    resources:
    requests:
    memory: 2Gi
    cpu: 500m
    limits:
    memory: 4Gi
            # Scrape workload cluster node-exporters
    additionalScrapeConfigs:
    -job_name:'workload-nodes'
    static_configs:
    -targets:
    -'192.168.40.30:9100'  # gandalf
    -'192.168.40.31:9100'  # aragorn
    -'192.168.40.32:9100'  # legolas
    -'192.168.40.33:9100'  # gimli
    -'192.168.40.51:9100'  # nfs-server
    -job_name:'garage'
    static_configs:
    -targets:
    -'192.168.40.53:3903'  # Garage admin API exposes metrics
    grafana:
    adminPassword: changeme  # Replace with secret reference
    persistence:
    enabled:true
    size: 5Gi
    alertmanager:
    alertmanagerSpec:
    resources:
    requests:
    memory: 256Mi
    limits:
    memory: 512Mi
    ```
    
- [x]  Create `mgmt-cluster/infrastructure/loki/helmrelease.yaml`:
    
    ```yaml
    apiVersion: helm.toolkit.fluxcd.io/v2
    kind: HelmRelease
    metadata:
    name: loki
    namespace: monitoring
    spec:
    interval: 1h
    chart:
    spec:
    chart: loki
    sourceRef:
    kind: HelmRepository
    name: grafana
    namespace: flux-system
    values:
    deploymentMode: SingleBinary
    loki:
    auth_enabled:false
    storage:
    type: s3
    s3:
    endpoint: http://192.168.40.53:3900
    bucketnames: loki-chunks
    region: garage
    access_key_id: YOUR_KEY      # Use a Kubernetes secret
    secret_access_key: YOUR_SECRET
    s3ForcePathStyle:true
    commonConfig:
    replication_factor:1
    limits_config:
    retention_period: 720h  # 30 days
    singleBinary:
    replicas:1
    resources:
    requests:
    memory: 1Gi
    cpu: 250m
    limits:
    memory: 2Gi
    ```
    
- [x]  Create the Flux layered reconciliation structure — three files that connect the bootstrap to your infrastructure resources:
    
    > **Why three files?** Flux has two resources that share the name “Kustomization” but are completely different things. A **native Kustomize** file (`kustomize.config.k8s.io/v1beta1`) tells the Kustomize tool which resources to bundle. A **Flux Kustomization CRD** (`kustomize.toolkit.fluxcd.io/v1`) is a Kubernetes object that tells Flux to independently reconcile a directory with its own interval, retry, and health tracking. The layered pattern uses both: the Flux CRD lives in the cluster directory and points to a target path; a native Kustomize file lives in that target path and lists the actual resources. This matches the [official Flux example repo](https://github.com/fluxcd/flux2-kustomize-helm-example) (`clusters/staging/infrastructure.yaml` + `infrastructure/controllers/kustomization.yaml`).
    > 
    > 
    > **What you gain:** The infrastructure layer gets its own independent reconciliation loop with separate retry/timeout behavior. When you later add an `apps` layer, you can use `dependsOn` to enforce ordering (apps wait for infrastructure to be healthy). The bootstrap Kustomization only needs to know about layers, not individual HelmReleases.
    > 
    
    **File 1 — `mgmt-cluster/kustomization.yaml`** (native Kustomize — tells Flux bootstrap what to apply):
    
    ```yaml
    ---
    apiVersion: kustomize.config.k8s.io/v1beta1
    kind: Kustomization
    resources:
    - infrastructure.yaml
    ```
    
    > This is the entry point. The `gotk-sync.yaml` bootstrap Kustomization reconciles `./mgmt-cluster` and finds this file. It only lists Flux Kustomization CRDs — one per layer. Add `apps.yaml` here later for application workloads.
    > 
    
    **File 2 — `mgmt-cluster/infrastructure.yaml`** (Flux Kustomization CRD — tells Flux to reconcile the infrastructure directory):
    
    ```yaml
    ---
    apiVersion: kustomize.toolkit.fluxcd.io/v1
    kind: Kustomization
    metadata:
    name: infrastructure
    namespace: flux-system
    spec:
    interval: 1h
    retryInterval: 2m
    timeout: 5m
    sourceRef:
    kind: GitRepository
    name: flux-system
    path: ./mgmt-cluster/infrastructure
    prune:true
    wait:true
    ```
    
    **File 3 — `mgmt-cluster/infrastructure/kustomization.yaml`** (native Kustomize — lists the actual infrastructure resources):
    
    ```yaml
    ---
    apiVersion: kustomize.config.k8s.io/v1beta1
    kind: Kustomization
    resources:
    - sources.yaml
    - external-secrets/helmrelease.yaml
    - external-secrets/cluster-secret-store.yaml
    - external-secrets/externalsecret-grafana.yaml
    - external-secrets/externalsecret-garage.yaml
    - prometheus/helmrelease.yaml
    - loki/helmrelease.yaml
    ```
    
    The full reconciliation flow:
    
    ```
    gotk-sync.yaml (bootstrap Kustomization, reconciles ./mgmt-cluster)
      → mgmt-cluster/kustomization.yaml (native Kustomize, lists infrastructure.yaml)
        → infrastructure.yaml (Flux CRD, applied to cluster)
          → Flux independently reconciles ./mgmt-cluster/infrastructure
            → infrastructure/kustomization.yaml (native Kustomize, lists HelmReleases etc.)
    ```
    
- [x]  Push to Git — Flux will reconcile automatically

### 5c. Configure Workload Cluster → Management Cluster Data Flow

- [x]  Deploy **Alloy** as a DaemonSet in the **workload cluster** (via ArgoCD):
    - [x]  Create `argocd/apps/alloy.yaml`
    - [x]  Create `apps/monitoring/alloy/values.yaml`:
        - Ship logs to Loki on mgmt-plane: `http://192.168.40.52:3100/loki/api/v1/push`
        - Scrape workload cluster Kubernetes metrics and forward to mgmt Prometheus via remote-write
    - [x]  Sync via ArgoCD
- [x]  Configure Grafana data sources on the mgmt cluster (can be done via Helm values or provisioning):

```yaml
# Port forward to access Grafana UI
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80

# Get Grafana Password (username is usually 'admin')
kubectl get secret grafana-admin-secret -n monitoring -o json | jq '.data | map_values(@base64d)'
```

- Prometheus (local on mgmt-plane)
- Loki (local on mgmt-plane)
- Alertmanager (local on mgmt-plane)

```yaml
# Verify metrics are flowing
curl -s "http://192.168.40.52:30090/api/v1/query?query=kube_node_info" | \
  jq '[.data.result[] | {node: .metric.node, cluster: .metric.cluster}]'
  
# Should show gandalf, aragorn, legolas, gimli alongside ubuntu
```

- [x]  Import/build Grafana dashboards:
    - [x]  Cluster overview (node CPU, RAM, disk)
    - [x]  Pod health and restarts
    - [x]  NFS server metrics (from node_exporter on nfs-server VM)
    - [x]  Cilium/Hubble network flows
    - [x]  Garage S3 metrics
- [ ]  Configure Alertmanager notification routing:
    - [ ]  Create a Discord webhook (or Slack, email)
    - [ ]  Configure alert routes for: node down, high CPU/memory, NFS unreachable, cert expiry, PVC near capacity
    - [ ]  Test an alert fires and notification arrives

### Verification

- [ ]  Flux reconciliation is healthy: `flux get all` (on mgmt-plane)
- [x]  Prometheus is scraping targets: check Prometheus UI targets page
- [x]  Loki is receiving logs: query `{namespace="kube-system"}` in Grafana
- [x]  Grafana dashboards load with real data
- [ ]  Alertmanager has routes configured: check Alertmanager UI
- [ ]  Test alert notification reaches your channel
- [ ]  Management cluster survives workload cluster being offline (kill a workload node and verify monitoring stays up)

---

## Phase 6: HashiCorp Vault — Dynamic Secrets

**Goal:** Vault deployed on the workload cluster, integrated with ESO for dynamic secret delivery to applications.

> **Why Vault alongside GCP SM?** GCP Secret Manager handles static infrastructure secrets (API tokens, Cloudflare credentials). Vault handles dynamic secrets — short-lived database credentials that are generated on-demand and automatically revoked. Together they demonstrate understanding of when to use each tool. The ESO integration means your GitOps workflow is identical regardless of the secret source.
> 
> 
> **Why ESO over VSO (Vault Secrets Operator)?** VSO only speaks Vault, so using it alongside ESO (which handles GCP SM) would mean running two operators for no benefit. More importantly, GCP SM is deliberately kept for bootstrap-critical secrets because Vault has a cold-start dependency — it requires manual unsealing after pod restarts. Secrets needed to bring up cert-manager, Cloudflared, and the rest of the platform must be available before Vault is operational. ESO handles both backends with identical `ExternalSecret` CRDs, keeping application manifests backend-agnostic.
> 

### 6a. Deploy Vault via ArgoCD

- [x]  Create `argocd/apps/vault.yaml`:
    
    ```yaml
    ---
    apiVersion: argoproj.io/v1alpha1
    kind: Application
    metadata:
      name: vault
      namespace: argocd
      annotations:
        argocd.argoproj.io/sync-wave: "3"
    spec:
      project: homelab
      source:
        repoURL: oci://registry-1.docker.io/bitnamicharts
        chart: vault
        targetRevision: 1.9.0
        helm:
          valuesObject:
            server:
              config: |
                ui = true
                listener "tcp" {
                  address = "[::]:8200"
                  tls_disable = 1
                }
                storage "raft" {
                  path = "/bitnami/vault/data"
                }
                telemetry {
                  prometheus_retention_time = "30s"
                  disable_hostname = true
                  unauthenticated_metrics_access = true
                }
    
              persistence:
                enabled: true
                storageClass: nfs-zfs-retain
                size: 5Gi
    
              resources:
                requests:
                  memory: 256Mi
                  cpu: 250m
                limits:
                  memory: 512Mi
    
              metrics:
                enabled: true
    
      destination:
        server: https://kubernetes.default.svc
        namespace: vault
    
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
          - ServerSideApply=true
    ```
    
- [x]  Sync via ArgoCD
- [x]  Wait for the Vault pod to be running (it will be in `0/1 Running` — not ready until initialized)

### 6b. Initialize and Unseal Vault

- [x]  Initialize Vault:
    
    ```bash
    kubectl exec -n vault vault-0 -- vault operator init \
      -key-shares=5 \
      -key-threshold=3 \
      -format=json > vault-init.json
    ```
    
    > **CRITICAL:** Save `vault-init.json` securely. This contains your unseal keys and initial root token. Store it encrypted on your workstation (e.g., in a GPG-encrypted file or your password manager). Do NOT commit it to Git. Don't rely on ESO + GCP SM as your only access path to the unseal keys — it’s fine as a backup though. Storing in GCP SM + password manager is architecturally sound.
    > 
- [x]  Unseal Vault (need 3 of 5 keys):
    
    ```bash
    # Repeat with 3 different unseal keys from vault-init.json
    kubectl exec -n vault vault-0 -- vault operator unseal <key-1>
    kubectl exec -n vault vault-0 -- vault operator unseal <key-2>
    kubectl exec -n vault vault-0 -- vault operator unseal <key-3>
    ```
    
- [x]  Verify Vault is unsealed and ready:
    
    ```bash
    kubectl exec -n vault vault-0 -- vault status
    # Sealed: false
    # HA Enabled: false
    ```
    
- [x]  Log in with the root token:
    
    ```bash
    kubectl exec -n vault vault-0 -- vault login <root-token>
    ```
    

### 6c. Configure Vault Secrets Engines

- [x]  Enable the **KV v2 secrets engine** (for general secrets):
    
    ```bash
    kubectl exec -n vault vault-0 -- vault secrets enable -path=secret kv-v2\
    # Success! Enabled the kv-v2 secrets engine at: secret/
    ```
    
- [x]  Enable the **database secrets engine** (for dynamic DB credentials):
    
    ```bash
    kubectl exec -n vault vault-0 -- vault secrets enable database
    # Success! Enabled the database secrets engine at: database/
    ```
    
    > The database engine will be configured with specific Postgres connections when applications are deployed (Uptime Kuma in Phase 7, or Authentik/n8n in Upgrades). For now, enabling the engine is sufficient.
    > 
- [x]  Create a policy for ESO to read secrets:
    
    ```bash
    kubectl exec -n vault vault-0 -- vault policy write eso-reader - <<EOF
    path "secret/data/*" {
      capabilities = ["read"]
    }
    path "database/creds/*" {
      capabilities = ["read"]
    }
    EOF
    ```
    

### 6d. Enable Kubernetes Auth for ESO

- [x]  Enable Kubernetes authentication in Vault:
    
    ```bash
    kubectl exec -n vault vault-0 -- vault auth enable kubernetes
    ```
    
- [x]  Configure the Kubernetes auth method:
    
    ```bash
    kubectl exec -n vault vault-0 -- sh -c '
      vault write auth/kubernetes/config \
        kubernetes_host="https://$KUBERNETES_PORT_443_TCP_ADDR:443"
    '
    ```
    
- [x]  Create a role for ESO:
    
    ```bash
    kubectl exec -n vault vault-0 -- vault write auth/kubernetes/role/eso \
      bound_service_account_names=external-secrets \
      bound_service_account_namespaces=external-secrets \
      policies=eso-reader \
      ttl=1h
    ```
    
    Verify Vault policies:
    
    ```yaml
    # List all Vault policies:
    kubectl exec vault-0 -n vault -- vault policy list
    
    # Read a specific policy:
    kubectl exec vault-0 -n vault -- vault policy read <policy_name>
    ```
    

### 6e. Add Vault as an ESO SecretStore

- [x]  Create `apps/external-secrets/vault-secret-store.yaml`:
    
    ```yaml
    ---
    apiVersion: external-secrets.io/v1
    kind: ClusterSecretStore
    metadata:
      name: vault
    spec:
      provider:
        vault:
          server: "http://vault.vault.svc.cluster.local:8200"
          path: "secret"
          version: "v2"
          auth:
            kubernetes:
              mountPath: "kubernetes"
              role: "eso"
              serviceAccountRef:
                name: external-secrets
                namespace: external-secrets
                audiences:
                  - vault
    ```
    
- [x]  Sync via ArgoCD
- [x]  Verify the store is healthy:
    
    ```bash
    kubectl get clustersecretstore vault
    # NAME    AGE   STATUS   CAPABILITIES   READY
    # vault   30s   Valid    ReadWrite       True
    ```
    

### 6f. Test the Integration

- [x]  Write a test secret to Vault:
    
    ```bash
    kubectl exec -n vault vault-0 -- vault kv put secret/test hello=world
    ```
    
- [x]  Create an ExternalSecret that reads from Vault:
    
    ```bash
    kubectl apply -f - <<EOF
    apiVersion: external-secrets.io/v1
    kind: ExternalSecret
    metadata:
      name: vault-test
      namespace: default
    spec:
      refreshInterval: 1m
      secretStoreRef:
        name: vault
        kind: ClusterSecretStore
      target:
        name: vault-test-secret
      data:
        - secretKey: hello
          remoteRef:
            key: test
            property: hello
    EOF
    ```
    
- [x]  Verify the secret was created:
    
    ```bash
    kubectl get secret vault-test-secret -o jsonpath='{.data.hello}' | base64 -d
    # Should output: world
    ```
    
- [x]  Clean up test resources:
    
    ```bash
    kubectl delete externalsecret vault-test
    kubectl delete secret vault-test-secret
    kubectl exec -n vault vault-0 -- vault kv delete secret/test
    ```
    

### 6g. Create HTTPRoute for Vault UI

- [x]  Add `apps/platform-ingress/vault-route.yaml`:
    
    ```yaml
    ---
    apiVersion: gateway.networking.k8s.io/v1
    kind: HTTPRoute
    metadata:
      name: vault-route
      namespace: vault
    spec:
      parentRefs:
        - name: homelab-gateway
          namespace: gateway
      hostnames:
        - vault.daltonbuilds.com
      rules:
        - matches:
            - path:
                type: PathPrefix
                value: /
          backendRefs:
            - name: vault-ui
              port: 8200
    ```
    
- [x]  Add DNS record for vault.daltonbuilds.com in Cloudflare (or add to Cloudflared tunnel config)

### Verification

- [x]  Vault pod running and unsealed: `kubectl exec -n vault vault-0 -- vault status`
- [x]  Vault UI accessible via browser
- [x]  KV v2 and database secrets engines enabled: `vault secrets list`
- [x]  Kubernetes auth configured: `vault auth list`
- [x]  ESO ClusterSecretStore for Vault shows `Ready: True`
- [x]  ExternalSecret successfully pulls from Vault
- [x]  You now have **two** ClusterSecretStores: `gcp-secret-manager` (static) and `vault` (dynamic)
- [x]  Root token stored securely offline

> **Operational note:** If the Vault pod restarts (node reboot, pod eviction, etc.), you must unseal it again. This takes ~30 seconds with 3 unseal keys. Auto-unseal via GCP KMS is available as a future upgrade.
> 

---

## Phase 7: Demo Application — Uptime Kuma

**Goal:** Deploy a real application on the platform to prove the full stack works end-to-end.

> Uptime Kuma is ideal for this: it’s simple, useful (monitors your other services), and exercises the full platform — NFS storage, Gateway API routing, TLS via cert-manager, external access via Cloudflared, and secrets via ESO.
> 

### 7a. Deploy Uptime Kuma

- [x]  Create `argocd/apps/uptime-kuma.yaml`:
    
    ```yaml
    apiVersion: argoproj.io/v1alpha1
    kind: Application
    metadata:
    name: uptime-kuma
    namespace: argocd
    annotations:
    argocd.argoproj.io/sync-wave:"5"
    spec:
    project: homelab
    source:
    repoURL: https://github.com/DaltonBuilds/homelab-gitops
    path: apps/uptime-kuma
    targetRevision: main
    destination:
    server: https://kubernetes.default.svc
    namespace: uptime-kuma
    syncPolicy:
    automated:
    prune:true
    selfHeal:true
    syncOptions:
    - CreateNamespace=true
    - ServerSideApply=true
    ```
    
- [x]  Create `apps/uptime-kuma/deployment.yaml`:
    
    ```yaml
    apiVersion: apps/v1
    kind: Deployment
    metadata:
    name: uptime-kuma
    namespace: uptime-kuma
    labels:
    app.kubernetes.io/name: uptime-kuma
    spec:
    replicas:1
    selector:
    matchLabels:
    app.kubernetes.io/name: uptime-kuma
    template:
    metadata:
    labels:
    app.kubernetes.io/name: uptime-kuma
    spec:
    containers:
    -name: uptime-kuma
    image: louislam/uptime-kuma:1  # Pin to major version
    ports:
    -containerPort:3001
    volumeMounts:
    -name: data
    mountPath: /app/data
    resources:
    requests:
    memory: 128Mi
    cpu: 100m
    limits:
    memory: 256Mi
    volumes:
    -name: data
    persistentVolumeClaim:
    claimName: uptime-kuma-data
    ---
    apiVersion: v1
    kind: Service
    metadata:
    name: uptime-kuma
    namespace: uptime-kuma
    spec:
    selector:
    app.kubernetes.io/name: uptime-kuma
    ports:
    -port:80
    targetPort:3001
    ---
    apiVersion: v1
    kind: PersistentVolumeClaim
    metadata:
    name: uptime-kuma-data
    namespace: uptime-kuma
    spec:
    accessModes:
    - ReadWriteOnce
    storageClassName: nfs-zfs-retain
    resources:
    requests:
    storage: 2Gi
    ```
    
- [x]  Create `apps/uptime-kuma/httproute.yaml`:
    
    ```yaml
    apiVersion: gateway.networking.k8s.io/v1
    kind: HTTPRoute
    metadata:
    name: uptime-kuma-route
    namespace: uptime-kuma
    spec:
    parentRefs:
    -name: homelab-gateway
    namespace: gateway
    hostnames:
    - status.daltonbuilds.com
    rules:
    -backendRefs:
    -name: uptime-kuma
    port:80
    ```
    
- [x]  Add DNS record / Cloudflared tunnel config for `status.daltonbuilds.com`
- [x]  Sync via ArgoCD

### 7b. Configure Monitors

- [x]  Access Uptime Kuma via browser, create admin account
- [ ]  Add monitors:
    - [ ]  ArgoCD — HTTPS check on `argocd.daltonbuilds.com`
    - [ ]  Vault UI — HTTPS check on `vault.daltonbuilds.com`
    - [ ]  NFS server — TCP check on `192.168.40.51:2049`
    - [ ]  Garage — HTTP check on `http://192.168.40.53:3903/health`
    - [ ]  Grafana — will be added after setting up mgmt cluster ingress (or use direct IP)

### Verification

- [x]  Uptime Kuma shows `Healthy` and `Synced` in ArgoCD
- [x]  Accessible via `status.daltonbuilds.com` through Cloudflared tunnel
- [x]  TLS certificate issued by cert-manager
- [ ]  PVC bound on `nfs-zfs-retain` StorageClass
- [ ]  Monitors are active and reporting status
- [ ]  This proves the full pipeline: Git → ArgoCD → Kubernetes → Cilium Gateway → Cloudflared → browser

---

## Phase 8: Documentation & Portfolio Polish

**Goal:** Make the repos something you’d be proud to share with a hiring manager.

### 8a. Architecture Diagram

- [ ]  Create a Mermaid diagram (or draw.io exported to SVG) showing:
    - Physical machines and VMs
    - Network topology (VLANs 10, 40)
    - Data flow: user → Cloudflare → Cloudflared → Cilium Gateway → services
    - Monitoring flow: workload cluster → Alloy → mgmt cluster (Prometheus/Loki/Grafana)
    - Secrets flow: GCP SM → ESO → Kubernetes secrets (static), Vault → ESO → Kubernetes secrets (dynamic)
- [ ]  Commit diagram to `docs/` and reference in root README

### 8b. Root README.md (for homelab-gitops)

- [ ]  Technology stack table with one-line rationale per tool:
    
    
    | Component | Tool | Why |
    | --- | --- | --- |
    | CNI | Cilium | eBPF-based, replaces kube-proxy, native L2 LB + Gateway API |
    | Load Balancing | Cilium L2 | Consolidated into CNI — no separate MetalLB needed |
    | Ingress | Cilium Gateway API | Kubernetes-native, vendor-neutral, replaces Traefik |
    | GitOps (workload) | ArgoCD | App-of-apps pattern, UI for visibility |
    | GitOps (mgmt) | Flux | Demonstrates multi-tool breadth, lightweight |
    | Storage (file) | NFS + ZFS | Snapshots, compression, proven reliability |
    | Storage (object) | Garage | S3-compatible, 1GB RAM vs MinIO’s 4-6GB |
    | Secrets (static) | ESO + GCP SM | No plaintext in Git, cloud-grade secret management |
    | Secrets (dynamic) | Vault | Short-lived DB credentials, auto-rotation, Secret Zero |
    | TLS | cert-manager | Automated Let’s Encrypt via DNS-01 |
    | Tunnel | Cloudflared | Zero-trust external access, no port forwarding |
    | Observability | Prometheus + Loki + Grafana | Industry standard, Alloy for unified collection |
    | IaC | Terraform | Proxmox VMs as code via bpg/proxmox provider |
    | Config Mgmt | Ansible | OS-level config, k3s bootstrap, SSH hardening |
- [ ]  Architecture diagram (embedded)
- [ ]  Repo structure explanation
- [ ]  Quick links to docs

### 8c. Key Documentation

- [ ]  `docs/architecture.md` — Architecture Decision Records (ADRs):
    - Why Cilium over Flannel (eBPF, kube-proxy replacement, L2 LB, Gateway API — one tool for four functions)
    - Why Cilium L2 over MetalLB (reduce component count, Cilium already owns the dataplane)
    - Why Gateway API over Traefik Ingress (Kubernetes-native, vendor-neutral, growing ecosystem standard)
    - Why NFS/ZFS over Longhorn (ZFS snapshots, compression, proven at scale, simpler failure domain)
    - Why Garage over MinIO (memory footprint, single-binary, S3-compatible for the same use cases)
    - Why ESO + GCP SM over Sealed Secrets (central management, audit log, no encryption key management)
    - Why Vault for dynamic secrets (Secret Zero, automatic credential rotation, lease-based revocation)
    - Why ESO over VSO (VSO is Vault-only; ESO handles both GCP SM and Vault with identical CRDs; GCP SM is kept for bootstrap-critical secrets that must be available before Vault unseal)
    - Why independent management cluster (observability survives workload cluster failures)
- [ ]  `docs/network-topology.md` — VLANs, IP allocation, Cilium L2 pool

### Verification

- [ ]  README renders well on GitHub
- [ ]  Architecture diagram is clear and accurate
- [ ]  ADRs are written and committed
- [ ]  No plaintext secrets anywhere in the repo (`git log --all -p | grep -i "password\|secret\|token\|key"` to check)
- [ ]  You can explain every architectural decision if asked in an interview

---

## Post-MVP: Ongoing Operations

These aren’t build steps but habits to maintain:

- [ ]  Monitor Alertmanager notifications — respond to alerts
- [ ]  Keep Helm charts updated (Renovate Bot is a great future addition for automated PRs)
- [ ]  Practice explaining each architectural decision aloud — prepare for interview questions
- [ ]  After Vault pod restarts, unseal within a reasonable window

---

## Upgrades — Post-MVP Enhancements

Everything below is deferred from the MVP. Each section is self-contained and can be tackled independently in any order. They build on the foundation established in Phases 0–8.

---

### Upgrade: Kyverno — Policy Enforcement

**Value:** Admission control preventing misconfigurations. Shows understanding of Kubernetes security posture management.

**What to deploy:**
- Kyverno controller via ArgoCD Helm chart
- Separate ArgoCD app for policies (update policies without restarting controller)
- Policies to create (start in `Audit` mode, switch to `Enforce` after fixing violations):
- `disallow-privileged.yaml` — no privileged containers
- `require-resource-limits.yaml` — all pods must have resource requests/limits
- `require-labels.yaml` — require `app.kubernetes.io/name` and `app.kubernetes.io/part-of`
- `restrict-image-registries.yaml` — allow only docker.io, ghcr.io, quay.io, registry.k8s.io
- `disallow-latest-tag.yaml` — no `:latest` image tags
- `require-non-root.yaml` — all containers run as non-root
- `auto-inject-labels.yaml` — mutating policy to auto-add `managed-by: argocd`

**AppProject update:** Add Kyverno CRDs to `clusterResourceWhitelist`.

**Interview talking point:** “I use Kyverno for admission control — policies start in audit mode so I can fix existing violations before enforcement. This prevents deploying misconfigured workloads while avoiding a flag-day migration.”

---

### Upgrade: Velero — Disaster Recovery

**Value:** Scheduled cluster-state backups with tested restore. Shows operational maturity.

**Prerequisites:** Create `velero-backups` bucket in Garage: `garage bucket create velero-backups`

**What to deploy:**
- Velero via ArgoCD Helm chart
- BackupStorageLocation pointing to Garage S3 (`http://192.168.40.53:3900`, bucket `velero-backups`)
- Garage credentials via ESO (from GCP SM or Vault)
- Scheduled backup: daily at 3 AM, 30-day retention, all namespaces, fsBackup for PVCs

**Critical step:** Test the restore procedure. An untested backup is not a backup.

```bash
# Create test namespace, take backup, delete namespace, restore, verify
velero backup create test-backup --include-namespaces velero-test
kubectl delete namespace velero-test
velero restore create --from-backup test-backup
```

---

### Upgrade: ARC — Self-Hosted CI Runners

**Value:** GitHub Actions runners as ephemeral Kubernetes pods. Shows CI/CD automation at the infrastructure level.

**What to deploy:**
- ARC controller: `oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller`
- RunnerScaleSet: `oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set`
- GitHub PAT or GitHub App credentials via ESO
- Scale from 0 runners when idle, max 3 when jobs are queued

**Important:** Pin the runner image to a specific version (not `:latest`) — especially if Kyverno is deployed.

**Test with:**

```yaml
# .github/workflows/test-runner.yml
name: Test Self-Hosted Runner
on: workflow_dispatch
jobs:
test:
runs-on: arc-runner-set
steps:
-run: echo "Running on self-hosted ARC runner!"
```

---

### Upgrade: Authentik — Identity Provider / SSO

**Value:** Centralized authentication. Shows understanding of identity management in a platform context.

**What to deploy:**
- Authentik via ArgoCD Helm chart
- Postgres database for Authentik on `nfs-zfs-retain` StorageClass
- HTTPRoute for `auth.daltonbuilds.com`
- All secrets via ESO

**Dynamic DB credentials via Vault:**
This is where Vault’s database secrets engine shines. Configure Vault to generate short-lived Postgres credentials for Authentik:

```bash
vault write database/config/authentik-postgres \
  plugin_name=postgresql-database-plugin \
  connection_url="postgresql://{{username}}:{{password}}@authentik-postgres.authentik.svc:5432/authentik?sslmode=disable" \
  allowed_roles="authentik-app" \
  username="vault_admin" \
  password="INITIAL_PASSWORD"

vault write database/roles/authentik-app \
  db_name=authentik-postgres \
  creation_statements="CREATE ROLE\"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; GRANT ALL ON ALL TABLES IN SCHEMA public TO\"{{name}}\";" \
  default_ttl="1h" \
  max_ttl="24h"
```

Then ESO pulls dynamic creds via: `vault read database/creds/authentik-app`

**Integrate with:**
- Grafana (OAuth2 login)
- ArgoCD (OIDC login)
- Vault UI (OIDC login)

---

### Upgrade: n8n — Workflow Automation

**Value:** Self-hosted workflow automation platform for homelab integrations.

**What to deploy:**
- n8n via ArgoCD Helm chart
- Postgres (can share instance with Authentik or run separately)
- PVC on `nfs-zfs-retain` for n8n data
- HTTPRoute for `n8n.daltonbuilds.com`
- All secrets via ESO

---

### Upgrade: pgBackRest — Database WAL Archiving

**Value:** Point-in-time recovery for Postgres databases. Enterprise-grade database DR.

**When to add:** When you have multiple Postgres instances (Authentik, n8n) and want to demonstrate advanced database operations knowledge.

**What to deploy:**
- pgBackRest configured per Postgres instance
- S3 repository pointing to Garage `pgbackrest` bucket
- Full backup weekly, differential daily
- WAL archiving enabled (enables PITR)

**Create bucket:** `garage bucket create pgbackrest`

**Talking point:** “For my homelab scale, pg_dump is sufficient. But I’ve implemented pgBackRest to demonstrate understanding of WAL archiving and point-in-time recovery — the kind of setup you’d need for production databases where full dumps are impractical and RPO requirements are tight.”

---

### Upgrade: restic — Offsite Backups to Workstation

**Value:** 3-2-1 backup rule compliance. Shows operational rigor.

**Strategy by data type:**
1. **Cluster state:** Already covered by Velero → Garage
2. **ZFS data:** `zfs send` (incremental) → workstation — far more efficient than restic for ZFS
3. **Garage data:** restic → workstation via SFTP
4. **Infrastructure:** Terraform + Ansible are the backup (rebuild from code)

**What to deploy:**
- restic configured with SFTP backend to workstation
- systemd timer for nightly runs
- Retention: keep 7 daily, 4 weekly, 6 monthly
- Alertmanager rule for stale backups

---

### Upgrade: NetworkPolicies & Hardening

**Value:** Defense-in-depth. Shows security awareness beyond “it works.”

**What to deploy:**
- Default-deny NetworkPolicy for every namespace
- Explicit allow policies: DNS egress, Gateway ingress, Prometheus scraping, app-specific egress
- RBAC review: no unnecessary cluster-admin bindings
- k3s API server audit logging
- (Optional) CiliumNetworkPolicies for L7 filtering

**Test thoroughly:** A curl pod in a locked-down namespace should be blocked. Legitimate traffic should still work.

---

### Upgrade: Trivy Operator — Vulnerability Scanning

**Value:** Continuous image vulnerability scanning. Lightweight addition.

**What to deploy:**
- Trivy Operator via ArgoCD Helm chart
- Review VulnerabilityReports: `kubectl get vulnerabilityreports -A`
- Alertmanager rules for critical/high CVEs

---

### Upgrade: Vault Auto-Unseal via GCP KMS

**Value:** Vault automatically unseals after pod restarts without manual intervention.

**What to configure:**
- Create a GCP KMS key ring and crypto key
- Update Vault config to use GCP KMS seal stanza:

```
```hcl
seal "gcpckms" {
  project     = "homelab-forge"
  region      = "us-central1"
  key_ring    = "vault-unseal"
  crypto_key  = "vault-key"
}
```
```

- Migrate from Shamir to auto-unseal: `vault operator unseal -migrate`

---

### Upgrade: Full Documentation Suite

**Additional docs beyond the MVP README and architecture.md:**
- `docs/disaster-recovery.md` — Step-by-step restore procedures for each backup path
- `docs/adding-an-app.md` — How to onboard a new service to the platform
- Per-app `README.md` in each `apps/` subdirectory

---

## Final Repo Structure (MVP + Upgrades path)

```
homelab-gitops/
├── README.md
├── docs/
│   ├── architecture.md          # ADRs
│   └── network-topology.md      # VLANs, IPs, Cilium L2
├── argocd/
│   ├── root.yaml
│   └── apps/
│       ├── app-project-homelab.yaml
│       ├── gateway-api-crds.yaml
│       ├── cilium.yaml
│       ├── cert-manager.yaml
│       ├── cert-manager-config.yaml
│       ├── external-secrets.yaml
│       ├── external-secrets-store.yaml
│       ├── nfs-provisioner-helm.yaml
│       ├── nfs-provisioner.yaml
│       ├── gateway.yaml
│       ├── cloudflared.yaml
│       ├── vault.yaml
│       ├── alloy.yaml
│       ├── platform-ingress.yaml
│       └── uptime-kuma.yaml
├── apps/
│   ├── cilium/
│   │   ├── values.yaml
│   │   ├── ip-pool.yaml
│   │   └── l2-policy.yaml
│   ├── cert-manager/
│   │   ├── cloudflare-secret.yaml
│   │   └── cluster-issuer.yaml
│   ├── external-secrets/
│   │   ├── cluster-secret-store.yaml       # GCP SM
│   │   └── vault-secret-store.yaml         # Vault
│   ├── gateway/
│   │   └── gateway.yaml
│   ├── nfs-provisioner/
│   │   ├── storageclass-nfs-zfs-retain.yaml
│   │   └── storageclass-nfs-zfs-delete.yaml
│   ├── vault/
│   │   └── (managed via Helm values in ArgoCD app)
│   ├── monitoring/
│   │   └── alloy/
│   │       └── values.yaml
│   ├── platform-ingress/
│   │   ├── argocd-route.yaml
│   │   ├── hubble-route.yaml
│   │   └── vault-route.yaml
│   ├── cloudflared/
│   │   └── deployment.yaml
│   └── uptime-kuma/
│       ├── deployment.yaml
│       └── httproute.yaml
└── mgmt-cluster/
    ├── kustomization.yaml          # Native Kustomize — entry point, lists Flux CRDs per layer
    ├── infrastructure.yaml         # Flux Kustomization CRD — independent reconciliation of infrastructure/
    ├── flux-system/
    │   ├── gotk-components.yaml
    │   ├── gotk-sync.yaml          # Bootstrap Kustomization — reconciles ./mgmt-cluster
    │   └── kustomization.yaml
    └── infrastructure/
        ├── kustomization.yaml      # Native Kustomize — lists HelmReleases, sources, secrets
        ├── sources.yaml
        ├── prometheus/
        │   └── helmrelease.yaml
        ├── loki/
        │   └── helmrelease.yaml
        └── grafana/
            ├── helmrelease.yaml
            └── dashboards/
```

---

## Workstation Kubeconfig Management — `pass` + Chezmoi + Mise

**Goal:** Kubeconfigs for all clusters managed securely via `pass` (GPG-encrypted password store), distributed to any workstation via Chezmoi templates, with multi-cluster context switching via kubectx/kubens (installed by Mise). No secrets in the public dotfiles repo — ever.

> **Why `pass` over Vault, Bitwarden, or GCP SM?**
> 
> - **Not Vault:** Vault runs inside the clusters it provides access to — chicken-and-egg. Kubeconfigs are infrastructure access credentials, not application secrets. They belong in a workstation-level secrets store, not a cluster-level one.
> - **Not GCP SM:** Would work (Chezmoi supports it), but requires network access and `gcloud` auth before you can apply dotfiles. Breaks the “one command on a fresh machine” goal.
> - **Not Bitwarden/1Password:** Adds a SaaS dependency and requires a running daemon/CLI auth flow during `chezmoi apply`.
> - **`pass` wins because:** GPG-encrypted, Git-backed, works offline, zero infrastructure dependencies, native Chezmoi integration. The `pass` store lives in a **private** Git repo — encrypted at rest with your GPG key, never touches the public dotfiles repo.

> **Design principle:** `pass`/Chezmoi handles **workstation credentials** (kubeconfigs, SSH configs, etc.). Vault handles **application secrets** (dynamic DB creds, PKI) inside the cluster. These are separate concerns with separate lifecycles.
> 

### Prerequisites

- [ ]  GPG key pair (if you don’t already have one)
- [ ]  Private Git repo for the password store (e.g., `github.com:DaltonBuilds/pass-store.git` — private)

### Step 1: Install `pass` and Initialize the Store

- [ ]  Generate a GPG key (skip if you already have one):
    
    ```bash
    gpg --full-generate-key
    # Select: RSA and RSA, 4096 bits, does not expire
    # Use your real name and email — this key identifies you
    ```
    
- [ ]  Note your GPG key ID:
    
    ```bash
    gpg --list-keys --keyid-format long
    # Look for the line like: pub   rsa4096/ABCDEF1234567890
    # ABCDEF1234567890 is your key ID
    ```
    
- [ ]  Install `pass`:
    
    ```bash
    # Fedora
    sudo dnf install pass
    
    # Ubuntu/Debian
    sudo apt install pass
    ```
    
- [ ]  Initialize the password store:
    
    ```bash
    pass init "ABCDEF1234567890"  # Your GPG key ID
    ```
    
- [ ]  Initialize Git tracking for the store:
    
    ```bash
    pass git init
    pass git remote add origin git@github.com:DaltonBuilds/pass-store.git
    ```
    

### Step 2: Store Kubeconfigs in `pass`

- [ ]  Insert each kubeconfig (after your clusters are up and you have the files):
    
    ```bash
    pass insert -m homelab/kubeconfig-fellowship < ~/.kube/config-fellowship
    pass insert -m homelab/kubeconfig-mgmt < ~/.kube/config-mgmt
    ```
    
- [ ]  Verify they’re stored:
    
    ```bash
    pass homelab/kubeconfig-fellowship | head -5
    # Should show the YAML header of your kubeconfig
    ```
    
- [ ]  Push the encrypted store to your private repo:
    
    ```bash
    pass git push -u origin main
    ```
    

> **Updating kubeconfigs:** If a cluster is rebuilt or certs rotate, just re-insert:
> 
> 
> ```bash
> pass insert -m homelab/kubeconfig-fellowship < ~/.kube/config-fellowship
> # pass will ask to overwrite — say yes
> pass git push
> ```
> 

### Step 3: Add kubectx and kubens to Mise

- [ ]  Update `dot_config/mise/config.toml` in your Chezmoi source:
    
    ```toml
    [tools]
    starship = "latest"
    ripgrep = "latest"
    bat = "latest"
    kubectx = "latest"
    kubectl = "latest"
    ```
    
    > `kubectx` via Mise includes both `kubectx` and `kubens`. `kubectl` is included so every workstation gets it without a separate install.
    > 

### Step 4: Create Chezmoi Templates for Kubeconfigs

- [ ]  Create the kubeconfig template files in your Chezmoi source directory:
    
    ```bash
    mkdir -p ~/.local/share/chezmoi/private_dot_kube
    ```
    
    > **Why `private_dot_kube`?** The `private_` prefix tells Chezmoi to set directory permissions to `0700` — matching the default `~/.kube/` permissions. Files inside inherit restrictive permissions.
    > 
- [ ]  Create `private_dot_kube/config-fellowship.tmpl`:
    
    ```
    {{ pass "homelab/kubeconfig-fellowship" }}
    ```
    
- [ ]  Create `private_dot_kube/config-mgmt.tmpl`:
    
    ```
    {{ pass "homelab/kubeconfig-mgmt" }}
    ```
    
    > **That’s it.** Each template is a single line. Chezmoi calls `pass` at apply time, decrypts the kubeconfig with your GPG key, and writes it to `~/.kube/config-fellowship` (etc.).
    > 
- [ ]  Set file permissions by adding a `.chezmoiattrs` file in `private_dot_kube/`:
    
    ```
    config-fellowship.tmpl  mode = "0600"
    config-mgmt.tmpl        mode = "0600"
    ```
    

### Step 5: Add KUBECONFIG Auto-Discovery to Shell Config

- [ ]  Convert `dot_bashrc` to a template (`dot_bashrc.tmpl`) and add the KUBECONFIG block, **or** add a dedicated file in `~/.bashrc.d/` via Chezmoi. The `~/.bashrc.d/` approach is cleaner since your bashrc already sources that directory:
- [ ]  Create `private_dot_bashrc.d/kubeconfig.sh` in Chezmoi source (use `private_` since it references infrastructure paths):
    
    ```bash
    # Auto-discover all kubeconfigs in ~/.kube/
    # Builds KUBECONFIG env var from all config-* files
    KUBECONFIG_DIRS="$HOME/.kube"
    KUBECONFIG_FILES=""
    
    for config in "$KUBECONFIG_DIRS"/config-*; do
        [ -f "$config" ] || continue
        if [ -z "$KUBECONFIG_FILES" ]; then
            KUBECONFIG_FILES="$config"
        else
            KUBECONFIG_FILES="$KUBECONFIG_FILES:$config"
        fi
    done
    
    # Include the default config if it exists
    if [ -f "$KUBECONFIG_DIRS/config" ]; then
        KUBECONFIG_FILES="$KUBECONFIG_DIRS/config:$KUBECONFIG_FILES"
    fi
    
    if [ -n "$KUBECONFIG_FILES" ]; then
        export KUBECONFIG="$KUBECONFIG_FILES"
    fi
    ```
    
    > This script runs on every shell startup and builds the `KUBECONFIG` env var from whatever `config-*` files exist in `~/.kube/`. Adding a new cluster is just `pass insert -m homelab/kubeconfig-newcluster`, adding a new Chezmoi template, and `chezmoi apply`. The shell config picks it up automatically.
    > 

### Step 6: New Workstation Bootstrap

On a fresh machine, the full flow is:

```bash
# 1. Import your GPG key (from a secure backup — USB drive, etc.)
gpg --import /path/to/private-key.asc

# 2. Clone the pass store
git clone git@github.com:DaltonBuilds/pass-store.git ~/.password-store

# 3. Run chezmoi (your existing bootstrap handles this)
chezmoi init --apply DaltonBuilds/dotfiles

# That's it. You now have:
# - ~/.kube/config-fellowship  (decrypted from pass)
# - ~/.kube/config-mgmt        (decrypted from pass)
# - KUBECONFIG env var set      (auto-discovery script)
# - kubectx, kubens, kubectl    (installed by mise)
```

> **The only manual step** is importing your GPG key — which is intentional. The GPG key is your identity; it should never be automated or stored in a system it protects. Keep a backup on an encrypted USB drive or in a physical safe.
> 

### Step 7: GPG Key Backup (Do This Immediately After Step 1)

- [ ]  Export your private key:
    
    ```bash
    gpg --export-secret-keys --armor ABCDEF1234567890 > gpg-private-key.asc
    ```
    
- [ ]  Store this file on an **encrypted USB drive** or print as a paper backup. This is your recovery path — if you lose this key, you cannot decrypt your password store.
- [ ]  **Do NOT** store the GPG private key in `pass`, GCP SM, or anywhere that depends on the key itself to decrypt.

### Verification

- [ ]  From your workstation: `chezmoi apply --dry-run --verbose` shows kubeconfig files would be written
- [ ]  `chezmoi apply` writes kubeconfigs to `~/.kube/` with `0600` permissions
- [ ]  `echo $KUBECONFIG` shows all discovered configs joined by `:`
- [ ]  `kubectx` lists both clusters (fellowship, mgmt)
- [ ]  `kubens` switches namespaces within the current context
- [ ]  `kubectl get nodes` works against the selected context

### Chezmoi Source Tree After This Change

```
~/.local/share/chezmoi/
├── .chezmoi.toml.tmpl
├── .chezmoiignore
├── .chezmoiexternals/
│   ├── chezmoi.toml
│   └── mise.toml
├── .chezmoiscripts/
│   └── run_onchange_after_install-mise-packages.sh.tmpl
├── dot_bashrc
├── dot_config/
│   ├── ghostty/config
│   ├── mise/config.toml            # + kubectx, kubectl
│   └── starship.toml
├── dot_vimrc
├── private_dot_bashrc.d/
│   └── kubeconfig.sh               # NEW — KUBECONFIG auto-discovery
├── private_dot_kube/
│   ├── .chezmoiattrs               # NEW — file permissions
│   ├── config-fellowship.tmpl      # NEW — pulls from pass
│   └── config-mgmt.tmpl            # NEW — pulls from pass
├── install.sh
└── setup
```

Additional Notes (4th Iteration Planning):

- RKE2
- Ansible Galaxy for OIDC (get rid of Ansible Vault completely)
    - e.g. `keycloak_identity_provider`
    - Also check cloud collections for solutions from GCP, Azure, AWS
- Vault + GCP SM KMS for Auto-Unseal:
    1. On your Vault VM, create an **AppRole**.
    2. Give the AppRole a `RoleID` and `SecretID`.
    3. On your management machine (where you run Ansible), set these as environment variables.
    4. Use the `community.hashi_vault` collection to authenticate using that AppRole.
        - **Security Note:** When using **GCP KMS for Auto-Unseal**, ensure the Service Account running on your Vault VM has the absolute **minimum permissions** (IAM role `roles/cloudkms.cryptoKeyEncrypterDecrypter`) only on that specific key to prevent broader cloud exposure.

---

- **Eliminate Environment Variable Leaks**: Move from `env` variables to **Volume Mounts** to prevent secrets from appearing in process trees, logs, or `kubectl describe` outputs.
- **Implement Least Privilege (Filesystem)**: Use `defaultMode: 256` (0400) in Pod specs to ensure secrets are only readable by the application user, not every process in the container.
- **Remove etcd Persistence (CSI Driver)**: Deploy the **Secrets Store CSI Driver** (optional) with the GCP provider to mount secrets directly from GCP SM into pods as ephemeral `tmpfs` volumes, bypassing the creation of native K8s Secret objects entirely (no longer lives in etcd).
    - **Enable Secret Rotation**: Leverage the CSI Driver’s "auto-rotation" feature so your application can consume updated credentials from the mount point without requiring a Pod restart.
    
    ```yaml
    spec:
      containers:
      - name: my-app
        volumeMounts:
        - name: secret-volume
          mountPath: "/etc/secrets"
          readOnly: true
      volumes:
      - name: secret-volume
        secret:
          secretName: my-synced-secret
          defaultMode: 256 # This is 0400 in decimal (read-only for owner)
    ```
