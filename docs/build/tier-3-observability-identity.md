[← Docs index](../README.md) · **Operation Long Haul v5**

[← Tier 2 · Platform Services](tier-2-platform-services.md)  ·  [Tier 4 · Workloads & Delivery →](tier-4-workloads-delivery.md)

---

# Tier 3 — Observability & Identity

**Purpose:** Three operational clusters become *legible*. Metrics, logs, traces, and runtime security events flow from workload clusters into homelab-mgmt and are queryable through a single Grafana. SLOs are defined for the platform itself before any workload depends on them. Keycloak is the single source of identity, with every UI on the platform OIDC-federated and break-glass procedures documented.

**Why observability before workloads:** Tier 4 will deploy apps that exercise canary releases, chaos engineering, and load testing. None of that is meaningful without observability already in place to measure outcomes. Building the measurement substrate first means every workload deployed in Tier 4 gets metrics, logs, traces, and SLOs from the moment it lands.

**Why identity before workloads:** Same reason. Every app deployed in Tier 4 will OIDC-integrate to Keycloak at deploy time, not as a follow-up. Retrofitting OIDC after-the-fact is the v3 pattern — v5 makes identity foundational.

## Tier 3 Phases

- **3.1** — kube-prometheus-stack on homelab-mgmt
- **3.2** — Loki on homelab-mgmt (Garage S3 backed)
- **3.3** — Tempo on homelab-mgmt (Garage S3 backed)
- **3.4** — Grafana Alloy on all Kubernetes clusters
- **3.5** — Grafana Alloy on substrate VMs (Vault, BGP, NFS, Garage, hypervisors)
- **3.6** — Cross-cluster metric scraping + log shipping wired up
- **3.7** — Falco on workload clusters with Loki output
- **3.8** — Tetragon event export to Loki
- **3.9** — Alertmanager routing configured
- **3.10** — Sloth for SLO-driven alerts (platform SLOs defined)
- **3.11** — CloudNativePG operator on homelab-mgmt (for Keycloak)
- **3.12** — Kubernetes audit log immutable retention
- **3.13** — Keycloak deployment (Operator, declarative realm) + break-glass runbook
- **3.14** — OIDC integrations: Flux UI, Grafana, Harbor, Vault UI + oauth2-proxy forward-auth
- **3.15** — OpenCost — cost attribution and visibility
- **3.16** — Tier 3 verification gate

---

### Phase 3.1: kube-prometheus-stack on Mgmt-Plane

**Goal:** Single Prometheus instance on homelab-mgmt is the central metrics store. Per-cluster collection happens via Alloy in Phase 3.4 with `remote_write` here. Grafana, Alertmanager, kube-state-metrics, and node-exporter come bundled.

> **Architecture decision — central Prometheus vs federation:** Two patterns exist for multi-cluster metrics. Per-cluster Prometheus instances with Prometheus federation pulling rolled-up metrics to a central is the "classic" pattern. Modern shops have shifted to remote_write from a collection agent (Alloy/Grafana Agent) directly to a central Prometheus, eliminating per-cluster Prometheus servers entirely. v5 uses the modern pattern: no Prometheus on homelab-prod or homelab-dev, only Alloy. Central Prometheus on homelab-mgmt stores everything. Simpler, fewer moving parts, no federation lag.

#### 3.1a — Manifest via Flux

Add to `homelab-gitops/clusters/homelab-mgmt/observability/kube-prometheus-stack/`:

```yaml
# helmrelease.yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: kube-prometheus-stack
  namespace: observability
spec:
  interval: 30m
  chart:
    spec:
      chart: kube-prometheus-stack
      version: "65.x"
      sourceRef:
        kind: HelmRepository
        name: prometheus-community
        namespace: flux-system
  values:
    fullnameOverride: kps

    # Disable bundled node-exporter (Alloy handles node metrics in Phase 3.4)
    # Keep kube-state-metrics — it's a cluster-state source, not a collector
    nodeExporter:
      enabled: false

    prometheus:
      prometheusSpec:
        # Long-ish retention since we're not using Mimir
        retention: 30d
        retentionSize: "80GB"

        # Storage — NFS-backed for now, will reconsider if Prometheus
        # WAL latency on NFS becomes painful (it usually doesn't at this scale)
        storageSpec:
          volumeClaimTemplate:
            spec:
              storageClassName: nfs-csi
              accessModes: ["ReadWriteOnce"]
              resources:
                requests:
                  storage: 100Gi

        # Allow remote_write from external Alloy instances
        enableRemoteWriteReceiver: true

        # Select all PodMonitors / ServiceMonitors / PrometheusRules cluster-wide
        # rather than restricting to release labels (gives us flexibility for Tier 4)
        podMonitorSelectorNilUsesHelmValues: false
        serviceMonitorSelectorNilUsesHelmValues: false
        ruleSelectorNilUsesHelmValues: false
        probeSelectorNilUsesHelmValues: false

        resources:
          requests:
            cpu: 500m
            memory: 4Gi
          limits:
            memory: 6Gi

    alertmanager:
      alertmanagerSpec:
        storage:
          volumeClaimTemplate:
            spec:
              storageClassName: nfs-csi
              accessModes: ["ReadWriteOnce"]
              resources:
                requests:
                  storage: 5Gi

    grafana:
      # We'll OIDC-integrate Grafana in Phase 3.14; keep admin password as break-glass
      admin:
        existingSecret: grafana-admin-credentials   # materialized by ESO from Vault
      ingress:
        enabled: true
        ingressClassName: cilium
        hosts:
          - grafana.mgmt.homelab.internal
        tls:
          - secretName: mgmt-wildcard-tls
            hosts: [grafana.mgmt.homelab.internal]
      persistence:
        enabled: true
        type: pvc
        storageClassName: nfs-csi
        size: 10Gi
      # Pre-configure data sources — Prometheus is local, Loki and Tempo wired in their phases
      additionalDataSources:
        - name: Loki
          type: loki
          url: http://loki-gateway.observability.svc:3100
          access: proxy
        - name: Tempo
          type: tempo
          url: http://tempo.observability.svc:3200   # v5.1: monolithic mode serves HTTP on 3200
          access: proxy
          jsonData:
            tracesToLogs:
              datasourceUid: loki
              tags: ['cluster', 'namespace', 'pod']
```

#### 3.1b — Vault-stored Grafana admin

```bash
bao kv put secret/mgmt/grafana/admin \
  user=admin \
  password="$(openssl rand -base64 24)"
```

ExternalSecret manifest in the gitops repo materializes this as `grafana-admin-credentials`.

#### Verification

- [ ] Prometheus pod Running on homelab-mgmt
- [ ] Grafana UI reachable at `https://grafana.mgmt.homelab.internal`
- [ ] Login with vault-stored admin works
- [ ] Loki and Tempo data sources show "not yet wired" errors (expected — those come in 3.2 and 3.3)

---

### Phase 3.2: Loki on Mgmt-Plane

**Goal:** Loki deployed in `SimpleScalable` mode, chunks stored in Garage S3, index stored on NFS, ready to receive logs from Alloy on every cluster.

#### 3.2a — Garage bucket and credentials

Already pre-created in Tier 1 (`loki-chunks-mgmt`). Materialize Garage credentials via ESO into the observability namespace.

```bash
bao kv put secret/mgmt/loki/s3 \
  access-key="<garage-loki-key>" \
  secret-key="<garage-loki-secret>"
```

#### 3.2b — Loki HelmRelease (via Flux)

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: loki
  namespace: observability
