[← Docs index](../README.md) · **Operation Long Haul v5**

[← Tier 3 · Observability & Identity](tier-3-observability-identity.md)  ·  [Tier 5 · MLOps →](tier-5-mlops.md)

---

# Tier 4 — Workloads & Delivery

**Purpose:** Everything built in Tiers 0–3 finally does work. Real applications deploy via real GitOps patterns. Progressive delivery with automated canary analysis. Load testing and chaos engineering exercise the platform against simulated production stress. Backups are tested with a documented disaster recovery drill. Policy enforcement moves from audit to enforce. This is the tier where v5 becomes the longstanding foundation it was designed to be.

**Why this tier exists:** A platform without workloads is just infrastructure. A workload without observability, identity, signing, policy, and progressive delivery is just a deployment. Tier 4 is where the pieces come together to demonstrate every production pattern the previous tiers enabled.

## Tier 4 Phases

- **4.1** — Flagger installation (progressive delivery)
- **4.2** — Kustomize overlays + Flux Kustomizations for env promotion
- **4.3** — *(removed; Argo Events relocated to Tier 5 MLOps — ADR-003)*
- **4.4** — Declarative Keycloak realm via Terraform
- **4.5** — Custom OTel app: end-to-end production deployment story
- **4.6** — ARC (Actions Runner Controller) for self-hosted runners
- **4.7–4.11** — *Deferred to post-Tier-5*: Vaultwarden, n8n, NetBox, Forgejo, Immich (see Tier 5 doc)
- **4.12** — k6-operator and load-testing patterns
- **4.13** — Chaos Mesh and combined chaos+load tests
- **4.14** — Velero on every cluster + DR drill
- **4.15** — Kyverno audit → enforce migration
- **4.16** — Carryover items from earlier tiers
- **4.17** — Tier 4 verification gate
- **4.18** — Closing reflections

---

### Phase 4.1: Flagger Installation (Progressive Delivery)

**Goal:** Flagger installed on homelab-prod and homelab-dev. Flagger drives canary / blue-green rollouts of ordinary Deployments, using Gateway API (Cilium) for traffic shifting and Prometheus for automated analysis — the Flux-native replacement for v4's Argo Rollouts (ADR-002).

#### 4.1a — Install via Flux HelmRelease

```yaml
# homelab-gitops/apps/flagger/release.yaml  (reconciled per workload cluster)
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata: { name: flagger, namespace: flagger-system }
spec:
  interval: 30m
  chart:
    spec:
      chart: flagger
      sourceRef: { kind: HelmRepository, name: flagger, namespace: flux-system }
      version: "1.x"
  values:
    meshProvider: gatewayapi:v1   # Cilium implements Gateway API (Phase 2.6)
    metricsServer: https://prometheus.mgmt.homelab.internal   # v5.1: canonical mgmt Prometheus hostname
```

Add the matching `HelmRepository` (`https://flagger.app`) under `flux-system`. Flagger replaces the per-cluster `argo-rollouts` install entirely — no separate dashboard or kubectl plugin to deploy.

#### 4.1b — Canary resource shape (used by the app in Phase 4.5)

A `Canary` references a normal Deployment and a Gateway API `HTTPRoute`; Flagger clones the Deployment into `-primary`/`-canary` and shifts weight based on analysis:

```yaml
apiVersion: flagger.app/v1beta1
kind: Canary
metadata: { name: hello-otel, namespace: hello }
spec:
  targetRef: { apiVersion: apps/v1, kind: Deployment, name: hello-otel }
  service:
    port: 8080
    gatewayRefs: [{ name: cilium-gw, namespace: gateway }]
  analysis:
    interval: 1m
    threshold: 5
    maxWeight: 50
    stepWeight: 10
    metrics:
      - name: request-success-rate
        thresholdRange: { min: 99 }
        interval: 1m
      - name: request-duration
        thresholdRange: { max: 500 }
        interval: 1m
```

#### Verification

- [ ] Flagger pod Running on homelab-prod and homelab-dev (`flux get hr -A` shows it Ready)
- [ ] `kubectl get canaries -A` functional (no Canaries yet — expected until Phase 4.5)
- [ ] Flagger reaches the mgmt Prometheus (check logs for metrics-server connectivity)
- [ ] No `argo-rollouts` namespace anywhere (`kubectl get ns argo-rollouts` NotFound)

---

### Phase 4.2: Kustomize Overlays + Flux Kustomizations for Env Promotion

**Goal:** A clean per-environment structure using a shared base + overlays, with one Flux `Kustomization` per cluster/env, and a documented PR-based promotion workflow — Flux's equivalent of v4's ApplicationSets (ADR-002).

#### 4.2a — Repo structure

```
homelab-gitops/
├── clusters/
│   ├── homelab-prod/                        # prod cluster
│   │   ├── flux-system/                   # bootstrap
│   │   ├── apps.yaml                      # Flux Kustomization -> apps/<app>/overlays/prod
│   │   ├── flagger/
│   │   ├── harbor/
│   │   └── platform-services/
│   ├── homelab-dev/                             # dev/staging cluster
│   │   ├── flux-system/
│   │   ├── apps-dev.yaml                  # -> overlays/dev
│   │   ├── apps-staging.yaml              # -> overlays/staging
│   │   └── platform-services/
│   └── homelab-mgmt/                        # Talos mgmt cluster (Flux-managed)
│       └── observability/
└── apps/                                  # per-app source manifests with overlays
    ├── hello-otel/
    │   ├── base/
    │   │   ├── kustomization.yaml
    │   │   ├── deployment.yaml
    │   │   ├── canary.yaml               # Flagger Canary (was rollout.yaml)
    │   │   ├── service.yaml
    │   │   ├── httproute.yaml
    │   │   ├── postgres-cluster.yaml
    │   │   └── external-secret.yaml
    │   └── overlays/{dev,staging,prod}/
    ├── vaultwarden/
    ├── n8n/
    ├── netbox/
    ├── forgejo/
    └── immich/
```

#### 4.2b — The per-cluster Flux Kustomization

Instead of an ApplicationSet generating Applications, each cluster has a Flux `Kustomization` per environment it hosts:

