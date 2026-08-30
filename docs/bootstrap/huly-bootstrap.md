[← Docs index](../README.md) · **Operation Long Haul v5** · companion to [Tier 0 · Foundation](../build/tier-0-foundation.md)

# Huly Bootstrap — Operation Long Haul v5

> **Purpose:** Stand up Huly as the temporary project-management system for the homelab build immediately after Proxmox is available, without waiting for Kubernetes or the rest of the platform.
>
> **Lifecycle:** This is intentionally **bootstrap infrastructure**, not the final Huly architecture. Run Huly on one simple Ubuntu VM with Docker Compose, use it to manage the v5 build, then migrate it onto `homelab-mgmt` after the platform is stable.

> **Where this fits in the build (sequencing):**
> - **Prerequisites:** [Tier 0](../build/tier-0-foundation.md) **Phase 0.1** (Proxmox on at least the first host) and **Phase 0.2** (management VLAN 40 reachable). Nothing else is required.
> - **Runs before Phase 0.4 (OpenBao).** Huly is a *deliberate manual-provisioning exception* — the second one in the build, alongside the hand-provisioned OpenBao VMs. Because it comes up before OpenBao and OpenTofu exist, it **cannot** be provisioned the "proper" IaC way yet, and that is intentional for bootstrap. The rest of the platform's strict "everything via OpenTofu + Vault auth" rule resumes at Tier 1.
> - **Exit criteria** (§7 below) gate you back to Phase 0.3. Seed the initial backlog from [`../../huly/work-breakdown.md`](../../huly/work-breakdown.md).
> - **Later:** re-homed onto `homelab-mgmt` (Flux-managed, proper storage/DR) per §Future Migration — at which point it *does* become IaC-managed.

---

## Bootstrap Architecture

```text
Workstation
    |
    |  LAN only initially
    v
Proxmox
└── huly-bootstrap (Ubuntu VM)
    ├── Nginx
    ├── Docker Engine + Compose
    └── Huly self-host stack
        ├── Huly services
        ├── CockroachDB
        ├── Redpanda
        ├── Elasticsearch
        └── persistent Docker volumes
```

**Keep this deliberately boring.** No Kubernetes, HA, external database, GitOps, or elaborate monitoring yet. The point is to get the work-management system online before the real build begins.

---

## 1. Create the Bootstrap VM

Create the first VM after the Proxmox hosts are available.

**Suggested VM:**

| Setting | Value |
|---|---|
| Hostname | `huly-bootstrap` |
| OS | Ubuntu Server 24.04 LTS |
| vCPU | 2 initially; increase to 4 if needed |
| RAM | 8 GB initially; increase to 16 GB if needed |
| Disk | 80–100 GB |
| Network | Management network / VLAN 40 when available |
| IP | Stable DHCP reservation or unused static address |

Huly currently documents **2 vCPU / 8 GB as the minimum** and **4 vCPU / 16 GB+ as recommended**. For one user, start at the minimum and resize the VM if the stack is memory-constrained.

During Ubuntu installation:

- Create an admin user with your SSH public key.
- Disable password-based SSH if convenient during install.
- Install/enable the QEMU guest agent.
- Do **not** expose this VM directly to the public internet.

After first login:

```bash
sudo apt update
sudo apt full-upgrade -y
sudo apt install -y git nginx qemu-guest-agent ca-certificates curl
sudo systemctl enable --now qemu-guest-agent nginx
```

---

## 2. Install Docker Engine + Compose

Use Docker's official Ubuntu repository rather than Ubuntu's `docker.io` package.

```bash
# Docker signing key
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# Docker apt repository
sudo tee /etc/apt/sources.list.d/docker.sources <<EOF2
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF2

sudo apt update
sudo apt install -y \
  docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin

sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"
newgrp docker

# Verify
docker run --rm hello-world
docker compose version
```

---

## 3. Clone and Configure Huly

Use Huly's dedicated self-host repository. Do **not** deploy from the `develop` branch of the main platform repository.

```bash
cd ~
git clone https://github.com/hcengineering/huly-selfhost.git
cd huly-selfhost
```

Before deploying, check the Huly releases and use a production `v*` tag/version rather than a development build.

Run the full setup rather than `./setup.sh --quick`; quick mode is documented for local testing only.

```bash
./setup.sh
```

For this bootstrap deployment:

- Use the VM's stable LAN address / hostname for `HOST_ADDRESS`.
- Keep the service **LAN-only**.
- It is acceptable to start with HTTP during this short bootstrap stage if the service is reachable only from the trusted management network.
- Use the default Docker named volumes unless you have a specific reason to bind them to host paths.
- Treat the generated `huly_v7.conf` as **sensitive configuration** and never commit it to Git.

The setup script generates Huly configuration and an Nginx configuration. Enable it:

```bash
sudo ln -s "$(pwd)/nginx.conf" /etc/nginx/sites-enabled/huly.conf
sudo nginx -t
sudo nginx -s reload

docker compose pull
docker compose up -d
```

Give the stack roughly a minute to initialize, then verify:

```bash
docker compose ps
```

Open the configured Huly address from your workstation and create the initial account/workspace.

If the UI loads but account creation fails:

```bash
docker compose logs -f account
```

---

## 4. Create the Initial Workspace

Create one workspace for the platform build, for example:

**Workspace:** `Operation Long Haul`

Do only enough configuration to begin working. The detailed Huly information architecture is maintained in **[`../../huly/work-breakdown.md`](../../huly/work-breakdown.md)** — that doc holds the full mapping and a ready-to-enter Tier 0 backlog. The intended model is:

```text
Operation Long Haul v5
│
├── Milestone: Tier 0 — Foundation
├── Milestone: Tier 1 — Platform Provisioning
├── Milestone: Tier 2 — Platform Services
├── Milestone: Tier 3 — Observability & Identity
├── Milestone: Tier 4 — Workloads & Delivery
└── Milestone: Tier 5 — MLOps

Within each milestone:
Capability → Epic → Story / Spike → Task
```

The mapping from build doc to Huly, in one line: **Tier → Milestone, Phase → Epic, phase steps → Stories/Tasks, verification gates → a gate Story, and Future-Upgrades items → Spikes.** See the work-breakdown doc for the worked Tier 0 example and the Tier 1–5 skeleton.

Do **not** spend days perfecting Huly before beginning the lab. Once the hierarchy, statuses, and first Tier 0 work items are usable, start the actual build.

---

## 5. Protect the Data Immediately

Huly is now the execution record for the project, so its data should not exist only inside one VM.

The self-host repository includes workspace backup tooling. After creating the workspace:

```bash
cd ~/huly-selfhost
mkdir -p ~/huly-backups/operation-long-haul

./backup-create.sh \
  ~/huly-backups/operation-long-haul \
  <workspace-id-or-url>
```

Backups are incremental when reused against the same destination directory.

Until Garage / the proper DR stack exists, copy this backup directory **off the VM** to the workstation, external storage, or another machine after meaningful planning sessions.

Also preserve the Huly configuration securely:

- `huly_v7.conf` — sensitive; do not commit it.
- Any custom Nginx configuration.
- The exact Huly production version currently deployed.

A Proxmox snapshot is useful before upgrades, but it should not be the only copy of the workspace data.

---

## 6. Basic Operations

### Status

```bash
cd ~/huly-selfhost
docker compose ps
```

### Logs

```bash
docker compose logs --tail=100
```

### Restart

```bash
docker compose restart
```

### Stop / start

```bash
docker compose down
docker compose up -d
```

### Upgrade later

Before every Huly upgrade:

1. Create a workspace backup.
2. Read `MIGRATION.md` for the target release.
3. Update the self-host repository.
4. Set the desired production version in the Huly configuration / `.env` as required by the current release.
5. Pull images and recreate the stack.

Do not blindly track `latest` or `develop` for a service that contains the project record.

---

## 7. Bootstrap Exit Criteria

Huly bootstrap is complete when:

- [ ] `huly-bootstrap` VM survives a reboot.
- [ ] All expected Huly containers return after reboot.
- [ ] Huly is reachable from the workstation.
- [ ] Initial account and `Operation Long Haul` workspace exist.
- [ ] Tier 0–5 milestones are created.
- [ ] Initial Tier 0 work is represented in Huly.
- [ ] At least one Huly workspace backup has been created and copied off the VM.
- [ ] The deployed Huly version and bootstrap VM details are recorded.

At this point, **stop working on Huly and begin Tier 0**.

---

## Future Migration

Do not prematurely productionize this VM.

Once `homelab-mgmt` and the surrounding platform services are mature—ideally after the observability/identity tier is complete—create a separate migration effort:

```text
Bootstrap VM / Docker Compose
           |
           | backup + restore rehearsal
           v
homelab-mgmt / Kubernetes
           ├── Flux-managed deployment
           ├── persistent storage
           ├── Gateway API + TLS
           ├── internal DNS
           ├── observability
           ├── identity / OIDC
           └── proper backup + DR
```

Only decommission `huly-bootstrap` after a restored workspace has been validated on the final deployment.

---

## Upstream References

- Huly self-host repository: https://github.com/hcengineering/huly-selfhost
- Huly self-host documentation: https://docs.huly.io/getting-started/self-host/
- Docker Engine on Ubuntu: https://docs.docker.com/engine/install/ubuntu/

> **Maintenance note:** Huly is actively changing. Re-check the upstream self-host README and `MIGRATION.md` when you actually perform the installation rather than assuming commands in this companion document remain valid forever.