spec:
  interval: 30m
  chart:
    spec:
      chart: loki
      version: "6.x"
      sourceRef:
        kind: HelmRepository
        name: grafana
        namespace: flux-system
  values:
    deploymentMode: SimpleScalable
    loki:
      auth_enabled: false   # single-tenant — we use cluster labels instead
      schemaConfig:
        configs:
          - from: "2024-01-01"
            store: tsdb
            object_store: s3
            schema: v13
            index:
              prefix: loki_index_
              period: 24h
      storage:
        type: s3
        bucketNames:
          chunks: loki-chunks-mgmt
          ruler: loki-chunks-mgmt
        s3:
          endpoint: http://garage-01.homelab.internal:3900
          secretAccessKey: ${LOKI_S3_SECRET}
          accessKeyId: ${LOKI_S3_KEY}
          s3ForcePathStyle: true
          insecure: true
      limits_config:
        retention_period: 90d    # 90 days of logs — adjust to your liking
        ingestion_rate_mb: 10
        ingestion_burst_size_mb: 20

    backend:
      replicas: 2
      persistence:
        storageClass: nfs-csi
        size: 20Gi
    read:
      replicas: 2
    write:
      replicas: 3              # write path is the most load-sensitive
      persistence:
        storageClass: nfs-csi
        size: 20Gi
    gateway:
      enabled: true            # nginx fronting Loki — what Grafana queries
```

#### Verification

- [ ] All Loki pods Running on homelab-mgmt
- [ ] In Grafana, the Loki data source test passes
- [ ] Send a manual test log via `curl` to Loki's push endpoint — verify it shows up in Grafana's Explore view

---

### Phase 3.3: Tempo on Mgmt-Plane

**Goal:** Tempo deployed in `monolithic` mode (sufficient for homelab scale; single binary, multiple replicas), traces stored in Garage S3, OTLP endpoints exposed for apps to push to directly.

```bash
# Vault-side
bao kv put secret/mgmt/tempo/s3 \
  access-key="<garage-tempo-key>" \
  secret-key="<garage-tempo-secret>"
```

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: tempo
  namespace: observability
spec:
  interval: 30m
  chart:
    spec:
      chart: tempo
      version: "1.x"
      sourceRef:
        kind: HelmRepository
        name: grafana
        namespace: flux-system
  values:
    tempo:
      storage:
        trace:
          backend: s3
          s3:
            bucket: tempo-traces-mgmt
            endpoint: garage-01.homelab.internal:3900
            insecure: true
            access_key: ${TEMPO_S3_KEY}
            secret_key: ${TEMPO_S3_SECRET}
      receivers:
        otlp:
          protocols:
            grpc:
              endpoint: 0.0.0.0:4317
            http:
              endpoint: 0.0.0.0:4318
      retention: 720h    # 30 days of traces
    persistence:
      enabled: true
      storageClassName: nfs-csi
      size: 10Gi
```

A `Gateway` HTTPRoute exposes OTLP/HTTP at `tempo-otlp.mgmt.homelab.internal:4318` so workload clusters can push without service-mesh trickery.

> **Why monolithic Tempo for homelab:** Microservices mode (separate distributor, ingester, querier, compactor) is the production scale-out option. Homelab scale doesn't need it. Monolithic is one container that does everything, scales horizontally via replicas, simple to reason about. ADR-worthy "knew the upgrade path, deliberately chose simpler."

#### Verification

- [ ] Tempo pods Running
- [ ] Grafana data source test passes
- [ ] Manual trace push via `curl` to `:4318/v1/traces` succeeds, trace queryable in Grafana Explore

---

### Phase 3.4: Grafana Alloy on All Clusters

**Goal:** Alloy installed on homelab-prod, homelab-dev, and homelab-mgmt as a DaemonSet. Single agent that scrapes Prometheus metrics, tails container logs, and forwards everything to homelab-mgmt's central stack.

> **Why Alloy not Promtail + Prometheus + OTel Collector separately:** Grafana Labs consolidated all three (and more) into Alloy in 2024. Same binary, single config, less operational surface. The legacy stack still works; Alloy is the future direction. Going with Alloy aligns the doc with where the ecosystem is heading rather than where it's been.

#### 3.4a — Alloy as DaemonSet on each cluster

Manifest deployed via Flux on all three clusters:

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2     # HelmRelease on every cluster
kind: HelmRelease
metadata:
  name: alloy
  namespace: observability
spec:
  interval: 30m
  chart:
    spec:
      chart: alloy
      version: "0.x"
      sourceRef:
        kind: HelmRepository
        name: grafana
  values:
    alloy:
      configMap:
        content: |-
          // ============================================================
          // Discovery
          // ============================================================
          discovery.kubernetes "pods" {
            role = "pod"
          }

          discovery.kubernetes "nodes" {
            role = "node"
          }

          // ============================================================
          // Logs
          // ============================================================
          loki.source.kubernetes "pods" {
            targets    = discovery.kubernetes.pods.targets
            forward_to = [loki.process.add_cluster_label.receiver]
          }

          loki.process "add_cluster_label" {
            forward_to = [loki.write.central.receiver]
            stage.static_labels {
              values = { cluster = "homelab-prod" }   // change per cluster
            }
          }

          loki.write "central" {
            endpoint {
              url = "https://loki.mgmt.homelab.internal/loki/api/v1/push"
              tls_config {
                ca_file = "/etc/ssl/certs/homelab-root-ca.crt"
              }
            }
          }

          // ============================================================
          // Metrics
          // ============================================================
          prometheus.scrape "kubelet_cadvisor" {
            targets = discovery.kubernetes.nodes.targets
            forward_to = [prometheus.remote_write.central.receiver]
            scheme = "https"
            tls_config {
              ca_file = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
              insecure_skip_verify = false
            }
            bearer_token_file = "/var/run/secrets/kubernetes.io/serviceaccount/token"
            metrics_path = "/metrics/cadvisor"
          }

          // ServiceMonitor / PodMonitor scraping
          prometheus.operator.servicemonitors "default" {
            forward_to = [prometheus.remote_write.central.receiver]
          }
          prometheus.operator.podmonitors "default" {
            forward_to = [prometheus.remote_write.central.receiver]
          }

          prometheus.remote_write "central" {
            endpoint {
              url = "https://prometheus.mgmt.homelab.internal/api/v1/write"
              tls_config {
                ca_file = "/etc/ssl/certs/homelab-root-ca.crt"
              }
            }
            external_labels = {
              cluster = "homelab-prod",   // change per cluster
            }
          }
```

#### 3.4b — Per-cluster label discipline

Every metric and every log line gets a `cluster` label (`homelab-prod`, `homelab-dev`, `mgmt`). Grafana dashboards filter by cluster. This is the entire reason multi-cluster observability works without separate UIs per environment.

#### Verification

- [ ] Alloy pods Running on every node of every cluster
- [ ] In Grafana, query `{cluster="homelab-prod"}` in Logs Explore — returns container logs
- [ ] In Grafana, query `up{cluster="homelab-dev"}` in Metrics — returns scrape targets

---

### Phase 3.5: Grafana Alloy on Substrate VMs

**Goal:** Vault VMs, VyOS BGP routers, NFS server, Garage host, and the Proxmox hypervisors themselves ship logs and metrics into the LGTM stack. No SSH-into-vault-01-at-3am to read journalctl when something goes sideways.

> **Why this matters:** Phase 3.4 deployed Alloy on every Kubernetes node — every cluster is observable. But the *substrate* (Vault VMs, routers, storage hosts, hypervisors) is invisible. When Vault unseal fails at 3am, when BGP flaps, when ZFS hits a scrub error — without this, you're SSHing manually. This phase closes the substrate observability gap.

#### 3.5a — Alloy on Ubuntu VMs (Vault, NFS, Garage hosts)

Extend the existing OS baseline Ansible role:

```yaml
# roles/observability/tasks/main.yml
- name: Install Grafana Alloy
  apt:
    deb: "https://github.com/grafana/alloy/releases/download/v1.4.0/alloy-{{ ansible_architecture }}.deb"
    state: present

- name: Drop Alloy config
  template:
    src: alloy/config.alloy.j2
    dest: /etc/alloy/config.alloy
    owner: root
    group: root
    mode: '0644'
  notify: restart alloy

- name: Enable + start Alloy
  systemd:
    name: alloy
    enabled: true
    state: started
```

Config template captures journald, node metrics, and ships them to mgmt-plane:

```alloy
// /etc/alloy/config.alloy
loki.source.journal "journal" {
  forward_to = [loki.write.mgmt.receiver]
  labels = {
    host = "{{ ansible_hostname }}",
    role = "{{ host_role }}",         // vault | nfs | garage | bgp | hypervisor
  }
}