```yaml
# homelab-gitops/clusters/homelab-dev/apps-dev.yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata: { name: hello-otel-dev, namespace: flux-system }
spec:
  interval: 5m
  path: ./apps/hello-otel/overlays/dev
  prune: true
  sourceRef: { kind: GitRepository, name: flux-system }
  targetNamespace: hello-dev
```

homelab-dev hosts `dev` and `staging`; homelab-prod hosts `prod`. Image bumps are written by Flux's image-automation controller (`ImagePolicy` + `ImageUpdateAutomation`) against the overlay kustomization, covering what ApplicationSets + Renovate did for image tags.

#### 4.2c — Promotion workflow

The image tag in `apps/hello-otel/overlays/<env>/kustomization.yaml` defines what's deployed:

```yaml
# apps/hello-otel/overlays/dev/kustomization.yaml
resources: [../../base]
images:
  - name: hello-otel
    newName: harbor.homelab-prod.homelab.internal/apps/hello-otel
    newTag: "v1.4.2-rc.7"   # Flux image-automation (or Renovate) updates this
namespace: hello-dev
```

**Promotion = a PR moving a tag through the overlays:**

1. CI builds + signs image → pushes to Harbor with a semver tag
2. Flux image-automation commits a bump to `overlays/dev/kustomization.yaml`
3. Merge → Flux reconciles homelab-dev/hello-dev automatically (5m, or webhook)
4. Manual promotion: human PR bumps `overlays/staging/kustomization.yaml` to the same tag
5. Merge → `flux reconcile kustomization hello-otel-staging` to force-sync (or wait for interval)
6. After staging validation: PR for `overlays/prod/` → prod reconcile, with Flagger driving the canary

> **What about Kargo?** Kargo automates step 4 onward but is still maturing and would reintroduce the Argo dependency we just removed. PR-based promotion is simpler, leaves a clear Git audit trail, and is how most shops promote without a dedicated tool — chosen for transparency and tooling minimalism.

#### Verification (after Phase 4.5 deploys the actual app)

- [ ] Three Flux Kustomizations exist: `hello-otel-dev`, `hello-otel-staging` (homelab-dev), `hello-otel-prod` (homelab-prod)
- [ ] Dev reconciles automatically on commit; staging/prod gated behind PRs + explicit reconcile
- [ ] Promoting a tag dev → staging → prod via PRs works end-to-end
- [ ] Prod promotion triggers a Flagger canary, not a hard cutover

---

### Phase 4.3: ~~Argo Events~~ → Relocated to Tier 5 (MLOps) *(v5)*

**This phase is intentionally removed from the core platform.** In v4, Argo Events provided general platform glue (Git webhook → sync, Harbor push → scan). Per ADR-002/ADR-003, GitOps reconciliation is now Flux's job — Flux's own webhook `Receiver` handles "push → reconcile" with sub-second latency, so the platform no longer needs Argo Events for that.

**Argo Events (with Argo Workflows) is retained only in Tier 5 MLOps**, where it's genuinely decoupled from GitOps and serves a specific use case: event-driven ML pipelines ("model registered in MLflow → training/promotion pipeline runs"). See the Tier 5 doc for the EventBus / EventSource / Sensor setup in that context.

What replaces the v4 platform uses of Argo Events:

- **Git push → reconcile:** Flux `Receiver` (notification-controller webhook), not EventSource → Sensor → ArgoCD sync.
- **Harbor image push → scan:** Harbor's native webhook → a small Flux-managed job (Kyverno already verifies signatures at admission, Phase 2.16).
- **Scheduled jobs:** plain `CronJob` where no event source is needed.

---

### Phase 4.4: Declarative Keycloak Realm via Terraform

**Goal:** What was bootstrapped manually in Tier 3 Phase 3.13c becomes code. Future realm changes go through PR.

#### 4.4a — Terraform setup

New environment in `homelab-terraform/environments/keycloak/`:

```hcl
terraform {
  required_providers {
    keycloak = {
      source  = "mrparkers/keycloak"
      version = "~> 4.4"
    }
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.4"
    }
  }
}

# Auth Vault first (same AppRole pattern as Tier 1)
provider "vault" {
  address = "https://vault.homelab.internal:8200"
  auth_login {
    path = "auth/approle/login"
    parameters = {
      role_id   = var.vault_role_id
      secret_id = var.vault_secret_id
    }
  }
}

# Read Keycloak admin from Vault
data "vault_kv_secret_v2" "keycloak_admin" {
  mount = "secret"
  name  = "mgmt/keycloak/admin"
}

provider "keycloak" {
  client_id     = "admin-cli"
  username      = data.vault_kv_secret_v2.keycloak_admin.data["user"]
  password      = data.vault_kv_secret_v2.keycloak_admin.data["password"]
  url           = "https://keycloak.mgmt.homelab.internal"
  initial_login = false
}
```

#### 4.4b — Realm, groups, clients as code

```hcl
resource "keycloak_realm" "homelab" {
  realm        = "homelab"
  enabled      = true
  display_name = "Homelab"

  password_policy = "upperCase(1) and length(12) and notUsername"

  registration_allowed         = false
  reset_password_allowed       = true
  remember_me                  = true
  verify_email                 = false
  login_with_email_allowed     = true

  access_token_lifespan         = "30m"
  sso_session_idle_timeout      = "8h"
  sso_session_max_lifespan      = "24h"
  offline_session_idle_timeout  = "30d"
}

resource "keycloak_group" "admin" {
  realm_id = keycloak_realm.homelab.id
  name     = "homelab-admin"
}

resource "keycloak_group" "reader" {
  realm_id = keycloak_realm.homelab.id
  name     = "homelab-reader"
}

# Clients — declarative versions of what we built in the UI
resource "keycloak_openid_client" "flux_ui" {
  realm_id              = keycloak_realm.homelab.id
  client_id             = "flux-ui"
  name                  = "Flux UI"
  access_type           = "CONFIDENTIAL"
  standard_flow_enabled = true
  valid_redirect_uris   = ["https://flux.homelab.internal/oauth2/callback"]
}

# Repeat for grafana, harbor, vault, and any future client
# ... (omitted for brevity)

# Group claim mapper — sends "groups" in tokens so apps can role-map
resource "keycloak_generic_client_protocol_mapper" "groups" {
  for_each = toset([
    keycloak_openid_client.flux_ui.id,
    # ... other clients
  ])
  realm_id        = keycloak_realm.homelab.id
  client_id       = each.value
  name            = "groups"
  protocol        = "openid-connect"
  protocol_mapper = "oidc-group-membership-mapper"
  config = {
    "claim.name"           = "groups"
    "full.path"            = "false"
    "id.token.claim"       = "true"
    "access.token.claim"   = "true"
    "userinfo.token.claim" = "true"
  }
}
```

