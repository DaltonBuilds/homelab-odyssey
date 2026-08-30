[← Docs index](../README.md) · **Operation Long Haul v5**

[← Future Upgrades](future-upgrades.md)  ·  _(end)_

---

# Appendix — Open Items from the v5.1 Consistency Review

A full-document consistency sweep was run in August 2026. Most findings were fixed in place and tagged `*(v5.1)*` inline. The items below need **your** decision or a chunk of authoring work, so they're parked here rather than silently patched. Nothing in this list blocks starting Tier 0.

### Decisions needed

1. **Hypervisor failure domain** *(highest impact)* — pve-01 carries 2 of 3 OpenBao nodes and 2 of 3 mgmt control-plane nodes. See the ⚠ callout under "IP allocation" for the three options. Ties directly to item 2.
2. **M920x #2 role** — still flagged "confirm" in Pre-Flight and the hardware inventory. Assigning it as `pve-05` is the cleanest fix for item 1.
3. **Node-to-host mapping confirmation** — the Pre-Flight checkbox asking you to confirm exact NUC/M920q placement is still unchecked; the IP table now lists pve-03/pve-04 at `.56`/`.57` as a proposal, not a fact.

### Authoring work still outstanding

4. **`modules/talos-cluster` doesn't exist.** The ephemeral-cluster OpenTofu references it; Tier 1 only defines `modules/proxmox-vm`. Factor the Phase 1.10 `talosctl` bring-up into a reusable module before the first ephemeral drill.
5. **Flux `Receiver` + Harbor push webhook** appear only as Tier 4 gate checkboxes with no phase that builds them. Either add them to Phase 4.2 / 2.9 or strike the gate items (both are annotated inline).
6. **Kyverno seed policies conflict with the doc's own manifests.** `require-resource-requests` is violated by several inline manifests (Renovate CronJob, ntfy, the rclone DR CronJob), and `require-image-signature` will reject every third-party image proxied through Harbor — which, after the Phase 2.10 air-gap pivot, is *all* of them, not a handful. Before the Phase 4.15 audit→enforce flip: scope `imageReferences` to first-party repos (`harbor.homelab-prod.homelab.internal/apps/*`), and add resource requests to the inline manifests.
7. **VLAN 70 (ephemeral) needs switch config.** Now in the VLAN plan, but the Phase 0.2 trunk checklist still only covers 10/40/50/60, and the ephemeral OpenTofu is the only consumer.
8. **ASN 65004 for ephemeral clusters** is newly allocated in the ASN table; VyOS has no matching `neighbor-group`. Add one in Phase 0.3b (or at drill time) if ephemeral clusters need LB IPs.
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
15. **oauth2-proxy route scoping is unspecified per app.** Phase 3.14e lists the hazards (don't gate machine-callable API/webhook endpoints: Harbor's registry API, Forgejo's git-over-HTTPS) but the per-app protected-path lists are authoring work for whenever Phases 4.7–4.11 get built.
16. **No workload identity anywhere in the build.** Every machine-to-machine credential is an AppRole `secret_id`, a ServiceAccount token, or a long-lived cloud key. Tracked as the top-priority spike in [Future Upgrades](future-upgrades.md#spiffe--spire--workload-identity-highest-dual-mission-value-on-this-list); gated on the Tier 3 gate. Called out here because it is a genuine design gap, not just a nice-to-have.

---

### Fixed in the v5.1 pass (for reference)

Phase numbering (Zarf `2.10b` → `2.11`, cascading 2.11–2.16 → 2.12–2.17; app suite sub-headings 4.6–4.10 → 4.7–4.11) · `homelab.local` → `homelab.internal` / `apps.homelab.internal` throughout (`.local` is mDNS-reserved and the PKI role could never have issued certs for it) · Argo Rollouts manifest in Phase 4.5c rewritten as a Flagger `Canary` + `MetricTemplate`s · missing `csi-driver-nfs` install and `nfs-csi` StorageClass (Phase 1.7c) · missing OpenBao audit device (Phase 0.5e) · missing OpenBao Raft snapshot DR (Phases 1.11f/g) · workstation VLAN 10 → port 8200 firewall rule · `retry_join` still on `http://` after the TLS rotation · mgmt kube context standardized to `homelab-mgmt` · `mgmt-api` DNS pointed at the HA VIP `.63` instead of mgmt-01 · Grafana datasource URLs (Tempo port/service, Loki namespace, Prometheus `fullnameOverride`) · Cosign key URI `cosign-signer` → `transit/keys/cosign-harbor` · Keycloak issuer hostname · shared-secret path scoping via `secret/platform/*` · Loki multi-tenancy breaking-change warning · Kyverno exemption list (`argo-rollouts` → `flagger-system`, `falco` added) · ~25 stale "v4" references · VLAN 70 / ASN 65003+65004 / pve-03 / pve-04 / mgmt VIP added to the reference tables.