{% if host_role == 'vault' %}
// OpenBao audit log → Loki (vault-* hosts only). Alloy needs read access:
// add the alloy user to the openbao group (audit dir is 0750 openbao:openbao).
loki.source.file "openbao_audit" {
  targets = [{
    __path__ = "/opt/openbao/audit/audit.log",
    host     = "{{ ansible_hostname }}",
    job      = "openbao-audit",
  }]
  forward_to = [loki.write.mgmt.receiver]
}
{% endif %}

prometheus.exporter.unix "node" { }

prometheus.scrape "self" {
  targets    = prometheus.exporter.unix.node.targets
  forward_to = [prometheus.remote_write.mgmt.receiver]
}

loki.write "mgmt" {
  endpoint {
    url = "https://loki.mgmt.homelab.internal/loki/api/v1/push"
    tls_config {
      ca_file = "/etc/ssl/certs/homelab-root-ca.crt"
    }
  }
  // WAL on disk: don't lose logs if mgmt-plane is briefly unreachable
  wal {
    enabled = true
    max_segment_age = "1h"
  }
}

prometheus.remote_write "mgmt" {
  endpoint {
    url = "https://prometheus.mgmt.homelab.internal/api/v1/write"
  }
}
```

Push to vault-01/02/03, nfs-01, garage-01.

#### 3.5b — Alloy on VyOS routers

VyOS is Debian-based. The deb installs, but VyOS treats services through its config commit system rather than systemd directly. The pattern:

```bash
# In a VyOS config commit-on-boot script (or systemd-via-VyOS-task):
sudo dpkg -i /config/scripts/alloy.deb
sudo systemctl enable alloy
sudo systemctl start alloy
```

Capture VyOS-specific telemetry. FRRouting (VyOS's routing daemon) exposes metrics on a Unix socket; Alloy reads them:

```alloy
prometheus.exporter.frr "frr" {
  socket = "/var/run/frr/frr.sock"
}

prometheus.scrape "frr" {
  targets    = prometheus.exporter.frr.frr.targets
  forward_to = [prometheus.remote_write.mgmt.receiver]
}
```

Important metrics: `bgp_session_established`, `bgp_received_prefix_count`, `vrrp_role` (master vs backup).

#### 3.5c — Alloy on Proxmox hypervisors

Proxmox is Debian. Direct install works. Capture three additional sources:

```alloy
// Proxmox VE API metrics
prometheus.exporter.pve "pve" {
  api_url = "https://localhost:8006/api2/json"
  username = "metrics@pam"
  token_id = "alloy"
  token_secret = sys.env("PVE_TOKEN")
}

// ZFS pool health
prometheus.exporter.zfs "zfs" { }

// Hypervisor host metrics (already covered by unix exporter)
```

Provision the `metrics@pam` user in Proxmox with `PVEAuditor` role (read-only). Token stored in Vault, materialized by Ansible to `/etc/alloy/pve-token.env`.

**Important constraint:** Alloy on the hypervisor must NOT depend on Kubernetes being up to function locally. The WAL config ensures Alloy queues logs to disk when mgmt-plane is unreachable and replays when connectivity returns. Test this explicitly during verification.

#### 3.5d — Grafana dashboards: Substrate Health

Add a dashboard set under a "Substrate" folder:

- **Substrate / Vault VMs** — disk usage (incl. audit-log headroom), memory pressure, `openbao.service` status, time-since-last-seal-status-check, unseal status alert if applicable
- **Substrate / Network (VyOS)** — BGP session state per neighbor, VRRP master/backup, packet drops, interface error rates
- **Substrate / Storage** — NFS req/s and latency, ZFS pool health, scrub last-completed timestamp, ZFS error counts, Garage S3 op rate
- **Substrate / Hypervisors** — VM density per host, memory balloon pressure, IO wait, disk SMART status, host uptime

#### 3.5e — Alerts on substrate signals

The substrate alerts that should wake you up:

- `openbao.service` not running on any vault-0X
- ZFS pool not ONLINE or scrub older than 30 days
- BGP session not Established for 2+ minutes (lose redundancy)
- VRRP master flap rate > 1/hr (likely network instability)
- Hypervisor IO wait > 30% for 10+ minutes
- Disk SMART self-test failed

Add these to Alertmanager routing (Phase 3.9) with `severity: critical`.

#### Verification

- [ ] `loki` query `{host="vault-01"}` in Grafana returns recent journal entries
- [ ] Prometheus query `node_filesystem_avail_bytes{host="garage-01"}` returns data
- [ ] BGP session state visible: `bgp_session_established{neighbor=~".*"}` returns 1 for each established session
- [ ] WAL test: `iptables -A OUTPUT -d <mgmt-plane> -j DROP` on vault-01 for 5 min → Alloy queues locally → restore connectivity → queued logs arrive in Loki
- [ ] All Substrate Health dashboards populated within 5 minutes of install
- [ ] Stop `openbao.service` on vault-02 → alert fires within 2 minutes

---

### Phase 3.6: Cross-Cluster Wiring Verification

This is a verification phase, not a deployment phase. Confirm that data from all three clusters lands in the central stack.

- [ ] Logs from homelab-prod, homelab-dev, and mgmt visible in Grafana via the `cluster` label
- [ ] Metrics from all three clusters in central Prometheus
- [ ] Multi-cluster Grafana dashboards work: import the kube-state-metrics dashboards from grafana.com and confirm cluster selector populates with all three values

---

### Phase 3.7: Falco on Workload Clusters

**Goal:** Falco installed on homelab-prod and homelab-dev with default rules + the Falco Sandbox ruleset. Events shipped to Loki via falcosidekick.

#### 3.7a — Install via Helm (deployed by a Flux HelmRelease)

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata: { name: falco, namespace: falco }   # reconciled per workload cluster by Flux
spec:
  interval: 30m
  install: { createNamespace: true }
  chart:
    spec:
      chart: falco
      sourceRef: { kind: HelmRepository, name: falcosecurity, namespace: flux-system }
      version: "4.x"
  values:
        driver:
          kind: modern-bpf   # eBPF driver, no kernel modules needed
        falcosidekick:
          enabled: true
          config:
            loki:
              hostport: https://loki.mgmt.homelab.internal
              tenant: homelab-prod
              tls:
                cafile: /etc/ssl/certs/homelab-root-ca.crt
        falcoctl:
          artifact:
            install:
              enabled: true
            follow:
              enabled: true
          config:
            artifact:
              install:
                refs: [falco-rules:3, falco-sandbox-rules:0]
              follow:
                refs: [falco-rules:3, falco-sandbox-rules:0]
```

Mirror to homelab-dev with `tenant: homelab-dev`.

#### 3.7b — Loki query examples for security review

```
# All Falco events from homelab-prod in the last hour
{cluster="homelab-prod", source="falco"} |= ""

# Critical and above only
{cluster="homelab-prod", source="falco"} |= "Critical" or {cluster="homelab-prod", source="falco"} |= "Error"

# Shell spawned in a container — common indicator
{cluster=~"homelab-prod|homelab-dev", source="falco"} |= "Terminal shell in container"
```

---

### Phase 3.8: Tetragon Event Export

**Goal:** Cilium Tetragon (already enabled in Tier 1 Cilium config) emits events. Alloy ships them to Loki.

Tetragon writes events to stdout in JSON. Alloy already tails container logs (Phase 3.4), so Tetragon events are *already* being shipped — they just need a label discriminator. Add to the Alloy log pipeline:

```hcl
loki.process "tag_tetragon" {
  forward_to = [loki.process.add_cluster_label.receiver]
  stage.match {
    selector = "{container=\"export-stdout\"}"
    stage.static_labels {
      values = { source = "tetragon" }
    }
  }
}
```

Query in Grafana: `{cluster="homelab-prod", source="tetragon"}`.

> **Falco vs Tetragon — why both:** Different lenses. Falco's rule engine is mature, with a large community ruleset library, and produces well-formed alert events. Tetragon's eBPF approach is more granular and lower-overhead but the rule-writing experience is more developer-y. In production you'd usually pick one as the primary alerting source and keep the other as a forensic detail layer. For v5, run both, learn the strengths, decide which becomes primary as workloads mature.