#### 4.4c — Import existing state

Critical step — we manually created clients in Tier 3. Terraform must import them rather than recreate:

```bash
source ../../scripts/vault-login.sh
tofu init
tofu import keycloak_realm.homelab homelab
tofu import keycloak_openid_client.flux_ui homelab/<client-uuid-from-keycloak-ui>
tofu import keycloak_openid_client.grafana homelab/<client-uuid>
# ... etc

tofu plan   # should show no changes after all imports
```

#### Verification

- [ ] `tofu plan` shows no drift after import
- [ ] Make a trivial change (e.g., update a redirect URI), `tofu apply`, verify in Keycloak UI
- [ ] OIDC logins to all 4 apps still work after the apply

---

### Phase 4.5: Custom OTel App — End-to-End Production Story

**Goal:** A simple HTTP service you wrote yourself that exercises *the entire stack* — Harbor (signed images), CloudNativePG (database), Vault (dynamic credentials), cert-manager (TLS), Cilium Gateway (ingress), Tempo (traces), Prometheus (metrics), Loki (logs), Flagger (canary), Sloth (SLOs), Kyverno (policy verification). This is the demo.

#### 4.5a — The app itself

Pick a domain. Suggestions:
- **URL shortener** — simple, demonstrates everything, useful
- **Feature flag service** — slightly more interesting, exercises read-heavy patterns
- **Tiny webhook receiver** — sit between Renovate/GitHub and other systems

Whichever you pick:
- **Language:** Go (smallest image, instrumentation is easy with `otelhttp`)
- **Endpoints:** `GET /healthz`, `GET /readyz`, `GET /metrics` (Prometheus format), `POST /` and `GET /:id` (or whatever the domain needs)
- **Storage:** Postgres via CloudNativePG-issued credentials
- **Observability:** OTel SDK initialized at startup, traces to `tempo-otlp.mgmt.homelab.internal:4318`, metrics scraped by Alloy ServiceMonitor

Skeleton structure:

```
hello-otel/
├── cmd/server/main.go              # entrypoint
├── internal/
│   ├── api/                         # HTTP handlers
│   ├── db/                          # Postgres queries
│   └── observability/               # OTel init
├── Dockerfile                       # multi-stage, distroless final
├── .github/workflows/
│   └── release.yaml                 # CI: build → sign → push to Harbor
└── README.md
```

#### 4.5b — CI pipeline (GitHub Actions, runs on self-hosted runners in Phase 4.6)

> **Ordering note (v5.1):** this pipeline needs the ARC runners *and* the `ci-signer` AppRole from Phase 4.6. Either build 4.6 first and treat 4.5b as its first real workload, or run 4.5b manually from your workstation once, then re-run it on ARC after 4.6. The Phase 4.5 gate item "CI pipeline produces signed, attested images" is only checkable after 4.6 either way.

```yaml
# .github/workflows/release.yaml
name: build-and-release
on:
  push:
    tags: ['v*']
jobs:
  release:
    runs-on: [self-hosted, homelab]
    permissions: { id-token: write, contents: read }
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-buildx-action@v3
      - name: Login to Harbor
        uses: docker/login-action@v3
        with:
          registry: harbor.homelab-prod.homelab.internal
          username: ${{ secrets.HARBOR_ROBOT_USER }}
          password: ${{ secrets.HARBOR_ROBOT_TOKEN }}
      - name: Build
        run: |
          docker build -t harbor.homelab-prod.homelab.internal/apps/hello-otel:${{ github.ref_name }} .
          docker push  harbor.homelab-prod.homelab.internal/apps/hello-otel:${{ github.ref_name }}
      - name: Sign with Cosign + Vault Transit
        env:
          VAULT_ADDR: https://vault.homelab.internal:8200
        run: |
          # Runner has VAULT_TOKEN env set via the harness; AppRole auth done before this step
          cosign sign --key hashivault://transit/keys/cosign-harbor \
            harbor.homelab-prod.homelab.internal/apps/hello-otel:${{ github.ref_name }}
      - name: Generate SBOM
        run: |
          syft harbor.homelab-prod.homelab.internal/apps/hello-otel:${{ github.ref_name }} \
            -o cyclonedx-json > sbom.json
          cosign attest --predicate sbom.json --type cyclonedx --key hashivault://transit/keys/cosign-harbor \
            harbor.homelab-prod.homelab.internal/apps/hello-otel:${{ github.ref_name }}
```

> **What this pipeline demonstrates:** Build → sign with key never on the runner → generate SBOM → attest SBOM. Every defense-industry supply-chain checkbox. The SBOM lives alongside the image as an attestation; the Kyverno policy that verifies it is written in Phase 2.16 and flipped to enforce in Phase 4.15.

#### 4.5c — Kubernetes manifests (`apps/hello-otel/base/`)

The Deployment (Flagger promotes it; it is an ordinary Deployment, not a Rollout) — *(v5.1: this section still carried an Argo Rollouts manifest, which ADR-002 removed. Rewritten for Flagger.)*

