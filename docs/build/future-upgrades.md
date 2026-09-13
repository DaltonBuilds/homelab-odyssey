[← Docs index](../README.md) · **Operation Long Haul v5**

[← Ephemeral Environments](ephemeral-environments.md)  ·  [Appendix →](appendix-open-items.md)

---

# Future Upgrades


Not part of v5 scope. Documented here so they don't get lost — and so the next engineer to read this repo (you in three months, or someone you're handing the keys to) sees where the platform was heading. Each item has a clear trigger: do this when X happens.

## OpenBao 2.7+ Seal Plugin Migration *(required gate — not optional)*

**What it is:** OpenBao 2.6 deprecated the provider-specific built-in auto-unseal seals (including the `gcpckms` seal this build uses in Phase 0.6) in favor of external KMS plugins; **2.7.0 removes the built-ins entirely.**

**Trigger to revisit:** Before *any* upgrade of the Vault tier past 2.6.x. This is a hard prerequisite — upgrading first would leave the cluster unable to auto-unseal.

**Effort:** One evening. Install the gcpckms seal plugin from the openbao-plugins repo, perform a seal migration (the same `-migrate` operation rehearsed in Phase 0.5→0.6), verify the cold-restart auto-unseal test from the Tier 0 gate still passes. Rehearse on a scratch single-node instance first.

## OpenBao Namespaces *(optional exploration)*

**What it is:** Multi-tenant isolation inside one OpenBao cluster — an Enterprise-only feature in HashiCorp Vault that OpenBao ships as OSS, including per-namespace sealing (2.6).

**Why later:** Nothing in the core build needs it; single-tenant paths (`secret/`, `pki_int/`, per-cluster auth mounts) are simpler to reason about while learning.

**Trigger to revisit:** After Tier 2 is stable. Natural first experiment: move homelab-dev's secrets under a `dev/` namespace and repoint that cluster's ESO `ClusterSecretStore` at it. Gov/air-gapped shops use namespaces to carve tenancy boundaries — hands-on time here is directly resume-relevant.

## OpenTofu State Encryption

**What it is:** OpenTofu-native encryption of state (and plan) files at rest — a feature Terraform proper doesn't have. State in this build contains real secrets (Proxmox API tokens, cloud-init material read from Vault).

**Trigger to revisit:** Once Tier 1 provisioning is stable. Config is a small `encryption` block in each environment; key via PBKDF2 passphrase from `pass`, or — pleasingly recursive — an OpenBao Transit key.

**Effort:** An evening, plus a documented state-migration step per environment (`tofu` re-encrypts on next write).

## Nix Spike — Reproducible CI Toolchain on ARC *(deferred by design)*

**What it is:** Nix provides hermetic, hash-pinned environments — bit-for-bit reproducible toolchains and container images, plus a binary cache that can be mirrored offline.

**Why deferred:** mise already handles the workstation problem (per-repo pinned tool versions via committed `.mise.toml`), with a fraction of the learning curve. Nix's *marginal* value over mise shows up in CI: building the ARC runner toolchain hermetically instead of `curl | bash`-ing tools into runner images, and — the air-gap tie-in — populating a Nix binary cache in Garage so runners never fetch from the internet. That's worth a spike, not a foundation rewrite.

**Consciously skipped:** NixOS on the substrate VMs (would replace the Ubuntu+Ansible hardening surface that ADR-001 deliberately preserves as the practice/compliance rehearsal target) and nix-darwin on the workstation (personal-tooling decision, orthogonal to this build).

**Trigger to revisit:** Phase 4.6 (ARC) is live and either (a) a toolchain-drift bug bites a CI run, or (b) a quiet week invites it.

**Effort:** 1–2 evenings. A `flake.nix` in the gitops repo's tooling dir; run `nix develop` inside an ARC job for the toolchain steps (or build the runner image itself with dockerTools); mirror the closure into a Garage-backed binary cache and prove a run with upstream caches blocked. Compare ergonomics against mise-in-CI as the baseline before committing either way.

## SPIFFE / SPIRE — Workload Identity *(highest dual-mission value on this list)*

**What it is:** A platform-wide identity plane for *workloads* rather than humans. SPIRE attests what a workload actually is (node + pod + service account) and issues it a short-lived SVID — an x509 cert or JWT — with no secret to distribute, rotate, or leak. Federated trust domains let a workload in one cluster authenticate to a service in another, or to a cloud API, without a static credential anywhere.