---

### Phase 3.9: Alertmanager Routing

**Goal:** Alerts from Prometheus rules reach you outside the homelab UI. v5 supports two delivery paths — pick one (or both).

#### Option A: Discord webhook (easy, third-party)

```yaml
# alertmanager-config.yaml (ESO-templated; webhook URL from Vault)
route:
  group_by: ['alertname', 'cluster', 'severity']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
  receiver: discord-default
  routes:
    - matchers: [severity="critical"]
      receiver: discord-critical
      repeat_interval: 30m

receivers:
  - name: discord-default
    discord_configs:
      - webhook_url_file: /etc/alertmanager/secrets/discord-default-webhook
  - name: discord-critical
    discord_configs:
      - webhook_url_file: /etc/alertmanager/secrets/discord-critical-webhook
```

#### Option B: Self-hosted ntfy.sh (no third-party)

Deploy ntfy as a small workload on homelab-mgmt, point Alertmanager at it via the generic webhook receiver. Defense-aligned: alerts never leave your network.

```yaml
# Brief ntfy deployment manifest
apiVersion: apps/v1
kind: Deployment
metadata: { name: ntfy, namespace: observability }
spec:
  replicas: 1
  selector: { matchLabels: { app: ntfy } }
  template:
    metadata: { labels: { app: ntfy } }
    spec:
      containers:
        - name: ntfy
          image: harbor.homelab-prod.homelab.internal/dockerhub/binwiederhier/ntfy:latest
          args: ["serve"]
          ports: [{ containerPort: 80, name: http }]
          volumeMounts:
            - { name: data, mountPath: /var/cache/ntfy }
      volumes:
        - name: data
          persistentVolumeClaim: { claimName: ntfy-data }
```

Exposed at `https://ntfy.mgmt.homelab.internal`. Subscribe from your phone via the ntfy app to specific topics (`homelab-prod-critical`, `homelab-dev-warnings`, etc.).

> **Recommendation:** Start with Discord (Option A) for friction-free setup. Migrate to ntfy in a Tier 3 follow-up if you want the "no alerts leave the network" property — defense-relevant, but not blocking.

#### Vault entries

```bash
bao kv put secret/mgmt/alertmanager/webhooks \
  discord-default-webhook="https://discord.com/api/webhooks/..." \
  discord-critical-webhook="https://discord.com/api/webhooks/..."
```

#### Verification

- [ ] Manually trigger an alert (e.g., scale down a deployment to 0 replicas with an `Up == 0` alert) — message arrives in Discord/ntfy within ~5 minutes
- [ ] Critical-routed alerts arrive in the correct channel/topic, not the default one

---

### Phase 3.10: Sloth — SLO-Driven Alerting

**Goal:** Define SLOs for the platform itself (API availability, Vault availability, Flux reconcile latency) before any workload depends on them. Sloth converts SLO definitions into Prometheus recording and alerting rules — multi-window multi-burn-rate, the Google SRE pattern.

> **Why this is on the doc before workloads exist:** SLO discipline is a learned habit, not a tool. Defining SLOs for the platform itself — *before* there are workloads to distract you — is how you build the muscle. By Tier 4 every new app gets an SLO at deploy time because the muscle exists. Skipping this until "the apps need it" is how shops end up with year-old apps that have no SLOs.

#### 3.10a — Install Sloth

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata: { name: sloth, namespace: observability }
spec:
  chart:
    spec:
      chart: sloth
      version: "0.x"
      sourceRef: { kind: HelmRepository, name: sloth }
```

#### 3.10b — Platform SLOs

```yaml
# observability/sloth/platform-slos.yaml
apiVersion: sloth.slok.dev/v1
kind: PrometheusServiceLevel
metadata:
  name: platform-availability
  namespace: observability
spec:
  service: "platform"
  labels:
    tier: "platform"
  slos:
    - name: "vault-api-availability"
      objective: 99.9
      description: "Vault API responsive within VLAN 40"
      sli:
        events:
          error_query: 'sum(rate(vault_audit_log_request_failure[5m]))'
          total_query: 'sum(rate(vault_audit_log_request[5m]))'
      alerting:
        name: VaultAPIBurnRate
        page_alert:    { labels: { severity: critical } }
        ticket_alert:  { labels: { severity: warning } }

    - name: "homelab-prod-api-availability"
      objective: 99.5
      sli:
        events:
          error_query: 'sum(rate(apiserver_request_total{cluster="homelab-prod",code=~"5.."}[5m]))'
          total_query: 'sum(rate(apiserver_request_total{cluster="homelab-prod"}[5m]))'
      alerting:
        name: HomelabProdAPIBurnRate
        page_alert:    { labels: { severity: critical } }

    - name: "flux-reconcile-success"
      objective: 99.0
      sli:
        events:
          error_query: 'sum(rate(gotk_reconcile_condition{type="Ready",status="False",kind=~"Kustomization|HelmRelease"}[5m]))'
          total_query: 'sum(rate(gotk_reconcile_condition{type="Ready",kind=~"Kustomization|HelmRelease"}[5m]))'
      alerting:
        name: FluxReconcileBurnRate
        ticket_alert:  { labels: { severity: warning } }
```

#### Verification

- [ ] Sloth pod Running
- [ ] PrometheusRule generated by Sloth visible: `kubectl get prometheusrule | grep platform`
- [ ] Recording rules query successfully in Prometheus (`slo:sli_error:ratio_rate5m`)
- [ ] Alert rules visible in Alertmanager UI under "Configured Alerts"

---

### Phase 3.11: CloudNativePG on Mgmt-Plane

**Goal:** Postgres operator installed on homelab-mgmt so Keycloak can have a real database.

Same install as Tier 2 Phase 2.8 on homelab-prod — duplicate the HelmRelease into `homelab-gitops/clusters/homelab-mgmt/cnpg/`.

> **Why a duplicate operator install rather than reaching across clusters:** Database stays in the same cluster as its consumer. Cross-cluster DB connections introduce a coupling we don't want for identity (Keycloak needs to function even if homelab-prod is rebuilding). The operator binary is tiny (~50MB RAM). ADR-worthy "each cluster owns its data tier."

---

### Phase 3.12: Kubernetes Audit Log Immutable Retention

**Goal:** Kubernetes API server audit logs ship immediately to Loki under a dedicated tenant with long retention. Long-term audit chunks replicate to AWS S3 with Object Lock. A compromised control plane cannot tamper with its own audit trail.

> **Why this matters:** RKE2's CIS profile writes audit logs to `/var/lib/rancher/rke2/server/logs/audit.log` on each CP node. If that node is compromised, those logs are mutable. Shipping them off-host immediately removes that attack window. For any defense customer (and increasingly for SOC2 / FedRAMP-adjacent commercial customers), audit-log integrity is a hard requirement. This phase makes the v5 platform actually audit-defensible rather than just "audit logs exist."

#### 3.12a — Separate audit logs from app logs in Alloy

Already shipping logs via the Tier 3.4 Alloy DaemonSet — but they currently go into the same Loki tenant as app logs. Separate them with a distinct source and a different `tenant_id` on the write endpoint.

Extend the Alloy config on control plane nodes:

```alloy
loki.source.file "k8s_audit" {
  targets = [{__path__ = "/var/lib/rancher/rke2/server/logs/audit.log"}]
  forward_to = [loki.process.audit.receiver]
}

loki.process "audit" {
  stage.static_labels {
    values = {
      log_type = "audit",
      cluster  = "homelab-prod",   // templated per cluster
    }
  }
  stage.json {
    expressions = {
      verb = "verb",
      user = "user.username",
      resource = "objectRef.resource",
      namespace = "objectRef.namespace",
    }
  }
  stage.labels {
    values = { verb = "", user = "", resource = "" }
  }
  forward_to = [loki.write.audit.receiver]
}

