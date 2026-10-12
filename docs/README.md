# Operation Long Haul v5 — Documentation Index

**Installing now? Start with the [seven-host Proxmox + UniFi day-one checklist](build/proxmox-day-one.md).**

This is the entry point for the build. Work through the tiers **sequentially** — each has a verification gate you must pass before advancing. The tier structure mirrors the architecture: Tier 0 is the substrate everything else stands on.

> New here? Read the [Overview](build/00-overview.md) and [ADRs](build/01-adrs.md) first, keep the [Network Reference](build/02-network-reference.md) open in a tab, then start Tier 0.

## Reference (read first / keep open)

- [Overview](build/00-overview.md) — **Purpose & Mandate (the lab's two missions — read this first)**, v3→v5.4 changelog, architecture diagram, hardware inventory, Pre-Flight decisions
- [Architecture Decision Records](build/01-adrs.md) — ADR-001 … ADR-013
- [Proxmox baseline and remote management](build/proxmox-baseline.md) — Phase 0.1 Ansible adoption, managed Tailscale and recovery checks
- [Network Reference](build/02-network-reference.md) — VLAN plan, BGP ASNs, IP allocation, LB pools

## Canonical build order

0. **Project tracking — YouTrack Cloud** — project `Homelab` (`HOMELAB`); the MCP integration is connected. See the [work breakdown](build/work-breakdown.md).
1. [Tier 0 · Foundation](build/tier-0-foundation.md) — Proxmox on all seven nodes (incl. pve-07 + GPU passthrough prep), VLANs across both switches, VyOS BGP fabric, OpenBao HA + engines
2. [Tier 1 · Platform Provisioning](build/tier-1-platform-provisioning.md) — OpenTofu/Ansible with Vault auth, storage tier, RKE2 (prod/dev) + Talos (mgmt)
3. [Tier 2 · Platform Services](build/tier-2-platform-services.md) — Cilium BGP + DNS, ESO, cert-manager, Harbor, Flux, Zarf, Kyverno, supply chain
4. [Tier 3 · Observability & Identity](build/tier-3-observability-identity.md) — metrics/logs/traces, Falco/Tetragon, Keycloak OIDC (Operator + declarative realm) + oauth2-proxy, OpenCost
5. [Tier 4 · Workloads & Delivery](build/tier-4-workloads-delivery.md) — Flagger, env promotion, ARC, k6/Chaos Mesh, Velero DR drill, app suite
6. [Tier 5 · MLOps](build/tier-5-mlops.md) — *(separate document — pointer stub here)*

## Cross-cutting

- [Ephemeral Environments](build/ephemeral-environments.md) — GitOps PR previews + disposable Talos clusters on available fleet capacity
- [Future Upgrades](build/future-upgrades.md) — deferred spikes and required upgrade gates
- [Appendix — Open Items](build/appendix-open-items.md)

## Project management

- [Work breakdown](build/work-breakdown.md) — tier/phase planning and the Tier 0 backlog

## Archive

Prior revisions live in [`/archive`](../archive/) (v3, v4). They are superseded by the v5 documents above.
