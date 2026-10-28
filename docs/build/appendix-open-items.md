[← Docs index](../README.md) · **Operation Long Haul v5**

[← Future Upgrades](future-upgrades.md)  ·  _(end)_

---

# Appendix — Open Items from the v5.1 Consistency Review

A full-document consistency sweep was run in August 2026. Most findings were fixed in place and tagged `*(v5.1)*` inline. The items below need **your** decision or a chunk of authoring work, so they're parked here rather than silently patched. Nothing in this list blocks starting Tier 0.

### Decisions needed

1. ~~**Hypervisor failure domain** *(highest impact)* — pve-01 carries 2 of 3 OpenBao nodes and 2 of 3 mgmt control-plane nodes.~~ **RESOLVED (v5.4 — [ADR-011](01-adrs.md)):** `vault-02` → pve-03 and `mgmt-02` → **pve-07**, split across two different hosts so no single hypervisor loss breaks either quorum. The ⚠ callout under "IP allocation" is now a resolved note with a post-mitigation failure table, and a single-host-loss drill was added to the Tier 1 gate. *(Note: this went one better than the callout's own Option 1, which put both nodes on pve-03 and would have just relocated the correlated failure.)*
2. ~~**M920x #2 role**~~ **RESOLVED** — assigned as `pve-03` in v5.2; it now hosts the relocated `vault-02` (v5.4).
3. **Inventory confirmed (2026-09-12, ADR-012):** one M920 SFF, two M920x, three M920q, and the Ryzen tower. The NUC entries were erroneous and removed. Record actual MAC addresses, switch ports, and wall-jack paths during installation; retain existing real-host IP assignments.

### Authoring work still outstanding

4. **`modules/talos-cluster` doesn't exist.** The ephemeral-cluster OpenTofu references it; Tier 1 only defines `modules/proxmox-vm`. Factor the Phase 1.10 `talosctl` bring-up into a reusable module before the first ephemeral drill.
5. **Flux `Receiver` + Harbor push webhook** appear only as Tier 4 gate checkboxes with no phase that builds them. Either add them to Phase 4.2 / 2.9 or strike the gate items (both are annotated inline).
6. **Kyverno seed policies conflict with the doc's own manifests.** `require-resource-requests` is violated by several inline manifests (Renovate CronJob, ntfy, the rclone DR CronJob), and `require-image-signature` will reject every third-party image proxied through Harbor — which, after the Phase 2.10 air-gap pivot, is *all* of them, not a handful. Before the Phase 4.15 audit→enforce flip: scope `imageReferences` to first-party repos (`harbor.homelab-prod.homelab.internal/apps/*`), and add resource requests to the inline manifests.
7. **VLAN 70 (ephemeral) needs switch config.** Now in the VLAN plan, but the Phase 0.2 trunk checklist still only covers 10/40/50/60, and the ephemeral OpenTofu is the only consumer.
8. **ASN 65004 for ephemeral clusters** is newly allocated in the ASN table; VyOS has no matching `peer-group` (VyOS syntax; the doc previously said `neighbor-group`). Add one through the homelab-infra `vyos_router` inventory at drill time if ephemeral clusters need LB IPs.
9. **Garage credential paths.** `secret/garage/*` predates the per-cluster ESO policy scoping. The `secret/platform/*` prefix added in Phase 2.2c is the intended home for shared credentials — migrate the Garage entries (Phase 1.7b) and add the concrete `ExternalSecret` manifests for `garage-harbor-creds` and `garage-cnpg-creds`, which are referenced but never defined.
10. **Cross-namespace TLS secrets.** Several apps reference the Gateway's wildcard TLS Secret from their own namespace, which Kubernetes doesn't allow. Guidance is inline at Phase 2.6b; the Harbor and Grafana manifests still need editing. *(v5.3: the Keycloak case is resolved — the Operator-based Phase 3.13b terminates TLS at the Gateway and no longer references the wildcard Secret.)*
11. **Static API-endpoint DNS records are used before they're created.** Phases 1.8/1.10 use `*-api.homelab.internal` names that Phase 2.1a creates. Move those static host-mappings into Tier 1 (or add them to Phase 0.3b alongside the rest of the VyOS base config).
12. **mgmt BGP contradiction.** Phase 1.10c says the mgmt cluster stays internal-only and doesn't advertise LB IPs; Phase 2.1b then gives it ASN 65003 and a BGP pool, and Phase 2.7a depends on that to expose CoreDNS at `.245`/`.246`. The 2.1b behavior is what the rest of the doc assumes — reword 1.10c.

---

## Addendum — v5.3 Identity Review (August 2026)

A challenge to the identity tier ("replace Keycloak with ZITADEL") was evaluated and rejected; see **[ADR-009](01-adrs.md)** for the decision and **[ADR-010](01-adrs.md)** for the deployment changes it triggered. Also added: an explicit [Purpose & Mandate](00-overview.md#purpose--mandate-v53) section, because the lab's second mission (long-term dojo) had never been written down and was silently biasing decisions toward the first (defense rehearsal).

**Fixed in this pass:** `bitnami/keycloak` → **Keycloak Operator** (Phase 3.13b — Bitnami's public catalog went to `bitnamilegacy` on 2025-08-28 and no longer receives security updates; this was a live problem independent of the IdP question) · realm now **declarative from first apply** (Phase 3.13c), deleting the UI-bootstrap-then-`tofu import` dance (old Phase 4.4c) · JVM heap capped, `instances: 1` · Terraform provider `mrparkers/keycloak` → `keycloak/keycloak` (the former is deprecated) · **oauth2-proxy forward-auth added** as Phase 3.14e, changing the SSO answer for Vaultwarden and n8n from "skip" to "gated" · Keycloak's cross-namespace wildcard-TLS reference removed (Appendix item 10) · Phase 4.4 rescoped from migration to ownership-boundary decision.

**New open items:**

13. **Keycloak Operator vs. official Helm chart.** Phase 3.13b uses the Operator's CRs directly. An upstream discussion (`keycloak/keycloak` #42170) tracks an official Operator-based Helm chart; if it has shipped by the time you build Tier 3, prefer it (better Flux `HelmRelease` ergonomics). **Verify at build time — do not assume either way.**
14. **Realm ownership boundary is deferred, deliberately.** Phase 4.4 now presents a CR-vs-Terraform split table rather than a decision. This is correct — it should be decided with Tier 5 tenancy evidence — but it *is* an open decision, and the failure mode if ignored is two tools thrashing over the same resources. Don't let it drift past the Tier 4 gate undecided.

---

## Addendum — v5.4 Hardware Review (September 2026)

The idle home-office workstation tower was reassigned to the fleet as `pve-07`, and the MacBook Pro became the sole workstation. See **[ADR-011](01-adrs.md)** for the decision and the accepted costs. This resolved **Appendix items 1 and 2** and closed the "GPU-bearing node added later" placeholder in the vLLM spike.

**Fixed in this pass:** hypervisor inventory 8 → 9 hosts (Overview, Pre-Flight, README, docs index) · Phase 0.1 gained a `pve-07` subsection (ZFS mirror install, `zfs_arc_max` cap, IOMMU + `vfio-pci` prep) · Phase 0.2 rewritten for the two-switch UniFi topology and the office-jack trunk · quorum layout decided and the ⚠ failure-domain callout converted to a resolved note with a failure table · `mgmt-02` → pve-07 and `vault-02` → pve-03 in the IP table, the Phase 1.3d HA-topology note, and the work breakdown · `prod-gpu-01` added to the Phase 1.3 prod node map with taint/label guidance · single-host-loss drill and quorum-spread check added to the Tier 1 gate · Tier 5 given a GPU-capacity section · NAS spike added to Future Upgrades and the spike backlog.

**New open items:**

15. **Tower hardware verification:** matching model/capacity resolved on 2026-09-13: two WD_BLACK SN850X 2000GB drives, healthy ONLINE mirror. M.2 lane sharing with the GPU populated and actual NIC link speed remain to be verified.
16. **The RKE2 CIS + Blackwell driver interaction is unproven.** GPU Operator's driver container on a new `GB205` branch, layered on `profile: cis` with SELinux enforcing, is the friction point in this plan. The mitigation written into Tier 5 is ordering — prove the CIS profile on the M920q nodes first, join `prod-gpu-01` last — but the combination itself has not been validated. Budget an evening and expect to debug it.
17. **The storage SPOF is now the largest remaining single-host blast radius.** With the quorum concentration resolved, `nfs-01` + `garage-01` unreplicated on pve-01 is what's left. Tracked as the NAS spike in [Future Upgrades](future-upgrades.md); the cheap partial fix (a Garage replica on pve-07's mirror) is an evening and does not require buying anything.
18. **Single-homed workstation is an accepted risk, not a mitigated one.** The MacBook Pro is the only holder of the `pass` GPG key, break-glass credentials, and GCP KMS access. Explicitly accepted as a buy-a-new-laptop event (see ADR-011) — recorded here so the next reader knows it was a decision rather than an oversight.
19. **Tower capacity corrected and allocation retained (2026-09-13).** The mirror is ~1.8TiB usable, not the previously estimated ~900GB. Retain 60GiB management, 200GiB build, and 250GiB GPU disks plus a ~50GiB host allowance; leave remaining capacity uncommitted. Revisit allocations after observed use and evaluate Garage replication later (ADR-011).
15. **oauth2-proxy route scoping is unspecified per app.** Phase 3.14e lists the hazards (don't gate machine-callable API/webhook endpoints: Harbor's registry API, Forgejo's git-over-HTTPS) but the per-app protected-path lists are authoring work for whenever Phases 4.7–4.11 get built.
16. **No workload identity anywhere in the build.** Every machine-to-machine credential is an AppRole `secret_id`, a ServiceAccount token, or a long-lived cloud key. Tracked as the top-priority spike in [Future Upgrades](future-upgrades.md#spiffe--spire--workload-identity-highest-dual-mission-value-on-this-list); gated on the Tier 3 gate. Called out here because it is a genuine design gap, not just a nice-to-have.

---

## Addendum — Phase 0.3 build (October 2026)

The VyOS pair went live on 2026-10-28 ([HOMELAB-17](https://daltonbuilds.youtrack.cloud/issue/HOMELAB-17)–[19](https://daltonbuilds.youtrack.cloud/issue/HOMELAB-19)); Phase 0.3 in [Tier 0](tier-0-foundation.md) now records the as-built configuration.

**New open items:**

20. **LoadBalancer reachability and VyOS peering path** *(Phase 0.3 build, 2026-10-28)*. The `*.240/28` pools sit inside connected `/24`s, so same-VLAN clients cannot reach BGP-only LB IPs. VyOS is on VLAN 40 only, so Phase 2.1c's VLAN 50/60 peers need sub-interfaces, multihop or a different peer, and LB return traffic is asymmetric through UniFi. Decide before Cilium peers: [HOMELAB-42](https://daltonbuilds.youtrack.cloud/issue/HOMELAB-42).

---

### Fixed in the v5.1 pass (for reference)

Phase numbering (Zarf `2.10b` → `2.11`, cascading 2.11–2.16 → 2.12–2.17; app suite sub-headings 4.6–4.10 → 4.7–4.11) · `homelab.local` → `homelab.internal` / `apps.homelab.internal` throughout (`.local` is mDNS-reserved and the PKI role could never have issued certs for it) · Argo Rollouts manifest in Phase 4.5c rewritten as a Flagger `Canary` + `MetricTemplate`s · missing `csi-driver-nfs` install and `nfs-csi` StorageClass (Phase 1.7c) · missing OpenBao audit device (Phase 0.5e) · missing OpenBao Raft snapshot DR (Phases 1.11f/g) · workstation VLAN 10 → port 8200 firewall rule · `retry_join` still on `http://` after the TLS rotation · mgmt kube context standardized to `homelab-mgmt` · `mgmt-api` DNS pointed at the HA VIP `.63` instead of mgmt-01 · Grafana datasource URLs (Tempo port/service, Loki namespace, Prometheus `fullnameOverride`) · Cosign key URI `cosign-signer` → `transit/keys/cosign-harbor` · Keycloak issuer hostname · shared-secret path scoping via `secret/platform/*` · Loki multi-tenancy breaking-change warning · Kyverno exemption list (`argo-rollouts` → `flagger-system`, `falco` added) · ~25 stale "v4" references · VLAN 70 / ASN 65003+65004 / pve-03 / pve-04 / mgmt VIP added to the reference tables.