```yaml
apiVersion: apps/v1
kind: Deployment
metadata: { name: hello-otel }
spec:
  replicas: 3
  selector: { matchLabels: { app: hello-otel } }
  template:
    metadata: { labels: { app: hello-otel } }
    spec:
      serviceAccountName: hello-otel
      containers:
        - name: app
          image: hello-otel:placeholder   # replaced by kustomize overlay
          ports: [{ containerPort: 8080, name: http }]
          env:
            - name: OTEL_EXPORTER_OTLP_ENDPOINT
              value: "https://tempo-otlp.mgmt.homelab.internal:4318"
            - name: PG_HOST
              value: hello-otel-postgres-rw.${NAMESPACE}.svc
            - name: PG_USER
              valueFrom: { secretKeyRef: { name: hello-otel-postgres-app, key: username } }
            - name: PG_PASSWORD
              valueFrom: { secretKeyRef: { name: hello-otel-postgres-app, key: password } }
          resources:
            requests: { cpu: 50m, memory: 128Mi }
            limits:   { memory: 256Mi }
          securityContext:
            runAsNonRoot: true
            runAsUser: 65532
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: [ALL] }
```

The Flagger `Canary` that drives progressive rollout (shape established in Phase 4.1b). Flagger owns the HTTPRoute and the primary/canary Services — do **not** hand-manage them:

```yaml
apiVersion: flagger.app/v1beta1
kind: Canary
metadata: { name: hello-otel }
spec:
  provider: gatewayapi:v1
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: hello-otel
  progressDeadlineSeconds: 600
  service:
    port: 80
    targetPort: 8080
    gatewayRefs:
      - name: homelab-gateway
        namespace: gateway-system
    hosts:
      - hello.homelab-prod.homelab.internal
  analysis:
    interval: 30s
    threshold: 2            # halt+rollback after 2 failed checks
    maxWeight: 50
    stepWeight: 10          # 10 → 20 → 30 → 40 → 50, then promote
    metrics:
      - name: success-rate
        templateRef: { name: hello-otel-success-rate }
        thresholdRange: { min: 99 }
        interval: 1m
      - name: p99-latency
        templateRef: { name: hello-otel-p99 }
        thresholdRange: { max: 500 }    # milliseconds
        interval: 1m
    webhooks:
      - name: load-test
        type: rollout
        url: http://flagger-loadtester.flagger-system/
        metadata:
          cmd: "hey -z 1m -q 10 -c 2 https://hello.homelab-prod.homelab.internal/"
```