**Why it's here, and why it's flagged.** ADR-009 rejected swapping the human IdP partly on the grounds that identity is the wrong layer to chase novelty in. That is only half an answer, and the other half belongs on this list: the genuine 2026 frontier in identity is not which SSO product you run, it's workload identity. Nothing in Tiers 0–5 addresses it — every machine-to-machine credential in this build is a Vault AppRole `secret_id`, a Kubernetes ServiceAccount token, or a long-lived cloud key.

This is the rare item that scores maximum on **both** missions (see [Purpose & Mandate](00-overview.md#purpose--mandate-v53)):
- **Mission 1:** workload identity and per-request attestation are the core of the DoD Zero Trust reference architecture. Directly job-relevant at a space defense company, and a far better conversation in a design review than "we run Keycloak."
- **Mission 2:** eliminating static machine credentials is unambiguously the right long-term posture for personal infrastructure, and it gets *better* as the platform grows.

**Why not in v5:** it wants a stable platform underneath it — SPIRE server needs HA storage, node attestation needs the node set to have stopped churning, and the payoff only shows up once there are enough services to have a credential-sprawl problem. Doing it before Tier 3 would mean debugging attestation and Cilium at the same time.

**Trigger to revisit:** after the Tier 3 gate, when the first of these is true: (a) you're about to hand a workload a long-lived cloud credential and it makes you uncomfortable; (b) the Vault AppRole `secret_id` distribution problem starts feeling like toil; (c) Tier 5 multi-tenancy needs per-tenant workload identity, not just per-tenant namespaces.

**Effort:** 2–3 evenings for a meaningful first slice. Suggested path, smallest useful step first:
1. SPIRE server on homelab-mgmt (CNPG-backed datastore), SPIRE agent as a DaemonSet on homelab-prod. Register one workload, prove it gets an SVID.
2. **The highest-value single win:** replace one long-lived AWS credential with OIDC federation — SPIRE-issued JWT SVID → AWS role assumption. No static key. This is the pattern worth internalizing, and it generalizes to GCP KMS (Phase 0.6) and any OIDC-trusting API.
3. Wire SPIRE as an OpenBao auth method (JWT/OIDC) so workload identity replaces AppRole for in-cluster consumers, and note what it does *not* replace (the substrate VMs).
4. Optional and genuinely advanced: mTLS between services via SPIFFE identities, and compare against what Cilium's transparent encryption already gives you — they overlap, and understanding *where* is the actual lesson.

**Consciously out of scope:** replacing human SSO (that's Keycloak's job — ADR-009), and a full service mesh. SPIRE without a mesh is the useful 80%.

## Re-evaluating the IdP — authentik *(conditional; do not do this speculatively)*

**What it is:** The formal revisit hook for [ADR-009](01-adrs.md), recorded so a future decision is evidence-driven rather than a rerun of the same argument from memory.

**Why it's here:** authentik was the strongest challenger to Keycloak — MIT-licensed, modern flow-builder UI, and the one real functional advantage of a **built-in forward-auth/proxy provider** plus an LDAP server for legacy apps. It lost on governance longevity (single-vendor vs. Keycloak's CNCF hosting) and non-expiring skill transfer, not on capability. ZITADEL lost more decisively and is not the fallback — if this ever flips, it flips to authentik.

**Trigger to revisit** (any one, per ADR-009): the day job moves off the defense path so CAC/SAML-IdP/Big Bang parity stop mattering; Keycloak leaves CNCF or relicenses; or oauth2-proxy toil across enough apps outgrows what a native proxy provider would cost.

**Before acting on it, verify the portability contract actually held** — that is the whole point of having written it down. Grep every integration for non-standard claim usage, confirm the realm is fully declarative, and confirm one issuer URL. If those three hold, budget a weekend. If they don't, the honest first step is fixing them, and doing that will probably remove the urgency.

## vLLM Serving Runtime for KServe

**What it is:** A KServe-native serving runtime optimized for transformer-based language models. Implements paged attention and continuous batching — radically more efficient than naive HuggingFace transformers serving. The de facto LLM serving runtime as of 2026.

**Why later:** KServe ships with serving runtimes for scikit-learn, PyTorch, TensorFlow, ONNX, and a generic HuggingFace runtime out of the box. None of those need vLLM. vLLM matters specifically when LLM workloads emerge — fine-tuning a Llama variant, serving a quantized 7B model, building a retrieval-augmented generation endpoint.

**Trigger to revisit:** The friend (or any tenant) wants to serve an LLM at production scale. Symptoms: HuggingFace runtime is too slow under realistic concurrent load, or per-request GPU memory pressure is bad.

**Effort:** 1–2 evenings. Install the vLLM `ClusterServingRuntime`, point an `InferenceService` at it. KServe handles the integration.

```yaml
# Sketch
apiVersion: serving.kserve.io/v1alpha1
kind: ClusterServingRuntime
metadata:
  name: kserve-vllmserver
spec:
  supportedModelFormats:
    - name: huggingface
      version: "1"
  containers:
    - name: kserve-container
      image: harbor.homelab-prod.homelab.internal/kserve/vllm:v0.x
      args:
        - --model
        - "{{.Name}}"
        - --tensor-parallel-size
        - "1"
```

**Where it runs *(updated v5.4)*.** The "GPU-bearing node added later" is no longer hypothetical — `prod-gpu-01` on pve-07 carries an RTX 5070 (12GB), joined to homelab-prod and tainted `nvidia.com/gpu=true:NoSchedule` (ADR-011). Two constraints shape what this spike can actually prove:

- **12GB VRAM is the ceiling.** Comfortable for quantized 7B–14B serving and `--tensor-parallel-size 1`; not enough for unquantized larger models or meaningful tensor parallelism. The **AWS `g5.xlarge` burst path is deliberately retained** for anything above 12GB — do not delete it from the plan just because local GPU exists.
- **No hardware isolation between tenants.** One consumer GPU means no vGPU and no MIG. Multi-tenant serving on this node is NVIDIA device-plugin time-slicing (`replicas: N`), which shares memory with no isolation — a single request with a large KV cache can OOM its neighbours. Fine for drills and single-tenant serving; if the friend/tenant scenario in the trigger above becomes real *concurrent* load, that is the signal for a second GPU or a `g5` burst, not more slicing.

## NAS — Relocating the Storage Tier *(conditional; the storage SPOF is the real driver)*

**What it is:** A dedicated NAS appliance or build, absorbing the bulk/cold storage tier that currently lives as VMs on pve-01.

**Why it's here.** The [Network Reference](02-network-reference.md) failure-domain note closes with the one SPOF that v5.4 did *not* fix: `nfs-01` and `garage-01` both live on pve-01 and neither is replicated. With the quorum concentration resolved (ADR-011), this is now the **largest remaining single-host blast radius** in the platform — a pve-01 loss no longer breaks either quorum, but it still takes all persistent storage with it.

**What a NAS does and does not change.** This was evaluated explicitly when choosing pve-07's pool layout, and the conclusion is worth recording so it isn't re-derived:

- **Does change:** where bulk, cold, sequential data belongs — model-weight archives, datasets, Velero restore points, Garage object storage, NFS-backed PVCs. All of that is a better fit on a NAS than on hypervisor-local NVMe.
- **Does *not* change:** anything latency-sensitive. VM boot disks, `mgmt-02`'s etcd WAL, CloudNativePG, Harbor's hot layers, and model weights being pulled into VRAM all want local NVMe (roughly 5–7GB/s and ~0.05ms, versus ~280MB/s and ~1ms over 2.5GbE). Those stay on pve-07 regardless.
- Consequently a NAS **removes** capacity pressure from pve-07's mirror rather than arguing against it. The ZFS mirror decision in ADR-011 is unaffected by acquiring a NAS — what a NAS changes is *where `nfs-01` and Garage live*, which is the actual thing to revisit.

**The capacity math makes this less optional than it first looked.** pve-07's mirror is **~900GB usable** (2× 1TB), and ADR-011's budget already commits most of it: ~50GB Proxmox, 60GB `mgmt-02`, ~200GB build VM, 250GB `prod-gpu-01`, leaving roughly 340GB shared between ZFS snapshots and the local model cache. So the two cheap mitigations below **compete with each other and with the model cache** for the same space — they are not free, and pve-07 is not a place to park a full storage tier. A NAS is what actually resolves this rather than shuffling it.

**Trigger to revisit:** a NAS is acquired, or the pve-01 storage SPOF causes a real outage. Two independent smaller steps are available before then and are worth taking on their own merits, with the caveat above: (a) a **Garage replica on pve-07's mirror**, sized deliberately (a bounded bucket subset, not a full mirror of the object tier) — it makes the most important objects survive a pve-01 loss; (b) moving `nfs-01` to pve-07, which trades one SPOF for another but lands it on mirrored disks — attractive only if the dataset is small, which is exactly what a NAS would stop constraining.

**Effort:** a scoped Garage replica is an evening. A full storage-tier relocation is 1–2 weekends including a Velero restore drill against the new target, and should not be attempted before the Tier 1 DR runbooks have been exercised once.

**If you do buy one:** the thing that matters most for this platform is not raw capacity but **link speed and redundancy** — 2.5GbE or better (both switches are managed UniFi, so the uplink is the question), and a redundant pool. Note that pve-07's own NIC speed is a Phase 0.1 verification item for the same reason.

## Papermill for Parameterized Notebooks

**What it is:** A library + CLI that lets you execute Jupyter notebooks programmatically with injected parameters. Turns notebook cells into a reusable, parameterized pipeline step.

**Why it matters for v5 + Tier 5:** The MLOps platform has two worlds — JupyterHub (exploration) and Argo Workflows (production pipelines). Papermill bridges them. A data scientist builds an exploration notebook, parameterizes the inputs (dataset version, hyperparameters), and the same notebook becomes an Argo Workflow step that runs nightly. No "rewrite the notebook as a Python script" tax.

**Trigger to revisit:** First time someone says "I want to schedule my notebook" or "I want to run this notebook with a different input every week." That's the moment Papermill earns its place.

**Effort:** ~1 hour. Install Papermill in the JupyterHub image; write one Argo Workflow template that takes a notebook URL + parameters, executes via Papermill, uploads the resulting output notebook to Garage S3.

```yaml
# Argo WorkflowTemplate sketch
apiVersion: argoproj.io/v1alpha1
kind: WorkflowTemplate
metadata:
  name: run-notebook
spec:
  templates:
    - name: papermill
      inputs:
        parameters:
          - name: notebook-url
          - name: params-json
      container:
        image: harbor.homelab-prod.homelab.internal/jupyter/papermill-runner:latest
        command: [papermill]
        args:
          - "{{inputs.parameters.notebook-url}}"
          - "/output/result.ipynb"
          - "-y"
          - "{{inputs.parameters.params-json}}"
```

The output `result.ipynb` becomes a reproducible artifact — a paper trail of "this notebook, with these parameters, produced this result."

## Backstage Developer Portal

**What it is:** Spotify's open-source internal developer portal. Catalogs services, owners, docs, dependencies; scaffolds new projects from templates; surfaces ownership and on-call from one place. The de facto answer to "where do I go to find out anything about anything we run?"

**Why it's interesting:** For a 5-person MLOps team, Backstage is borderline overkill — that's enough people to keep service ownership in their heads. But it's *exactly* the kind of platform-engineering capability that demonstrates "you understand the platform layer beyond just CI/CD." Defense industry, FAANG, any platform team — Backstage on a resume is a strong signal.

**Why not in v5:** Backstage is itself a significant build. A real Backstage deployment is ~2–3 weekends of work to set up well: deploy + Postgres backend + GitHub auth + Catalog YAML + first scaffolder template + first TechDocs page. That's a tier in itself, with no operational payoff for v5's actual users.

**Trigger to revisit:** Either (a) the platform grows past ~10 services and service discovery becomes painful, or (b) you specifically want to build it as a portfolio piece. Both are valid.

**What a v5-style Backstage tier would include:**
- Phase B.1 — Backstage on homelab-mgmt (Postgres via CNPG, OIDC via Keycloak)
- Phase B.2 — Catalog: enumerate every service in homelab-gitops with `catalog-info.yaml`
- Phase B.3 — TechDocs: every service has a `docs/` folder rendered in Backstage
- Phase B.4 — Scaffolder: at least one template for "new MLOps tenant" that wires Keycloak group + namespaces + JupyterHub access in one PR
- Phase B.5 — Plugin: Flux, Argo Workflows, Grafana, Harbor all surfaced in service pages

**Effort estimate:** 3–4 weekends end-to-end if done thoroughly.

---

The list ends here intentionally. The temptation in a homelab is always to add one more thing — every new CNCF project, every emerging pattern, every "interesting" demo. v5 plus Tier 5 plus this list is already substantially more platform than five users need. Build it, run it, learn what actually hurts, then revisit this list with real evidence.

> **Priority, if you only do one:** SPIFFE/SPIRE. It is the only item that advances both missions at once, and it addresses a real gap in the current design rather than adding a new surface. The IdP re-evaluation is the opposite — strictly conditional, and doing it speculatively would cost a weekend to arrive back where you started.

---