loki.write "audit" {
  endpoint {
    url       = "https://loki.mgmt.homelab.internal/loki/api/v1/push"
    tenant_id = "audit"
    tls_config {
      ca_file = "/etc/ssl/certs/homelab-root-ca.crt"
    }
  }
  wal {
    enabled = true
    max_segment_age = "4h"   // longer WAL for audit — never drop on the floor
  }
}
```

Audit logs now arrive in Loki under tenant `audit`, separately from app logs under tenant `default`.

#### 3.12b — Loki multi-tenant config with per-tenant retention


> **Breaking change — do this in one commit (v5.1):** flipping `auth_enabled` to `true` makes Loki reject every write and query that carries no tenant header. The writers configured in Phases 3.4/3.5 (`loki.write "central"` and `loki.write "mgmt"`) and the Grafana Loki datasource from 3.1 all send none today, so app-log ingest and every existing dashboard break the moment this lands. In the same change:
> - add `tenant_id = "default"` to **both** Alloy `loki.write` blocks (and `tenant_id = "audit"` on the audit-log writer added below),
> - add `httpHeaderName1: X-Scope-OrgID` / `httpHeaderValue1: default` to the Grafana Loki datasource, and add a second datasource for the `audit` tenant,
> - **append** the new `schemaConfig` entry rather than replacing the 3.2b one — rewriting `from:`/`prefix:` on the existing entry orphans every chunk already written.

Update Loki helm values:

```yaml
loki:
  config:
    auth_enabled: true   // required for multi-tenancy
    limits_config:
      retention_period: 30d      // default for any tenant
      ingestion_rate_mb: 16
      ingestion_burst_size_mb: 32
  # Per-tenant overrides
  runtimeConfig:
    overrides:
      audit:
        retention_period: 365d     # one year hot-queryable
        ingestion_rate_mb: 10
        max_query_lookback: 365d
  schemaConfig:
    configs:
      - from: 2026-01-01
        store: tsdb
        object_store: s3
        schema: v13
        index:
          prefix: index_
          period: 24h
```

#### 3.12c — Object Lock for long-term audit archive

The audit tenant in Loki keeps 365 days hot-queryable. Beyond that, chunks compact and ship to a separate AWS S3 bucket with Object Lock — the same WORM pattern from Phase 1.11.

Stand up the bucket:

```hcl
# homelab-terraform/modules/audit-archive/main.tf
resource "aws_s3_bucket" "audit_archive" {
  bucket              = "homelab-audit-logs-immutable"
  object_lock_enabled = true
}