The `MetricTemplate`s the Canary references (Flagger's equivalent of the old AnalysisTemplate):

```yaml
apiVersion: flagger.app/v1beta1
kind: MetricTemplate
metadata: { name: hello-otel-success-rate }
spec:
  provider:
    type: prometheus
    address: http://kps-prometheus.observability.svc:9090
  query: |
    100 - 100 * (
      sum(rate(http_requests_total{
        namespace="{{ namespace }}",
        service="{{ target }}",
        code=~"5.."
      }[{{ interval }}]))
      /
      sum(rate(http_requests_total{
        namespace="{{ namespace }}",
        service="{{ target }}"
      }[{{ interval }}]))
    )
---
apiVersion: flagger.app/v1beta1
kind: MetricTemplate
metadata: { name: hello-otel-p99 }
spec:
  provider:
    type: prometheus
    address: http://kps-prometheus.observability.svc:9090
  query: |
    histogram_quantile(0.99,
      sum(rate(http_request_duration_seconds_bucket{
        namespace="{{ namespace }}",
        service="{{ target }}"
      }[{{ interval }}])) by (le)
    ) * 1000
```

> **Prometheus reachability:** the workload clusters' Flagger queries the mgmt-plane Prometheus. Use the in-cluster service address only if Flagger runs on mgmt; from homelab-prod/dev, point `address` at `https://prometheus.mgmt.homelab.internal` (the Gateway-exposed endpoint) instead — and keep it identical to the `metricsServer` value set in Phase 4.1a.

#### 4.5d — Per-app SLO

```yaml
apiVersion: sloth.slok.dev/v1
kind: PrometheusServiceLevel
metadata: { name: hello-otel-slo, namespace: hello-prod }
spec:
  service: "hello-otel"
  labels: { tier: "application" }
  slos:
    - name: "availability"
      objective: 99.5
      sli:
        events:
          error_query: 'sum(rate(http_requests_total{service="hello-otel",namespace="hello-prod",code=~"5.."}[5m]))'
          total_query: 'sum(rate(http_requests_total{service="hello-otel",namespace="hello-prod"}[5m]))'
      alerting:
        name: HelloOtelAvailabilityBurn
        page_alert: { labels: { severity: critical } }
```

#### Verification

- [ ] CI pipeline produces signed, attested images in Harbor
- [ ] Image pull from homelab-dev succeeds (Kyverno in audit mode logs the signature verification, sees it passes)
- [ ] App reachable at `https://hello.homelab-dev.homelab.internal` (dev)
- [ ] Traces visible in Tempo (Grafana Explore → Tempo data source → search by service `hello-otel`)
- [ ] Metrics visible in Prometheus, Alloy is scraping the ServiceMonitor
- [ ] Logs visible in Loki, filtered to `{cluster="homelab-dev",namespace="hello-dev"}`
- [ ] Trigger a deploy: push a new tag, watch the Flagger `Canary` walk through its step weights, see analysis succeed
- [ ] Trigger an *unhealthy* deploy (introduce a deliberate 500 error): canary aborts, traffic stays on stable, Discord alert fires

---

### Phase 4.6: ARC (Actions Runner Controller)

**Goal:** Self-hosted GitHub runners on homelab-dev, scaled on demand, pulling images from Harbor.

> **Why homelab-dev not homelab-prod:** CI is a dev-tier concern. Don't burn prod resources on builds. Runners run on homelab-dev; the artifacts they push land in Harbor on homelab-prod.

#### 4.6a — ARC install

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata: { name: arc-controller, namespace: arc-systems }   # on homelab-dev via Flux
spec:
  interval: 30m
  install: { createNamespace: true }
  chart:
    spec:
      chart: gha-runner-scale-set-controller
      sourceRef: { kind: HelmRepository, name: arc, namespace: flux-system }
      version: "0.x"
```

#### 4.6b — Runner scale set per repo

```yaml
apiVersion: actions.github.com/v1alpha1
kind: AutoscalingRunnerSet
metadata: { name: homelab-runners, namespace: arc-runners }
spec:
  githubConfigUrl: https://github.com/yourorg/homelab-gitops
  githubConfigSecret: arc-github-creds   # ESO from Vault (GitHub App credentials)
  maxRunners: 4
  minRunners: 1
  containerMode: { type: dind }
  template:
    spec:
      containers:
        - name: runner
          image: harbor.homelab-prod.homelab.internal/dockerhub/actions/runner:latest
          env:
            - name: VAULT_ADDR
              value: https://vault.homelab.internal:8200
          # AppRole credentials for Vault-Cosign signing — short-lived
          envFrom:
            - secretRef: { name: runner-vault-approle }
```

The `runner-vault-approle` secret carries an AppRole bound to a `ci-signer` Vault policy:

```hcl
# Vault policy: ci-signer
path "transit/sign/cosign-harbor"   { capabilities = ["create", "update"] }
path "transit/verify/cosign-harbor" { capabilities = ["create", "update"] }
```

> **AppRole TTL = 4h**, force re-issue from Vault for long-running CI. If runners get compromised, the blast window is bounded.

#### Verification

- [ ] Runner pods appear in `arc-runners` namespace on homelab-dev when a workflow needs them
- [ ] Pushing a tag to `hello-otel` triggers the release workflow on a self-hosted runner
- [ ] Signed image lands in Harbor, signature verifiable

---

### Phases 4.7–4.11: The Application Suite *(specification only — build post-Tier-5)*

> **Status (v5.1):** these five are **deferred to post-Tier-5** (see the Tier 4 phase list and the Tier 4 gate — they do not block Tier 4 completion). What follows is the spec so the decisions are captured while fresh; it is not a build instruction for this pass. One dependency to watch: the ephemeral air-gap drill assumes a local **Forgejo** mirror, so either pull Forgejo forward out of this deferred set or use a throwaway in-package git server for the drill until it exists.

Each follows the same pattern: Helm chart (proxied through Harbor) → values file in `apps/<name>/base/` → Kustomize overlay for prod (and dev if applicable) → Postgres via CloudNativePG where needed → ESO for any secrets → HTTPRoute via Cilium Gateway → OIDC client in Keycloak.

I'll keep these phases tight — the pattern is established.

#### 4.7 — Vaultwarden (prod-only on homelab-prod)

- Single replica, Postgres via CNPG
- Hostname: `vault-pwd.homelab-prod.homelab.internal` (avoid `vault.` conflict with the OpenBao cluster's DNS name)
- Admin token in Vault KV, materialized via ESO
- OIDC integration optional (Vaultwarden has limited SSO support; not worth wiring)
- Daily Velero backup; restore drill documented

#### 4.8 — n8n (prod-only on homelab-prod)

- Helm chart from the [n8n community charts](https://github.com/8gears/n8n-helm-chart)
- Postgres via CNPG, persistent storage for workflow data
- OIDC via Keycloak (enterprise feature; on community version use header auth + a placeholder)
- Useful early workflow: monitor Renovate PRs, auto-approve patches that pass Kyverno verification

#### 4.9 — NetBox (prod-only on homelab-prod)

- Postgres via CNPG + Redis (CNPG doesn't do Redis — use Bitnami Redis chart)
- OIDC via Keycloak (NetBox natively supports it through python-social-auth)
- **Seed the inventory:** import all VLANs, subnets, racks (just the one), and devices (everything in your IP allocation table from Tier 0). NetBox becomes source of truth for IPAM going forward.
- Bonus: configure Ansible to use NetBox as a dynamic inventory source — closes the loop on "NetBox documents real infrastructure"

#### 4.10 — Forgejo (prod-only on homelab-prod)

- Postgres via CNPG, NFS for repo storage
- OIDC via Keycloak
- Configure **GitHub mirroring** for the three homelab repos (`homelab-gitops`, `homelab-ansible`, `homelab-terraform`)
- Now you have offline-resilient copies of every repo your platform depends on. The defense-grade air-gap pattern: if GitHub disappears tomorrow, the homelab keeps running.

> **Pull-through mirror is one-way (GitHub → Forgejo)**, not a fork. Flux continues pulling from GitHub. Forgejo is a read-only failsafe. If GitHub goes down, you re-point Flux to Forgejo as the source. Add this as a runbook.

#### 4.11 — Immich (prod-only on homelab-prod; the storage stress test)

- Heavy: Postgres + Redis + ML processing
- NFS-mounted storage for the photo library (could be huge — set a realistic ZFS quota)
- OIDC via Keycloak
- Mobile apps point at `https://photos.homelab-prod.homelab.internal`
- **Why this is in v5:** Real workload that exercises NFS storage at scale, CPU-heavy ML processing, large object handling. Best chaos engineering target you'll have.

---

### Phase 4.12: k6-operator and Load-Testing Patterns

**Goal:** Distributed load tests defined as Kubernetes resources, results streamed to Prometheus, dashboards in Grafana. Run regular load tests against the hello-otel app and other workloads.

#### 4.12a — Install on homelab-dev only

Load testing belongs in the dev/staging tier. Don't load-test prod from inside prod.

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata: { name: k6-operator, namespace: k6-operator-system }   # on homelab-dev via Flux
spec:
  interval: 30m
  install: { createNamespace: true }
  chart:
    spec:
      chart: k6-operator
      sourceRef: { kind: HelmRepository, name: grafana, namespace: flux-system }
      version: "3.x"
```

#### 4.12b — Test script lives in gitops repo

```javascript
// apps/hello-otel/load-tests/baseline.js
import http from 'k6/http';
import { check, sleep } from 'k6';

export const options = {
  scenarios: {
    ramp_up: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '2m', target: 100 },   // ramp to 100 VUs
        { duration: '5m', target: 100 },   // hold
        { duration: '2m', target: 0 },     // ramp down
      ],
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.01'],          // < 1% errors
    http_req_duration: ['p(95)<500'],        // 95th percentile < 500ms
  },
};

