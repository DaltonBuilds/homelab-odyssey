# Operation Long Haul v5 — Documentation Index

**Installing now? Start with the [seven-host Proxmox + UniFi day-one checklist](build/proxmox-day-one.md).**

This is the entry point for the build. Work through the tiers **sequentially** — each has a verification gate you must pass before advancing. The tier structure mirrors the architecture: Tier 0 is the substrate everything else stands on.

> New here? Read the [Overview](build/00-overview.md) and [ADRs](build/01-adrs.md) first, keep the [Network Reference](build/02-network-reference.md) open in a tab, then start Tier 0.

## Reference (read first / keep open)

- [Overview](build/00-overview.md) — **Purpose & Mandate (the lab's two missions — read this first)**, v3→v5.4 changelog, architecture diagram, hardware inventory, Pre-Flight decisions
- [Architecture Decision Records](build/01-adrs.md) — ADR-001 … ADR-011
- [Network Reference](build/02-network-reference.md) — VLAN plan, BGP ASNs, IP allocation, LB pools

## Canonical build order

0. **[Bootstrap project tracking — Huly](bootstrap/huly-bootstrap.md)** *(interstitial)* — stand this up right after Proxmox + the management VLAN are live (Tier 0 Phase 0.1–0.2) and **before** OpenBao (Phase 0.4), so the rest of the build is tracked as work items. It is a deliberate manual bootstrap VM, a sibling to the hand-provisioned Vault VMs. See [Tier 0](build/tier-0-foundation.md).
1. [Tier 0 · Foundation](build/tier-0-foundation.md) — Proxmox on all seven nodes (incl. pve-09 + GPU passthrough prep), VLANs across both switches, VyOS BGP fabric, OpenBao HA + engines
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

- [Huly bootstrap guide](bootstrap/huly-bootstrap.md) — stand up the tracker
- [Huly work breakdown](../huly/work-breakdown.md) — Tier→Milestone / Phase→Epic mapping and the Tier 0 backlog

## Archive

Prior revisions live in [`/archive`](../archive/) (v3, v4). They are superseded by the v5 documents above.
