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

Pair with GPU-bearing nodes (homelab-prod node added later, or AWS burst cluster with `g5.xlarge`).

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

The list ends here intentionally. The temptation in a homelab is always to add one more thing — every new CNCF project, every emerging pattern, every "interesting" demo. v5 plus Tier 5 plus these three is already substantially more platform than five users need. Build it, run it, learn what actually hurts, then revisit this list with real evidence.

---