export default function () {
  const target = __ENV.TARGET || 'https://hello.homelab-dev.homelab.internal';
  const r = http.post(`${target}/`, JSON.stringify({ url: 'https://example.com/long-url' }), {
    headers: { 'Content-Type': 'application/json' },
  });
  check(r, { 'status is 201': (r) => r.status === 201 });
  sleep(1);
}
```

#### 4.12c — TestRun CRD

```yaml
apiVersion: k6.io/v1alpha1
kind: TestRun
metadata: { name: hello-otel-baseline, namespace: k6-tests }
spec:
  parallelism: 4   # distributed across 4 pods
  script:
    configMap: { name: hello-otel-baseline-script, file: baseline.js }
  arguments: --out experimental-prometheus-rw
  runner:
    env:
      - name: K6_PROMETHEUS_RW_SERVER_URL
        value: https://prometheus.mgmt.homelab.internal/api/v1/write
      - name: K6_PROMETHEUS_RW_TREND_STATS
        value: "p(95),p(99),min,max"
      - name: TARGET
        value: "https://hello.homelab-dev.homelab.internal"
```

After the run completes, metrics (`k6_http_req_duration`, `k6_http_reqs`) are queryable in Grafana. Pre-import the [k6 Grafana dashboard](https://grafana.com/grafana/dashboards/19665) for visualization.

#### Verification

- [ ] Baseline test runs successfully, metrics appear in Prometheus
- [ ] k6 dashboard in Grafana populates
- [ ] During load test, application Tempo traces show increased volume, hello-otel SLO recording rules update

---

### Phase 4.13: Chaos Mesh + Combined Chaos+Load Tests

**Goal:** Chaos experiments run on homelab-dev (never on homelab-prod). Combined with k6 load tests to simulate "load + something goes wrong simultaneously" — the most realistic production stress.

#### 4.13a — Install on homelab-dev only

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata: { name: chaos-mesh, namespace: chaos-mesh }   # on homelab-dev via Flux
spec:
  interval: 30m
  install: { createNamespace: true }
  chart:
    spec:
      chart: chaos-mesh
      sourceRef: { kind: HelmRepository, name: chaos-mesh, namespace: flux-system }
      version: "2.x"
  values:
        dashboard:
          create: true
          securityMode: false   # for homelab; production should use authenticated dashboard
```

#### 4.13b — Three starter experiments

**PodChaos — random pod kill:**

```yaml
apiVersion: chaos-mesh.org/v1alpha1
kind: PodChaos
metadata: { name: hello-otel-pod-kill, namespace: chaos-mesh }
spec:
  action: pod-kill
  mode: one
  selector:
    namespaces: [hello-dev]
    labelSelectors: { app: hello-otel }
  scheduler:
    cron: "@every 5m"     # one pod dies every 5 minutes
```

**NetworkChaos — induce latency:**

```yaml
apiVersion: chaos-mesh.org/v1alpha1
kind: NetworkChaos
metadata: { name: hello-otel-latency, namespace: chaos-mesh }
spec:
  action: delay
  mode: all
  selector:
    namespaces: [hello-dev]
    labelSelectors: { app: hello-otel }
  delay: { latency: "100ms", jitter: "50ms" }
  duration: "5m"
```

**IOChaos — disk latency (Immich is a great target):**

```yaml
apiVersion: chaos-mesh.org/v1alpha1
kind: IOChaos
metadata: { name: immich-disk-slow, namespace: chaos-mesh }
spec:
  action: latency
  mode: one
  selector:
    namespaces: [immich-dev]   # if you stand one up in homelab-dev
    labelSelectors: { app: immich }
  volumePath: /usr/src/app/upload
  path: "**"
  delay: "200ms"
  duration: "10m"
```

#### 4.13c — Combined test ritual

The "production stress simulation" — schedule a k6 TestRun and a Chaos experiment to overlap:

1. Start k6 ramp-up (2 min)
2. At t+3min (during hold phase), trigger PodChaos pod-kill experiment
3. Observe: does the canary stability hold? Do circuit breakers engage? Does the SLO burn-rate alert fire?
4. After test: compare baseline metrics vs chaos metrics, document findings

> **The defense-industry framing:** Real workloads don't fail in isolation. They fail under load. Combining k6 + Chaos Mesh is how you get realistic resilience data without paying for fault-injection-as-a-service. ADR-worthy: "We treat resilience as a measurable property, exercised quarterly."

#### Verification

- [ ] Chaos Mesh dashboard reachable
- [ ] All three experiments can be triggered manually
- [ ] Combined chaos+load test demonstrates: pod kills don't break the canary, latency injection shows up in Tempo traces, SLO burn-rate alert fires when load + chaos exceed acceptable bounds

---

### Phase 4.14: Velero + Documented DR Drill

**Goal:** Velero on every cluster, scheduled daily backups to Garage S3, AND a documented + executed DR drill that proves the backups actually work.

> **Backups are theater until they're restored.** This phase is the only one where you intentionally destroy something to prove you can rebuild it.

#### 4.14a — Velero install per cluster

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata: { name: velero, namespace: velero }   # reconciled per cluster by Flux
spec:
  interval: 30m
  install: { createNamespace: true }
  chart:
    spec:
      chart: velero
      sourceRef: { kind: HelmRepository, name: vmware-tanzu, namespace: flux-system }
      version: "7.x"
  values:
        configuration:
          backupStorageLocation:
            - name: garage
              provider: aws
              bucket: velero-backups-homelab-prod   # rename per cluster
              config:
                region: garage
                s3ForcePathStyle: "true"
                s3Url: http://garage-01.homelab.internal:3900
          volumeSnapshotLocation:
            - name: garage
              provider: aws
        credentials:
          existingSecret: velero-garage-creds   # ESO from Vault
        initContainers:
          - name: velero-plugin-for-aws
            image: harbor.homelab-prod.homelab.internal/dockerhub/velero/velero-plugin-for-aws:v1.10.x
            volumeMounts: [{ name: plugins, mountPath: /target }]
```

#### 4.14b — Schedule daily backups

```yaml
apiVersion: velero.io/v1
kind: Schedule
metadata: { name: daily-full, namespace: velero }
spec:
  schedule: "0 3 * * *"     # 3am
  template:
    storageLocation: garage
    ttl: "720h"             # 30 days
    includeClusterResources: true
    snapshotVolumes: true
