[← Docs index](../README.md) · **Operation Long Haul v5**

[← Tier 4 · Workloads & Delivery](tier-4-workloads-delivery.md)  ·  [Ephemeral Environments →](ephemeral-environments.md)

---

# Tier 5 — MLOps *(separate document)*

The MLOps platform is **Tier 5** of Operation Long Haul, but its build detail lives in a **separate document** (kept out of this repo for now — it is large and evolving independently).

**What Tier 5 covers** (per ADR-003 and the overview): an event-driven ML pipeline platform where **Argo Workflows + Argo Events are retained *only* here** — decoupled from GitOps, which stays on Flux everywhere — plus model serving, an experiment/registry stack, and multi-tenant `mlops-*` namespaces surfaced via ExternalDNS/CoreDNS.

**Relationship to the rest of the build:**
- Several core-platform phases explicitly pre-stage for Tier 5 — e.g. ExternalDNS tenant records (Phase 2.7), the AWS secrets engine referenced around Phase 3.12 / "Tier 5.7", and Keycloak group mappings for `mlops-admins`.
- The **five personal apps** (Vaultwarden, n8n, NetBox, Forgejo, Immich) are specified in **Phase 4.7–4.11** (see [Tier 4](tier-4-workloads-delivery.md)) and are deliberately **built post-Tier-5**.
- Related **Future Upgrades** spikes (vLLM serving runtime, Papermill parameterized notebooks) live in [future-upgrades.md](future-upgrades.md).

> **TODO (build time):** when the Tier 5 doc is finalized, add it to this repo as `tier-5-mlops.md` (replacing this stub) or link it here.
