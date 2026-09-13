# Operation Long Haul — Production-Grade Homelab Foundation (v5)

**Installing now? Start with the [seven-host Proxmox + UniFi day-one checklist](docs/build/proxmox-day-one.md).**

A from-scratch, security-first homelab platform built to rehearse the practices real defense/regulated Kubernetes shops run on: immutable infrastructure, GitOps everywhere, a secrets substrate that every tool authenticates to, CIS/STIG-adjacent hardening, supply-chain attestation, air-gapped delivery, and tested disaster recovery.

This repository is the **design and build documentation** for that platform. The implementation lives in three separate repos (below). No secrets or state are kept here — see [Security & publishing](#security--publishing).

---

## Architecture at a glance

- **Hypervisors:** Proxmox VE on all **seven** physical nodes in one Proxmox cluster (`homelab-pve`; ADR-012) (no bare-metal Kubernetes — [ADR-008](docs/build/01-adrs.md)); each K8s node is an OpenTofu-provisioned VM. `pve-07` (Ryzen 9 7900X / 64GB / ZFS-mirrored NVMe / RTX 5070) is the GPU + amd64-build host, reassigned from workstation duty — [ADR-011](docs/build/01-adrs.md).
- **Clusters:** `homelab-prod` + `homelab-dev` on **RKE2** (CIS profile, encryption-at-rest, audit); `homelab-mgmt` on **Talos** (immutable, API-managed, no SSH). Quorum nodes are spread so no single hypervisor loss breaks OpenBao Raft or mgmt etcd.
- **Networking:** Cilium CNI + BGP control plane advertising LB IPs to redundant **VyOS** speakers (VRRP); Gateway API ingress.
- **Secrets:** **OpenBao** HA (Raft + GCP KMS auto-unseal) — PKI, Transit, SSH OTP, Database, KV engines; every tool (OpenTofu, Ansible, ESO, cert-manager, cosign) authenticates to it.
- **GitOps:** **Flux** on every cluster; **Flagger** for progressive delivery.
- **Supply chain:** Harbor registry, Cosign signing, Syft SBOMs, **Zarf** air-gapped bundles, Kyverno policy.
- **Observability & identity:** Prometheus/Loki/Tempo/Grafana/Alertmanager + Keycloak OIDC on the mgmt plane.
- **DR:** Velero + etcd/OpenBao off-host snapshots with Object Lock; documented, drilled restores.

The full topology diagram and rationale are in the [Overview](docs/build/00-overview.md) and [Architecture Decision Records](docs/build/01-adrs.md).

---

## How to navigate

Start at the **[docs index](docs/README.md)**, which lays out the canonical build order. In short:

| # | Document | What it covers |
|---|----------|----------------|
| — | [Overview](docs/build/00-overview.md) | Goals, changelog, topology, hardware inventory, locked-in decisions |
| — | [ADRs](docs/build/01-adrs.md) | The *why* behind every major choice (001–011) |
| — | [Network Reference](docs/build/02-network-reference.md) | VLANs, BGP ASNs, IP allocation, LB pools |
| 0 | [Tier 0 · Foundation](docs/build/tier-0-foundation.md) | Proxmox, VLANs, VyOS BGP, OpenBao HA |
| 1 | [Tier 1 · Platform Provisioning](docs/build/tier-1-platform-provisioning.md) | OpenTofu + Ansible + Vault auth, storage, RKE2/Talos |
| 2 | [Tier 2 · Platform Services](docs/build/tier-2-platform-services.md) | Cilium/DNS, ESO, cert-manager, Harbor, Flux, Zarf, Kyverno |
| 3 | [Tier 3 · Observability & Identity](docs/build/tier-3-observability-identity.md) | Prometheus/Loki/Tempo/Grafana, Falco, Keycloak, OpenCost |
| 4 | [Tier 4 · Workloads & Delivery](docs/build/tier-4-workloads-delivery.md) | Flagger, env promotion, DR drills, k6/Chaos Mesh, app suite |
| 5 | [Tier 5 · MLOps](docs/build/tier-5-mlops.md) | Pointer — detailed in a separate document |
| — | [Ephemeral Environments](docs/build/ephemeral-environments.md) | PR-preview namespaces + disposable Talos clusters |
| — | [Future Upgrades](docs/build/future-upgrades.md) | Deferred spikes (Nix, vLLM, state encryption, …) |
| — | [Appendix](docs/build/appendix-open-items.md) | Open items from the consistency review |

Project management is bootstrapped on **Huly** — see the [bootstrap guide](docs/bootstrap/huly-bootstrap.md) and the [work breakdown](huly/work-breakdown.md).

---

## Companion repositories

The build references three implementation repos (kept separate from these docs):

- `homelab-gitops` — Kubernetes manifests, Helm values, Flux config
- `homelab-ansible` — OS-level configuration for all nodes and VMs
- `homelab-terraform` — Proxmox VM provisioning (executed by OpenTofu)

---

## Status & disclaimer

This is an actively-built personal lab, not a turnkey product. **Every version pin in these docs was current at authoring time (Aug 2026) — verify the latest stable at build time.** The deliberate ceiling is OpenBao 2.6.x (a seal-plugin migration gate; see [Future Upgrades](docs/build/future-upgrades.md)).

## Security & publishing

These docs contain architecture, internal RFC1918 addressing, and hostnames — but **no secrets**: keys, passwords, and tokens all live in OpenBao / `pass`, never in Git. A hardened [`.gitignore`](.gitignore) blocks the generated-secret artifacts (state, kubeconfigs, unseal material, `huly_v7.conf`, …) from ever being committed. If you fork this, keep that discipline.

## License

[MIT](LICENSE).
