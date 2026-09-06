[← Docs index](../README.md) · **Operation Long Haul v5**

[← Tier 4 · Workloads & Delivery](tier-4-workloads-delivery.md)  ·  [Ephemeral Environments →](ephemeral-environments.md)

---

# Tier 5 — MLOps *(separate document)*

The MLOps platform is **Tier 5** of Operation Long Haul, but its build detail lives in a **separate document** (kept out of this repo for now — it is large and evolving independently).

**What Tier 5 covers** (per ADR-003 and the overview): an event-driven ML pipeline platform where **Argo Workflows + Argo Events are retained *only* here** — decoupled from GitOps, which stays on Flux everywhere — plus model serving, an experiment/registry stack, and multi-tenant `mlops-*` namespaces surfaced via ExternalDNS/CoreDNS.

**GPU capacity *(v5.4 — ADR-011)*.** Tier 5 now has real GPU hardware rather than a deferred plan to rent it. `prod-gpu-01` (VM on **pve-09**, the former workstation tower) carries an **RTX 5070 (12GB)** passed through, joins homelab-prod, and is tainted `nvidia.com/gpu=true:NoSchedule` with `node.homelab.internal/pool=gpu` — so Tier 5 workloads opt in via matching `tolerations` + `nodeSelector`. Three things to design around:

- **The pool has exactly one member.** One consumer GPU passes through to one VM; there is no vGPU and no MIG. In-cluster sharing is NVIDIA device-plugin time-slicing, which gives **no memory or fault isolation** — the multi-tenant `mlops-*` namespace model applies to *scheduling*, not to GPU isolation. Do not promise tenants isolated GPU.
- **12GB is the ceiling**; the AWS `g5.xlarge` burst path stays in the plan for anything larger (see [Future Upgrades](future-upgrades.md)).
- **Bring the GPU up last.** GPU Operator's driver container on a fresh Blackwell branch, layered on RKE2 `profile: cis` with SELinux enforcing, is the friction point. Prove the CIS profile on the M920q nodes first; join `prod-gpu-01` once the rest of homelab-prod is stable. The VM itself is provisioned back in Phase 1.3 — only the `hostpci0` attachment and the cluster join belong here.

**Relationship to the rest of the build:**
- Several core-platform phases explicitly pre-stage for Tier 5 — e.g. ExternalDNS tenant records (Phase 2.7), the AWS secrets engine referenced around Phase 3.12 / "Tier 5.7", and Keycloak group mappings for `mlops-admins`.
- **Phase 1.3 provisions `prod-gpu-01`** as a VM on pve-09 without the GPU attached; Tier 0 Phase 0.1 already left the host with IOMMU enabled and the card bound to `vfio-pci`. Tier 5's first infrastructure task is therefore attachment + join + GPU Operator, not provisioning.
- The **five personal apps** (Vaultwarden, n8n, NetBox, Forgejo, Immich) are specified in **Phase 4.7–4.11** (see [Tier 4](tier-4-workloads-delivery.md)) and are deliberately **built post-Tier-5**.
- Related **Future Upgrades** spikes (vLLM serving runtime, Papermill parameterized notebooks) live in [future-upgrades.md](future-upgrades.md).

> **TODO (build time):** when the Tier 5 doc is finalized, add it to this repo as `tier-5-mlops.md` (replacing this stub) or link it here.