```

#### 4.14c — The DR drill (run quarterly)

Document in `homelab-gitops/docs/runbooks/dr-drill.md`:

```markdown
# Quarterly DR Drill

**Last completed:** [date]
**Next due:** [date + 90 days]

## Procedure

1. Pick a non-critical namespace on homelab-dev (e.g., `hello-dev`)
2. Take a fresh backup: `velero backup create dr-drill-$(date +%Y%m%d) --include-namespaces hello-dev`
3. Wait for completion: `velero backup describe dr-drill-...`
4. **Destroy:** `kubectl --context homelab-dev delete namespace hello-dev`
5. Confirm complete deletion (Postgres CR gone, PVCs gone, all resources gone)
6. Start a timer. Restore: `velero restore create --from-backup dr-drill-...`
7. Wait for restore completion
8. Verify hello-dev fully functional (app reachable, Postgres data intact via test query, traces resume)
9. **Stop the timer.** That's your RTO.
10. Compare last successful health check time vs the data state in restored Postgres. The gap is your RPO.

## Last drill results

| Date       | RTO    | RPO    | Notes                                          |
| ---------- | ------ | ------ | ---------------------------------------------- |
| 2026-MM-DD | 14 min | 22h    | Backup was from 3am; drill ran at 1pm           |
| ...        |        |        |                                                |

## Improvement actions from last drill

- ...
```

> **What "RTO 14 min, RPO 22h" tells you:** Recovery takes 14 minutes once you start. Data loss can be up to 22 hours (the time since last backup). If RPO is unacceptable, increase backup frequency or add point-in-time recovery (CNPG WAL archiving handles that — you already have it). Stating these numbers is the whole point — you can't improve what you don't measure.

#### Verification

- [ ] Daily schedule running on every cluster, backups appearing in Garage
- [ ] Initial DR drill completed for hello-dev with RTO and RPO documented
- [ ] CNPG continuous WAL archiving enabled — verify by checking that WAL files appear in Garage in addition to base backups
- [ ] Runbook committed to gitops repo with results table

---

### Phase 4.15: Kyverno Audit → Enforce Migration

**Goal:** Every policy seeded in Tier 2 Phase 2.14 moves from `validationFailureAction: Audit` to `Enforce`, with documented exemptions for cases where enforcement breaks legitimate workloads.

#### Migration ritual per policy

1. Pull recent PolicyReports: `kubectl get polr -A -o json | jq '.items[] | select(.results[].result == "fail")'`
2. Categorize violations:
   - **Real misconfigurations** — fix the workload
   - **Legitimate exceptions** — add namespace exemption to the policy
3. Update policy: `validationFailureAction: Enforce`
4. Commit and let Flux roll it out
5. Watch for new admission failures over the next 24 hours; address fast

#### Required exemptions (known cases)

- `kube-system`, `cilium-system`, `kyverno`, `external-secrets`, `cert-manager`, `flagger-system`, `falco` — system namespaces often need elevated privileges and/or images from upstream (not Harbor) during bootstrap *(v5.1: `argo-rollouts` removed — ADR-002; `falco` added, its modern-bpf driver needs privileged access)*
- `velero` — needs cluster-wide permissions for backups

Add to each policy spec:

```yaml
exclude:
  any:
    - resources:
        namespaces: [kube-system, cilium-system, kyverno, external-secrets, cert-manager, flagger-system, falco, velero]