resource "aws_s3_bucket_object_lock_configuration" "audit_archive" {
  bucket = aws_s3_bucket.audit_archive.id
  rule {
    default_retention {
      mode = "COMPLIANCE"   // even root can't bypass before window expires
      days = 2555           // 7 years — the common audit floor
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "audit_archive" {
  bucket = aws_s3_bucket.audit_archive.id
  rule {
    id     = "transition-to-glacier"
    status = "Enabled"
    transition {
      days          = 90
      storage_class = "GLACIER"
    }
  }
}
```

CronJob in `platform-dr` namespace runs daily, syncs Loki-compacted audit chunks from Garage to AWS:

```yaml
spec:
  schedule: "0 4 * * *"
  jobTemplate:
    spec:
      template:
        spec:
          containers:
            - name: rclone
              image: harbor.homelab-prod.homelab.internal/rclone/rclone:latest
              command:
                - rclone
                - sync
                - garage:loki-chunks/audit/
                - aws:homelab-audit-logs-immutable/
                - --immutable
                - --transfers=2
```

7-year retention with COMPLIANCE mode is the strictest tier; downgrade to GOVERNANCE mode if you want to be able to lift retention later in genuine emergencies. COMPLIANCE is what defense customers typically expect.

#### 3.12d — Grafana access pattern: tenant-aware permissions

Audit logs aren't for everyone. Configure Grafana with separate datasources per tenant:

- `Loki (default)` — app logs, available to anyone with Grafana login
- `Loki (audit)` — audit logs, available only to `mlops-admins` or `homelab-admins` group via Keycloak role mapping

Grafana datasource permissions (set in the datasource YAML):

```yaml
apiVersion: 1
datasources:
  - name: Loki-audit
    type: loki
    url: http://loki-gateway.observability.svc:3100   # v5.1: Loki lives in `observability`
    jsonData:
      httpHeaderName1: 'X-Scope-OrgID'
    secureJsonData:
      httpHeaderValue1: 'audit'
    # Restrict via Grafana team permissions
```

Build a default dashboard: "Audit Trail":
- Failed authentications (verb=create, resource=tokenreviews, status=Failure)
- RBAC denials (annotations.authorization.k8s.io/decision=Forbid)
- Secret reads (verb=get, resource=secrets)
- Namespace deletions (verb=delete, resource=namespaces)
- Privileged pod creations (Kyverno blocks these but the attempt is the signal)

#### 3.12e — Alert on audit log absence (canary)

If audit logs stop arriving from a cluster, that itself is a security signal — possibly indicating tampering or a compromise. Add a Prometheus alert:

```yaml
- alert: AuditLogIngestStopped
  expr: |
    rate(loki_distributor_lines_received_total{tenant="audit"}[5m]) == 0
  for: 10m
  labels:
    severity: critical
    pager: true
  annotations:
    summary: "Audit logs not arriving in Loki for {{ $labels.cluster }} for 10+ minutes"
    runbook_url: "https://apps.homelab.internal/runbooks/audit-log-stopped"
```

The runbook walks through diagnosing whether it's a network issue, Alloy crash, log rotation problem, or actual tampering.

#### Verification

- [ ] Audit logs visible in Grafana via the audit-tenant datasource: `{log_type="audit", cluster="homelab-prod"}`
- [ ] Non-admin user logged into Grafana sees app logs only, NOT audit (test with a `data-scientist` Keycloak user)
- [ ] 365d retention configured on audit tenant: `curl loki/loki/api/v1/labels --header "X-Scope-OrgID: audit"` works, oldest data is from a year back (after the year passes)
- [ ] AWS S3 archive bucket receiving compacted audit chunks daily
- [ ] `aws s3api delete-object --bucket homelab-audit-logs-immutable --key <chunk>` returns AccessDenied during retention window
- [ ] AuditLogIngestStopped alert fires after `iptables -A OUTPUT -d <loki-IP> -p tcp --dport 3100 -j DROP` on a CP node for 15 minutes

---

### Phase 3.13: Keycloak Deployment

**Goal:** Keycloak running on homelab-mgmt at `keycloak.mgmt.homelab.internal`, deployed via the **Keycloak Operator**, backed by CloudNativePG, with a **declaratively-defined** `homelab` realm and clients pre-staged for the Flux UI, Grafana, Harbor, Vault, and oauth2-proxy. **Break-glass admin retained on every integration.**

> **Why Keycloak and not something lighter:** this was re-litigated in v5.3 against ZITADEL and authentik and Keycloak was retained — on governance longevity (CNCF/Apache 2.0), claim-shape portability, and non-expiring skill transfer, *not* on resource footprint. The ergonomic wins that motivated the challenge are folded into 3.13b/3.13c and 3.14e below. Read [ADR-009](01-adrs.md) and [ADR-010](01-adrs.md) before changing anything in this phase, and honor the **claim contract** described in 3.13c — it is what keeps the decision reversible.

#### 3.13a — Postgres cluster for Keycloak

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata: { name: keycloak-postgres, namespace: keycloak }
spec:
  instances: 2
  storage:
    size: 10Gi
    storageClass: nfs-csi
  backup:
    barmanObjectStore:
      destinationPath: s3://harbor-registry/postgres-backups/keycloak
      endpointURL: http://garage-01.homelab.internal:3900
      s3Credentials:
        accessKeyId:     { name: garage-cnpg-creds, key: access-key }
        secretAccessKey: { name: garage-cnpg-creds, key: secret-key }
    retentionPolicy: "30d"
```

#### 3.13b — Keycloak via the Keycloak Operator *(v5.3 — ADR-010)*

> **Why not the Bitnami chart:** earlier revisions of this doc pinned `bitnami/keycloak`. Bitnami's public catalog converted to `bitnamilegacy` on **2025-08-28** — those images get no further security updates without a Broadcom subscription, and the charts still reference them by default. The identity tier is the last place to run unpatched images. Use the upstream **Keycloak Operator**, which also gives us `KeycloakRealmImport` for 3.13c. Check whether an official Operator-based Helm chart has landed upstream by the time you build this (`keycloak/keycloak` discussion #42170); if so, prefer it over the raw Operator manifests.

Install the Operator (version-pinned, images proxied through Harbor per the Tier 2 air-gap pivot), then:

```yaml
apiVersion: k8s.keycloak.org/v2alpha1
kind: Keycloak
metadata: { name: keycloak, namespace: keycloak }
spec:
  instances: 1                       # v5.3: one replica — see note below
  image: harbor.homelab-prod.homelab.internal/keycloak/keycloak:<pinned>
  db:
    vendor: postgres
    host: keycloak-postgres-rw.keycloak.svc
    port: 5432
    database: keycloak
    usernameSecret: { name: keycloak-postgres-app, key: username }
    passwordSecret: { name: keycloak-postgres-app, key: password }
  hostname:
    hostname: keycloak.mgmt.homelab.internal
  http:
    httpEnabled: true                # TLS terminates at the Cilium Gateway
  proxy:
    headers: xforwarded
  additionalOptions:
    - name: features
      value: "declarative-ui,passkeys"
  unsupported:
    podTemplate:
      spec:
        containers:
          - env:
              - name: JAVA_OPTS_APPEND
                value: "-Xms256m -Xmx512m"   # v5.3: cap the heap (ADR-010)
```

Route to it with an `HTTPRoute` on the mgmt Gateway — do **not** give this namespace its own copy of the wildcard TLS Secret (see the Phase 2.6b cross-namespace note and Appendix item 10).

> **One replica, deliberately (ADR-010).** Two replicas requires distributed Infinispan cache with JGroups/DNS_PING discovery, which is a reliable source of homelab pain on Talos. For a single-operator lab, identity *simplicity* is worth more than identity HA: a restart is a brief total-SSO outage, and every integration already retains break-glass credentials (3.13d). Revisit if the lab gains real users who notice.

#### 3.13c — Realm + clients, declarative from first apply *(v5.3 — ADR-010)*

> **Changed in v5.3:** earlier revisions built the realm by hand in the UI here, then reconciled it with `tofu import` and hand-copied client UUIDs in Phase 4.4. That dance is deleted. The realm is code from the first `kubectl apply`, which satisfies ADR-009's portability contract (rule 2) and removes the single ugliest step in the identity build.

Commit a `KeycloakRealmImport` to `homelab-gitops/apps/keycloak/`:

```yaml
apiVersion: k8s.keycloak.org/v2alpha1
kind: KeycloakRealmImport
metadata: { name: homelab, namespace: keycloak }
spec:
  keycloakCRName: keycloak
  realm:
    realm: homelab
    enabled: true
    displayName: Homelab
    registrationAllowed: false
    loginWithEmailAllowed: true
    accessTokenLifespan: 1800          # 30m
    ssoSessionIdleTimeout: 28800       # 8h
    ssoSessionMaxLifespan: 86400       # 24h
    groups:
      - name: homelab-admin
      - name: homelab-reader
    clients:
      - clientId: flux-ui
        name: Flux UI
        publicClient: false
        standardFlowEnabled: true
        redirectUris: ["https://flux.homelab.internal/oauth2/callback"]
        # The claim contract (ADR-009 rule 1): flat `groups` array of strings.
        protocolMappers:
          - name: groups
            protocol: openid-connect
            protocolMapper: oidc-group-membership-mapper
            config:
              "claim.name": "groups"
              "full.path": "false"
              "id.token.claim": "true"
              "access.token.claim": "true"
              "userinfo.token.claim": "true"
      # Repeat for grafana, harbor, vault, and oauth2-proxy (3.14e).
```

Then:

1. **Client secrets.** Generate one per client, store in Vault, and let ESO materialize them into the consuming namespaces. Do **not** inline secrets in the realm manifest — it is a Git-tracked file.
   ```bash
   bao kv put secret/mgmt/keycloak/flux-ui-oidc client-id="flux-ui" client-secret="$(openssl rand -base64 32)"
   # repeat per client; reference the same value in the realm manifest via a secret ref, not a literal
   ```
2. **Your user.** Create it via the admin console or `kcadm` after first apply and assign it to `homelab-admin`. Users are deliberately *not* declarative — a realm manifest is not the right home for credentials, and there are only ever a handful of humans here.
3. **Confirm idempotency.** Re-apply the manifest and verify the Operator reconciles without recreating clients (this is the property Phase 4.4 used to buy with `tofu import`).

> **The claim contract is load-bearing.** Every client gets the flat-`groups` mapper above, and every consumer reads only `sub` / `email` / `preferred_username` / `groups`. This is what makes ADR-009 reversible — keep it and swapping IdPs later is a weekend's work. Do not let an app talk you into a proprietary claim shape.

#### 3.13d — Break-glass runbook (commit to `homelab-gitops/docs/runbooks/keycloak-outage.md`)

```markdown
# Runbook: Keycloak Outage

## Symptoms
- Flux UI shows "OIDC unavailable" on login page
- Grafana login redirects to non-functioning Keycloak
- Harbor login fails

## Immediate Mitigation
Each integration retains a local admin account that bypasses OIDC:

| Service  | URL                                        | Local Admin Credential Path           |
| -------- | ------------------------------------------ | ------------------------------------- |
| Flux UI  | https://flux.homelab.internal/  (SSO via Keycloak)         | break-glass: workstation kubeconfig   |
| Grafana  | https://grafana.mgmt.../                   | pass: homelab/grafana/admin           |
| Harbor   | https://harbor.homelab-prod.../              | pass: homelab/harbor/admin            |
| Vault    | https://vault.../  (token auth, not OIDC)  | pass: homelab/vault/root-token-backup |

## Recovery Steps
1. Check Keycloak pod status: `kubectl --context homelab-mgmt -n keycloak get pods`
2. Check Postgres status: `kubectl --context homelab-mgmt -n keycloak get cluster keycloak-postgres`
3. Most common failure: Postgres pod OOM. Increase resources, rollout restart.
4. If Postgres data corruption: restore from Garage backup using CNPG's recovery procedure (separate runbook)
5. If realm config corruption: re-import from the realm JSON exported quarterly (auto-cron at TODO)
```

#### Verification

- [ ] Keycloak UI reachable, login as admin works
- [ ] Realm `homelab` exists with 5 clients configured (flux-ui, grafana, harbor, vault, oauth2-proxy) — **created by the committed manifest, not by hand**
- [ ] Re-applying the `KeycloakRealmImport` is idempotent: no client recreation, no lost secrets
- [ ] All 5 client secrets stored in Vault under `secret/mgmt/keycloak/*`; none inlined in Git
- [ ] A decoded ID token from any client shows `groups` as a **flat array of strings** (the ADR-009 claim contract)
- [ ] Local-admin credentials for each integration target stored in `pass`
- [ ] Runbook committed to gitops repo and readable
- [ ] JVM heap cap confirmed in effect (`kubectl exec … -- jcmd 1 VM.flags | grep MaxHeapSize`) and pod RSS is under ~700MB at idle

---

### Phase 3.14: OIDC Integrations

Now wire each consumer. Pattern is identical: read client secret from Vault via ESO, configure OIDC in the app, test login, retain local-admin fallback.

#### 3.14a — Flux UI (Weave GitOps / Capacitor)

Flux has no built-in UI, so a single read-only dashboard on homelab-mgmt provides cross-cluster visibility and takes the Keycloak OIDC slot ArgoCD held in v4. Deploy Weave GitOps (or Capacitor) via a Flux HelmRelease, behind the Gateway with OIDC:

```yaml
# values excerpt — Weave GitOps with Keycloak OIDC
adminUser:
  create: false              # no local admin; SSO only (break-glass = workstation kubeconfig)
oidc:
  enabled: true
  issuerURL: https://keycloak.mgmt.homelab.internal/realms/homelab
  clientID: flux-ui
  clientSecretName: flux-ui-oidc        # delivered by ESO from Vault
  redirectURL: https://flux.homelab.internal/oauth2/callback
```

The `flux-ui` client is already declared in the Phase 3.13c realm manifest — no manual creation step. Store its secret in Vault and let ESO materialize `flux-ui-oidc`. Break-glass stays the workstation kubeconfig + `flux`/`kubectl`. *(v5.3: this used to say "or manually for bootstrap" — that path is gone; see ADR-010.)*

#### 3.14b — Grafana

In the kube-prometheus-stack values, add:

```yaml
grafana:
  grafana.ini:
    server:
      root_url: https://grafana.mgmt.homelab.internal
    auth.generic_oauth:
      enabled: true
      name: Keycloak
      client_id: grafana
      client_secret: $__file{/etc/grafana/oauth-secret/secret}
      scopes: openid email profile groups
      auth_url: https://keycloak.mgmt.homelab.internal/realms/homelab/protocol/openid-connect/auth
      token_url: https://keycloak.mgmt.homelab.internal/realms/homelab/protocol/openid-connect/token
      api_url:  https://keycloak.mgmt.homelab.internal/realms/homelab/protocol/openid-connect/userinfo
      role_attribute_path: contains(groups[*], 'homelab-admin') && 'Admin' || 'Viewer'
```

ESO mounts the client secret to `/etc/grafana/oauth-secret/secret`.

#### 3.14c — Harbor

Harbor UI → Administration → Configuration → Authentication → OIDC Provider:

- Name: Keycloak
- Endpoint: `https://keycloak.mgmt.homelab.internal/realms/homelab`
- Client ID: harbor
- Client Secret: (from Vault)
- Scope: `openid,profile,email,groups`
- Verify Certificate: yes
- Auto onboarding: yes
- User claim: preferred_username

#### 3.14d — Vault UI *(OpenBao ships the same web UI)*

```bash
bao auth enable oidc
bao write auth/oidc/config \
  oidc_discovery_url="https://keycloak.mgmt.homelab.internal/realms/homelab" \
  oidc_client_id="vault" \
  oidc_client_secret="<from-keycloak>" \
  default_role="reader"

bao write auth/oidc/role/admin \
  bound_audiences="vault" \
  allowed_redirect_uris="https://vault.homelab.internal:8200/ui/vault/auth/oidc/oidc/callback" \
  allowed_redirect_uris="http://localhost:8250/oidc/callback" \
  user_claim="sub" \
  groups_claim="groups" \
  bound_claims='{"groups": ["homelab-admin"]}' \
  policies="default"   # Vault root policy retained only via token auth as break-glass

bao write auth/oidc/role/reader \
  bound_audiences="vault" \
  allowed_redirect_uris="https://vault.homelab.internal:8200/ui/vault/auth/oidc/oidc/callback" \
  user_claim="sub" \
  policies="default"
```

> **Vault's root token stays for break-glass.** The root token never gets revoked. It's stored in `pass` under `homelab/vault/root-token-backup` and is the bypass if Keycloak is down AND you've locked yourself out of OIDC. Generate-root via recovery keys is the *deeper* break-glass; root token is the everyday one.

#### 3.14e — oauth2-proxy: forward-auth for apps that don't speak OIDC *(v5.3 — ADR-010)*

**Goal:** A generic authentication layer in front of applications with absent or paywalled native OIDC support, so "no SSO" stops being an acceptable answer anywhere on the platform.

> **Why this exists.** Keycloak has no built-in forward-auth/proxy provider (this is authentik's one genuine advantage — see ADR-009). oauth2-proxy fills the gap with a boring, standards-based reverse proxy rather than a second IdP. It immediately upgrades the SSO story for Phase 4.7 (Vaultwarden) and 4.8 (n8n), where the spec previously said "not worth wiring."

Deploy once per protected app (or once with per-route config), behind the Cilium Gateway:

```yaml
# homelab-gitops/apps/oauth2-proxy/base/values.yaml — excerpt
config:
  clientID: oauth2-proxy
  existingSecret: oauth2-proxy-oidc        # ESO from Vault; holds client secret + cookie secret
extraArgs:
  provider: oidc
  oidc-issuer-url: https://keycloak.mgmt.homelab.internal/realms/homelab
  email-domain: "*"
  scope: "openid email profile groups"
  # Authorize on the SAME flat `groups` claim every other integration uses (ADR-009 rule 1)
  oidc-groups-claim: groups
  allowed-group: homelab-admin
  upstream: http://<app-service>.<namespace>.svc:<port>
  reverse-proxy: "true"                    # trust X-Forwarded-* from the Gateway
  set-xauthrequest: "true"                 # pass identity downstream as headers
  pass-access-token: "false"
```

Point the app's `HTTPRoute` at the oauth2-proxy Service rather than the app Service. For apps that can consume trusted headers (n8n, some others), map `X-Auth-Request-Email` / `X-Auth-Request-Preferred-Username` to their header-auth mechanism so you get real per-user identity rather than a shared gate. For apps that can't, oauth2-proxy is still a real access control boundary in front of an app that had none.

**Cautions worth writing down:**
- Forward-auth is an *authentication* gate, not authorization inside the app. Vaultwarden still has its own vault password; oauth2-proxy just means the login page isn't reachable without a Keycloak session.
- Don't put oauth2-proxy in front of anything with its own OIDC support that works — double auth is toil, not defense in depth.
- Don't put it in front of API/webhook endpoints that need to be machine-callable (Harbor's registry API, Forgejo's git-over-HTTPS). Scope the protected routes deliberately.
- The `oauth2-proxy` Keycloak client is declared in the Phase 3.13c realm manifest like any other.

#### Verification

- [ ] Log into each UI via Keycloak (Flux UI, Grafana, Harbor, Vault UI)
- [ ] oauth2-proxy gates a test app: unauthenticated request redirects to Keycloak; post-login request reaches the upstream
- [ ] A user outside `homelab-admin` is rejected by `allowed-group`
- [ ] Downstream app sees `X-Auth-Request-Email` populated with the real user
- [ ] Group-based authorization works: removing yourself from `homelab-admin` in Keycloak demotes access to read-only on next login
- [ ] Local-admin fallback works for each (test by deliberately failing OIDC — e.g., temporarily change client_secret to garbage, verify local-admin still works, restore)
- [ ] Vault's CLI OIDC login flow works: `bao login -method=oidc role=admin` opens browser, returns token

---

### Phase 3.15: OpenCost — Cost Attribution and Visibility

**Goal:** Per-namespace, per-tenant, per-workload cost visibility across homelab clusters and AWS cloud bursts. Replaces what would otherwise be a multi-week build of custom Prometheus recording rules and label-slicing.

> **Why this matters:** Tier 5 multi-tenancy needs cost accountability — who's burning the GPU dollars on a cloud burst? Building this from scratch with PromQL gets you 60% of the way to OpenCost's out-of-the-box dashboards and saves the rest of the build entirely. OpenCost is the CNCF project Kubecost is built on; it's production-grade and free.

#### 3.15a — Deploy OpenCost on mgmt-plane

Single central OpenCost on homelab-mgmt with federation from workload clusters.

```yaml
# homelab-gitops/apps/opencost/values.yaml
opencost:
  prometheus:
    external:
      enabled: true
      url: http://kps-prometheus.observability.svc:9090   # v5.1: matches fullnameOverride `kps`
  exporter:
    defaultClusterId: homelab-mgmt
    persistentVolume:
      enabled: true
      size: 10Gi
  ui:
    enabled: true
    ingress:
      enabled: true
      hosts:
        - opencost.mgmt.homelab.internal
      annotations:
        external-dns.alpha.kubernetes.io/hostname: opencost.mgmt.homelab.internal
  # Synthetic pricing for homelab hardware (amortized) — these aren't free
  customPricing:
    enabled: true
    provider: custom
    costModel:
      CPU: 0.02       # $/CPU-hour, M920q amortization
      spotCPU: 0.02
      RAM: 0.005      # $/GB-hour
      spotRAM: 0.005
      GPU: 0          # no homelab GPUs
      storage: 0.0001 # $/GB-hour
      internetNetworkEgress: 0
      regionNetworkEgress: 0
      zoneNetworkEgress: 0
```

Cloud-burst clusters automatically use real AWS prices when OpenCost detects them — no custom pricing needed for those.

#### 3.15b — Federation from workload clusters

Each workload cluster runs an OpenCost agent that the central instance scrapes:

```yaml
# homelab-gitops/apps/opencost-agent/values.yaml  (on homelab-prod, homelab-dev)
opencost:
  exporter:
    defaultClusterId: homelab-prod  # or homelab-dev
  prometheus:
    external:
      url: http://prometheus.mgmt.homelab.internal:9090   # central Prom
  ui:
    enabled: false  # agents don't expose UI, only central does
```

Central OpenCost aggregates by `clusterId` label, so the UI shows cost broken down by source cluster.

#### 3.15c — Label-based cost attribution

OpenCost slices by Kubernetes labels. The Tier 5 multi-tenancy labels (`mlops.homelab/owner-sub`, `mlops.homelab/owner-username`) are designed for this.

```bash
# Cost by owner over the last 30 days
curl 'http://opencost.mgmt.homelab.internal/allocation?window=30d&aggregate=label:mlops_homelab_owner_username'
```

Push aggregations into Prometheus as recording rules so they appear in Grafana:

```yaml
- record: mlops:cost_by_owner_30d:sum
  expr: |
    sum by (mlops_homelab_owner_username) (
      opencost_namespace_total_cost{namespace=~"mlops-.+"}
    )

- record: mlops:cost_by_tier_30d:sum
  expr: |
    sum by (mlops_homelab_tier) (
      opencost_namespace_total_cost{namespace=~"mlops-.+"}
    )
```

#### 3.15d — Cloud-burst cost attribution

Tier 5.10 spins up AWS EKS clusters per training job. Two integration points:

1. **Resource tagging.** Terraform module tags every AWS resource with `mlops-burst-job-id` and `owner-username`. AWS Cost Explorer reads these tags.

2. **Cost Explorer puller.** A CronJob in homelab-mgmt queries Cost Explorer daily, attributes spend to users, pushes results to Prometheus pushgateway:

```python
# scripts/aws-cost-attribution.py
import boto3, os, requests
from datetime import datetime, timedelta

ce = boto3.client('ce')
end = datetime.utcnow().date()
start = end - timedelta(days=1)

resp = ce.get_cost_and_usage(
    TimePeriod={'Start': str(start), 'End': str(end)},
    Granularity='DAILY',
    Metrics=['UnblendedCost'],
    GroupBy=[{'Type': 'TAG', 'Key': 'owner-username'}]
)

for group in resp['ResultsByTime'][0]['Groups']:
    owner = group['Keys'][0].split('$')[1]   # "owner-username$alice"
    cost = float(group['Metrics']['UnblendedCost']['Amount'])
    # Push to Prometheus pushgateway
    requests.post(
        f'{os.environ["PUSHGATEWAY"]}/metrics/job/aws-cost-attribution',
        data=f'aws_cost_daily{{owner="{owner}"}} {cost}\n'
    )
```

AWS creds via Vault AWS secrets engine (Tier 5.7).

#### 3.15e — Grafana dashboards and budget alerts

Add the dashboard set:
- **MLOps Cost by Tenant** — total $ per Keycloak user over time, daily/weekly/monthly
- **MLOps Cost by Tier** — sandbox vs staging vs prod cost ratios
- **Cloud Burst Spend** — daily AWS spend with drill-down by user and job-id
- **Cost Forecasts** — naive 30-day projection per user based on trailing rate

Budget alerts:

```yaml
- alert: TenantMonthlyBudgetExceeded
  expr: mlops:cost_by_owner_30d:sum > 500
  labels:
    severity: warning
  annotations:
    summary: "Tenant {{ $labels.mlops_homelab_owner_username }} exceeded $500 in trailing 30d"

- alert: CloudBurstSpendSpike
  expr: rate(aws_cost_daily[1d]) > rate(aws_cost_daily[7d]) * 3
  for: 1h
  labels:
    severity: critical
  annotations:
    summary: "Cloud burst spend tripled vs trailing week — runaway job?"
```

#### Verification

- [ ] OpenCost UI reachable at https://opencost.mgmt.homelab.internal
- [ ] Cost data appearing for all three clusters (cluster selector populates)
- [ ] Custom pricing applied: verify CPU cost matches config
- [ ] Label aggregation: `curl 'opencost.mgmt.homelab.internal/allocation?aggregate=label:mlops_homelab_owner_username'` returns per-owner data
- [ ] After a Tier 5.10 cloud-burst job: AWS spend attributed within 24h
- [ ] Budget alert fires when set to a deliberately low threshold (then revert)
- [ ] Spend spike alert tested by manipulating a synthetic high value

---

### Phase 3.16: Tier 3 Verification Gate

#### Observability

- [ ] Prometheus on homelab-mgmt scrapes all three clusters via Alloy remote_write
- [ ] Loki receives logs from all three clusters; cluster label discriminates correctly
- [ ] Tempo receives traces from manual test pushes; trace queryable in Grafana
- [ ] Multi-cluster dashboards work: kube-state-metrics, node-exporter, Cilium dashboards all populate for all three clusters
- [ ] Grafana data sources all green
- [ ] Alloy DaemonSet healthy on every node of every cluster

#### Substrate observability

- [ ] Alloy running on every Vault VM, NFS host, Garage host, BGP router, and Proxmox hypervisor
- [ ] `loki` query `{host="vault-01"}` returns recent journal entries
- [ ] BGP session metrics visible: `bgp_session_established` returns 1 per established neighbor
- [ ] Substrate Health dashboards populated (Vault, Network, Storage, Hypervisors)
- [ ] WAL resilience verified: substrate Alloy queues logs locally when mgmt-plane is briefly unreachable, replays on recovery

#### Audit log immutability

- [ ] Audit logs visible under separate Loki tenant `audit` (verify with `X-Scope-OrgID: audit`)
- [ ] Non-admin Grafana user cannot read audit tenant (test with `data-scientist` user)
- [ ] AWS S3 audit archive bucket receiving daily compacted chunks
- [ ] Object Lock enforced: delete attempt on archived chunk returns AccessDenied
- [ ] AuditLogIngestStopped alert fires when audit log shipping is artificially broken

#### Cost attribution

- [ ] OpenCost UI reachable at `https://opencost.mgmt.homelab.internal`
- [ ] Cost data visible per cluster (homelab-prod, homelab-dev, homelab-mgmt)
- [ ] Custom homelab pricing applied
- [ ] Per-namespace cost breakdown working
- [ ] Label aggregation by `mlops.homelab/owner-username` returns data (after Tier 5 tenants exist; otherwise verify with placeholder labels)

#### Runtime security

- [ ] Falco running on homelab-prod and homelab-dev; events arrive in Loki tagged `source=falco`
- [ ] Tetragon events tagged `source=tetragon` in Loki
- [ ] Synthetic event test: `kubectl exec` into a pod, verify a "Terminal shell in container" event lands in Loki within 30 seconds

#### Alerting

- [ ] Alertmanager delivers test alert to Discord/ntfy within 5 minutes
- [ ] Critical-severity routes hit the critical channel; warning-severity hits the default
- [ ] Sloth-generated SLO alerts visible in Alertmanager UI

#### Identity

- [ ] Keycloak reachable, realm + 4 clients + admin user configured
- [ ] Each of Flux UI, Grafana, Harbor, Vault UI logs in via Keycloak SSO
- [ ] Group-based authorization tested for each
- [ ] Break-glass local-admin works for each (verified)
- [ ] Keycloak outage runbook committed to gitops repo

#### Hygiene

- [ ] All OIDC client secrets in Vault
- [ ] All break-glass credentials in `pass`
- [ ] CNPG backups for keycloak-postgres landing in Garage
- [ ] Workstation (and ideally mobile) trust store contains the homelab root CA — every UI loads with a green padlock

When every item passes: **Tier 3 is complete.** The platform now sees itself, knows when it's broken, and authenticates everyone through a single source of truth. Tier 4 is the payoff — actual workloads deployed via real GitOps patterns, with canary rollouts, load testing, and chaos engineering exercising everything you just built.