```

#### One policy that *must* be enforced last: `require-image-signature`

Until every workload pulls signed images, enforcement breaks deployments. Sequence:

1. Confirm hello-otel (the only app you control end-to-end) has signed images via the CI pipeline
2. Add exemption list for "upstream charts that don't sign yet" — most public Helm charts don't push signatures
3. Switch the policy to enforce
4. Track the exemption list as technical debt — every time a chart vendor starts signing, remove the exemption

> **The honest scope call:** v5 will not have signature verification enforced on every image. The defense-industry pattern is to maintain a vendor allow-list of trusted unsigned-image sources alongside the signed-image enforcement. Document the list, work to shrink it over time. That posture is realistic and demonstrates real engineering judgment.

---

### Phase 4.16: Carryover Items From Earlier Tiers

A handful of items were deferred during tier construction. Address now or document as long-term TODOs:

- **Vault listener cert auto-rotation** (deferred from Tier 2 Phase 2.5) — write the systemd timer + pull script on each Vault VM, or rotate manually every 28 days. Calendar-pinned.
- **Egress firewall enforcement for air-gap** (deferred from Tier 2 Phase 2.10) — add VyOS firewall rules blocking VLANs 50/60 from initiating connections to docker.io, quay.io, ghcr.io, gcr.io, registry.k8s.io. FQDN-based blocking in VyOS is fiddly; an alternative is to deploy an explicit Squid proxy on bgp-01/bgp-02 that only allows Harbor and Cloudflare DNS.
- **Mobile root CA install** — install homelab root CA cert on your phone so mobile access to internal services doesn't warn about untrusted certificates.
- **DNS sprawl threshold** — if you've crossed ~20 hostname entries on VyOS, time to deploy CoreDNS as a platform service.
- **Keycloak realm declarative migration** — confirmed in Phase 4.4; verify drift-free state.

---

### Phase 4.17: Tier 4 Verification Gate

#### Delivery primitives

- [ ] Flagger controller on homelab-prod and homelab-dev (HelmRelease Ready)
- [ ] Per-environment Flux Kustomizations (dev/staging/prod) reconciling at least one app
- [ ] Keycloak realm declaratively managed, `tofu plan` shows no drift
- [ ] CI pipeline produces signed, attested images in Harbor
- [ ] Cosign verification works for signed images

#### Event-driven workflows

- [ ] *(v5.1: no phase builds this — either add the `Receiver` + GitHub webhook to Phase 4.2 or strike this item)* Flux `Receiver` (notification-controller webhook) live; a test push reconciles in seconds
- [ ] *(v5.1: no phase builds this — Harbor scans on push natively via Phase 2.9's Trivy integration; either wire the webhook explicitly or reword to "Harbor auto-scans on push")* Harbor image-push webhook triggers the Trivy scan job
- [ ] *(Argo Events EventBus/Sensor checks relocated to the Tier 5 MLOps gate — ADR-003)*

#### Custom app full stack

- [ ] hello-otel deployed to dev, staging, and prod via separate Flux `Kustomization`s (kustomize overlays — Phase 4.2)
- [ ] Flagger `Canary` walks through its analysis steps automatically
- [ ] Deliberate bad deploy aborts canary, traffic stays on stable
- [ ] Traces in Tempo, metrics in Prometheus, logs in Loki — all tagged with cluster + namespace
- [ ] SLO recording rules computing, burn-rate alerts configured

#### Personal apps (deferred)

- [ ] Vaultwarden, n8n, NetBox, Forgejo, Immich — *deferred to post-Tier-5*; not blocking Tier 4 completion
- [ ] When built post-Tier-5: each app deployed on homelab-prod, OIDC login works where supported, Velero backup verified, NetBox seeded with homelab inventory, Forgejo mirroring repos

#### CI runtime

- [ ] ARC runner scale set on homelab-dev, scales up on demand
- [ ] Self-hosted runners use Vault AppRole for Cosign signing

#### Resilience

- [ ] k6 baseline load test passes on hello-otel; metrics streaming to Prometheus
- [ ] Three Chaos Mesh experiments work (PodChaos, NetworkChaos, IOChaos)
- [ ] Combined chaos+load test executed at least once
- [ ] Velero on every cluster with daily schedules running
- [ ] Initial DR drill complete with RTO + RPO documented in the runbook

#### Policy

- [ ] All Kyverno policies moved to Enforce except documented exemptions
- [ ] Signature-verification policy in Enforce with vendor exemption list maintained
- [ ] No surprise admission failures over 7 consecutive days

#### Carryover items

- [ ] Vault listener cert rotation: implemented or calendar-pinned
- [ ] Egress firewall enforcement: implemented or documented as Phase 5 follow-up
- [ ] Mobile root CA installed
- [ ] Quarterly DR drill scheduled in calendar

---

### Phase 4.18: Closing Reflections

You're done. Or rather: the *foundation* is done. From this point, v5 stops being a build doc and starts being the substrate you ship on top of.

#### What v5 actually demonstrates

When you walk an interviewer through this, the talking points organize naturally by tier:

**Foundation (Tier 0).** "I run Vault as a platform substrate, not as an application. Three-node Raft cluster auto-unsealed via GCP KMS, with PKI/Transit/SSH/Database engines providing dynamic credentials, internal CA, encryption-as-a-service, and audited SSH OTPs. The substrate has its own redundant BGP routing fabric so it survives single hypervisor failures."

**Provisioning (Tier 1).** "Every VM and OS configuration is Vault-authenticated Terraform and Ansible. No long-lived credentials in tfvars, no encrypted YAML files, no `--ask-vault-pass`. RKE2 clusters with CIS profile, encryption-at-rest, audit policy, and Cilium with BGP control plane and WireGuard pod-to-pod encryption."

**Platform Services (Tier 2).** "Two-tier internal PKI with 24-hour leaf certificates auto-rotated by cert-manager. External Secrets Operator authenticates per-cluster via Kubernetes auth method. Self-hosted Harbor with Cosign signing using keys in Vault Transit — the key material never leaves Vault. Air-gap pattern on workload clusters demonstrates the Iron Bank style supply chain."

**Observability & Identity (Tier 3).** "Centralized LGTM stack with cross-cluster collection via Alloy. Falco + Tetragon for runtime security observability. Sloth-managed SLOs for the platform itself. Keycloak federates identity across every UI, with documented break-glass procedures because identity outages are real."

**Delivery (Tier 4).** "Progressive delivery via Flagger with Prometheus-driven canary analysis. Per-environment Flux Kustomizations with PR-gated promotion. Quarterly DR drills with measured RTO and RPO. Combined chaos engineering and load testing as a resilience exercise."

#### What v5 deliberately doesn't do

Worth being honest about scope:

- **Not multi-region.** Single physical site, eight hypervisors. Real DR for site loss would require a remote target — Garage backup replication or offsite Velero target as Phase 5 work.
- **Partial air-gap.** The mgmt plane still pulls upstream for observability bootstrap, and egress-firewall enforcement on workload clusters is documented but not strictly enforced. **v5 narrows this:** Zarf gives true disconnected package delivery, and the ephemeral air-gap clusters are offline by construction — but the *standing* platform is not end-to-end air-gapped.
- **Not full STIG; FIPS optional.** RKE2's CIS profile covers the K8s layer on the workload clusters, and the Talos mgmt plane is immutable with no interactive login — a strong STIG-adjacent posture. True FIPS needs the FIPS-validated RKE2 build and the entitled Talos FIPS image (both pinned as swap-in options in the configs, not assumed). Full OS-level STIG remains "CIS-adjacent" on the workload nodes.
- **Not HSM-backed.** Vault Transit keys are software-backed. Real defense environments back transit with HSMs (CloudHSM, Thales, YubiHSM). Pattern is identical; hardware is the upgrade.

These are honest gaps, not failures. Document them in ADRs and you have a roadmap for any future hardening pass.

#### Maintenance posture

The platform isn't "done" forever — it's done *for now*. Going forward:

- **Renovate** handles routine version bumps. Review weekly.
- **Quarterly:** DR drill, review Kyverno exemption list, rotate Vault recovery keys.
- **Monthly:** Review observability dashboards for newly-noisy alerts; tune burn rates.
- **Annually:** Audit IAM grants (GCP KMS service account scope), rotate the Cosign key, review SLO targets against actual reliability.

These are operations, not engineering. The engineering is done.

#### One last thing

Build the things on top of this that you actually want. Workflows in n8n that scratch real itches. Forgejo as your sandbox for projects you don't want on GitHub. Immich filled with the photos you care about preserving. The custom app, extended into something genuinely useful.

The whole point of a foundation is the buildings it lets you put up.

---

