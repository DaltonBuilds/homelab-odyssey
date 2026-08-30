[← Docs index](../README.md) · **Operation Long Haul v5**

[← Tier 1 · Platform Provisioning](tier-1-platform-provisioning.md)  ·  [Tier 3 · Observability & Identity →](tier-3-observability-identity.md)

---

# Tier 2 — Platform Services

**Purpose:** Three operational clusters from Tier 1 become a usable platform. By the end of Tier 2 you have BGP-advertised load balancers, internal DNS resolution, automated certificate issuance (internal + public), a working Vault-to-Kubernetes integration on every cluster, a self-hosted container registry with image signing, the air-gap pattern in place for workload clusters, GitOps tooling installed and ready to manage workloads in Tier 4, policy enforcement in audit mode, and automated dependency updates.

**Why this tier sits between provisioning and workloads:** Tier 1 produced clusters that *exist*. Tier 2 produces clusters that are *consumable* — services can be exposed, secrets can flow in, certs are automatic, images are stored and signed, and GitOps controllers are ready to reconcile manifests. Nothing here is a workload itself; everything is infrastructure that workloads depend on.

**What changes from v3:**
- BGP control plane replaces L2 announcements (v3 used `cilium-l2announcement` CRDs)
- Two PKIs instead of one: internal CA via Vault PKI for service-to-service, Let's Encrypt for public-facing
- ESO authenticates to Vault via Kubernetes auth method (v3 used static tokens)
- Cosign keys for image signing live in Vault Transit, never on disk
- Harbor replaces "pull from Docker Hub directly" as the platform registry
- Air-gap pivot: workload clusters pull only from Harbor; homelab-mgmt keeps upstream access for observability bootstrap
- CloudNativePG operator deployed early as a platform service (v3 ran a single Postgres pod per app)
- Flux reconciles all three clusters (workloads + mgmt); **Flagger** handles progressive delivery on the workload clusters *(v5: ArgoCD removed — ADR-002)*

## Tier 2 Phases

- **2.1** — Cilium BGP activation + internal DNS via VyOS
- **2.2** — Vault Kubernetes auth method (one backend per cluster)
- **2.3** — External Secrets Operator on all three clusters
- **2.4** — cert-manager + Vault PKI issuer + Let's Encrypt issuer
- **2.5** — Vault's own listener cert migrated to cert-manager-managed rotation
- **2.6** — Cilium Gateway API resources (per-cluster Gateway, GatewayClass)
- **2.7** — ExternalDNS (CoreDNS+etcd authoritative; ExternalDNS per cluster)
- **2.8** — CloudNativePG operator on homelab-prod
- **2.9** — Harbor deployment (Postgres via CloudNativePG, blob storage in Garage, Cosign keys in Vault Transit)
- **2.10** — Air-gap pivot: workload clusters pull from Harbor
- **2.11** — Zarf for air-gapped package delivery *(v5)*
- **2.12** — Flux on workload clusters (homelab-prod, homelab-dev)
- **2.13** — Flux on homelab-mgmt (Talos)
- **2.14** — Kyverno in audit mode with baseline policy seeds
- **2.15** — Renovate Bot via GitHub App
- **2.16** — Supply chain attestation — SBOMs via Syft + Cosign
- **2.17** — Tier 2 verification gate

---

### Phase 2.1: Cilium BGP Activation + Internal DNS

**Goal:** Each cluster's Cilium agents peer with bgp-01/bgp-02 via eBGP and start advertising LoadBalancer IPs. VyOS resolves the `homelab.internal` domain so services have proper names.

#### 2.1a — Internal DNS on VyOS

The BGP routers also serve as the internal DNS authority for `homelab.internal`. Add to both bgp-01 and bgp-02:

```bash
configure

# Forward upstream queries (everything that isn't homelab.internal) to your edge DNS
set service dns forwarding system
set service dns forwarding listen-address 192.168.40.10  # bgp-02 uses .11
set service dns forwarding allow-from 192.168.0.0/16

# Static A records for the platform tier and cluster API endpoints
# These never change, so static records are simpler than running a real DNS daemon
set service dns forwarding host-file
set system static-host-mapping host-name vault.homelab.internal           inet 192.168.40.20
set system static-host-mapping host-name vault.homelab.internal           inet 192.168.40.21
set system static-host-mapping host-name vault.homelab.internal           inet 192.168.40.22
set system static-host-mapping host-name nfs.homelab.internal             inet 192.168.40.51
set system static-host-mapping host-name garage-01.homelab.internal          inet 192.168.40.53
set system static-host-mapping host-name homelab-prod-api.homelab.internal  inet 192.168.50.30
set system static-host-mapping host-name homelab-dev-api.homelab.internal       inet 192.168.60.30
set system static-host-mapping host-name mgmt-api.homelab.internal        inet 192.168.40.63

# Wildcard records pointing at LB IPs will be added per-service in Phase 2.6 (Gateway resources)
# For now, the cluster API endpoints and platform services are enough.

commit
save
```

Configure your UniFi gateway to forward `homelab.internal` queries to `192.168.40.1` (the VRRP virtual IP). Settings → Networks → (your VLAN) → DHCP → DNS Server → add `192.168.40.1`. Or better: add a conditional DNS forwarder in the UniFi controller (Settings → Routing → DNS → conditional forwarding) so the routing happens at the gateway level for all clients.

> **Why static records instead of a proper DNS server (CoreDNS/AdGuard):** Resisting infrastructure sprawl. Two records will change with any frequency (LB IPs for Gateway, added in Phase 2.6), and those go in by hand once per Gateway. If this list grows past ~20 entries, revisit and add CoreDNS as a dedicated platform service. For now, this is the right amount of complexity.

#### 2.1b — Cilium BGP cluster config (homelab-prod example)

The Cilium CRDs that activate BGP. Apply to homelab-prod via a manifest in `homelab-gitops/clusters/homelab-prod/networking/cilium-bgp.yaml` — this will be reconciled by Flux later, but for bootstrap we `kubectl apply` it directly.

```yaml
---
apiVersion: cilium.io/v2alpha1
kind: CiliumBGPClusterConfig
metadata:
  name: homelab-prod-bgp
spec:
  nodeSelector:
    matchLabels:
      topology.kubernetes.io/zone: homelab-prod-cp
      # Plus a second selector for workers — combined via OR via separate instances if needed
  bgpInstances:
    - name: "instance-65001"
      localASN: 65001
      peers:
        - name: "bgp-01"
          peerASN: 65000
          peerAddress: 192.168.40.10
          peerConfigRef:
            name: "default-peer-config"
        - name: "bgp-02"
          peerASN: 65000
          peerAddress: 192.168.40.11
          peerConfigRef:
            name: "default-peer-config"
---
apiVersion: cilium.io/v2alpha1
kind: CiliumBGPPeerConfig
metadata:
  name: default-peer-config
spec:
  timers:
    holdTimeSeconds: 30
    keepAliveTimeSeconds: 10
  gracefulRestart:
    enabled: true
    restartTimeSeconds: 120
  families:
    - afi: ipv4
      safi: unicast
      advertisements:
        matchLabels:
          advertise: "bgp"
---
apiVersion: cilium.io/v2alpha1
kind: CiliumBGPAdvertisement
metadata:
  name: homelab-prod-services
  labels:
    advertise: "bgp"
spec:
  advertisements:
    - advertisementType: "Service"
      service:
        addresses:
          - LoadBalancerIP
      selector:
        matchExpressions:
          - key: "somekey"
            operator: "NotIn"
            values: ["never-match"]   # match all services with LoadBalancer type
---
apiVersion: cilium.io/v2alpha1
kind: CiliumLoadBalancerIPPool
metadata:
  name: homelab-prod-lb-pool
spec:
  blocks:
    - start: "192.168.50.240"
      stop: "192.168.50.250"
  serviceSelector:
    matchLabels:
      io.cilium/lb-pool: homelab-prod
```

Apply identical manifests on homelab-dev (ASN 65002, pool `192.168.60.240–250`, selector label `homelab-dev`) and homelab-mgmt (ASN 65003, pool `192.168.40.240–250`, selector label `mgmt`).

> **ASN choice on homelab-mgmt:** I had 65003 left implicit in Tier 0. Going with that — each cluster gets its own ASN so BGP loop prevention works correctly across the fabric.

#### 2.1c — Activate the second BGP peer on VyOS

In Tier 0 we pre-staged neighbor-groups but didn't bind specific peers. Now bind the cluster nodes as peers. On bgp-01:

```bash
configure

# homelab-prod nodes peer from VLAN 50
set protocols bgp neighbor 192.168.50.30 peer-group homelab-prod
set protocols bgp neighbor 192.168.50.31 peer-group homelab-prod
set protocols bgp neighbor 192.168.50.32 peer-group homelab-prod
set protocols bgp neighbor 192.168.50.33 peer-group homelab-prod

# homelab-dev nodes peer from VLAN 60
set protocols bgp neighbor 192.168.60.30 peer-group homelab-dev
set protocols bgp neighbor 192.168.60.31 peer-group homelab-dev
set protocols bgp neighbor 192.168.60.32 peer-group homelab-dev

# Mgmt-plane peers from VLAN 40
set protocols bgp neighbor-group mgmt remote-as 65003
set protocols bgp neighbor 192.168.40.60 peer-group mgmt
set protocols bgp neighbor 192.168.40.61 peer-group mgmt
set protocols bgp neighbor 192.168.40.62 peer-group mgmt

commit
save
```

Mirror on bgp-02.

#### Verification

- [ ] `dig +short vault.homelab.internal @192.168.40.1` returns all three Vault IPs
- [ ] `dig +short homelab-prod-api.homelab.internal @192.168.40.1` returns `192.168.50.30`
- [ ] On bgp-01, `show ip bgp summary` shows BGP sessions in `Established` state for every cluster node
- [ ] On any homelab-prod node, `kubectl exec -n kube-system ds/cilium -- cilium bgp peers` shows two peers (bgp-01, bgp-02) Established
- [ ] Create a quick test Service with `type: LoadBalancer` and label `io.cilium/lb-pool: homelab-prod`, get an IP from the pool, `ping` that IP from your workstation. Delete the test service.
- [ ] Failover test: stop bgp-01, the LB IP stays reachable via bgp-02 within ~10 seconds. Restart bgp-01.

---

### Phase 2.2: Vault Kubernetes Auth Method

**Goal:** Workloads in any cluster authenticate to Vault by presenting their ServiceAccount JWT. Vault validates the JWT against the cluster's API and issues a Vault token with the policies bound to that role. This is *the* production pattern for K8s ↔ Vault integration.

> **Architecture decision:** Each cluster gets its own auth backend in Vault at `auth/kubernetes-<cluster>/`. This means a compromised JWT signing key on homelab-dev cannot grant access as homelab-prod workloads. Same blast-radius reasoning as separating hypervisors. Some homelabs share one auth backend across clusters — that conflates trust boundaries unnecessarily.

#### 2.2a — Create a TokenReview ServiceAccount on each cluster

Vault needs to call `/apis/authentication.k8s.io/v1/tokenreviews` to validate JWTs. That requires a ServiceAccount with the `system:auth-delegator` ClusterRole. Apply on each cluster (`kubectl --context homelab-prod`, then homelab-dev, then mgmt):

```yaml
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: vault-tokenreview
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: vault-tokenreview-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:auth-delegator
subjects:
  - kind: ServiceAccount
    name: vault-tokenreview
    namespace: kube-system
---
apiVersion: v1
kind: Secret
metadata:
  name: vault-tokenreview-token
  namespace: kube-system
  annotations:
    kubernetes.io/service-account.name: vault-tokenreview
type: kubernetes.io/service-account-token
```

#### 2.2b — Capture cluster info and configure Vault backend

For each cluster, gather three things:

```bash
# Run with the appropriate kubectl context
CLUSTER=homelab-prod   # repeat for homelab-dev, homelab-mgmt

K8S_HOST="https://$(kubectl get endpoints kubernetes -o jsonpath='{.subsets[0].addresses[0].ip}'):443"
K8S_CA="$(kubectl get secret vault-tokenreview-token -n kube-system -o jsonpath='{.data.ca\.crt}' | base64 -d)"
K8S_TOKEN="$(kubectl get secret vault-tokenreview-token -n kube-system -o jsonpath='{.data.token}' | base64 -d)"

# Enable per-cluster auth backend in Vault
bao auth enable -path="kubernetes-${CLUSTER}" kubernetes

# Configure the backend with cluster details
bao write "auth/kubernetes-${CLUSTER}/config" \
  kubernetes_host="${K8S_HOST}" \
  kubernetes_ca_cert="${K8S_CA}" \
  token_reviewer_jwt="${K8S_TOKEN}" \
  issuer="https://kubernetes.default.svc.cluster.local"
```

The `issuer` value matters with RKE2 — `kubectl get --raw /.well-known/openid-configuration | jq -r .issuer` from inside the cluster confirms the right value. RKE2 defaults differ from k3s; verify per cluster.

#### 2.2c — Define Vault policies and roles per consumer

The two consumers in Tier 2 are ESO and cert-manager. Create their policies first:

```bash
# ESO — needs to read application secrets per namespace
bao policy write eso-homelab-prod - <<EOF
path "secret/data/homelab-prod/*"   { capabilities = ["read"] }
path "secret/metadata/homelab-prod/*" { capabilities = ["read", "list"] }
EOF

bao policy write eso-homelab-dev - <<EOF
path "secret/data/homelab-dev/*"   { capabilities = ["read"] }
path "secret/metadata/homelab-dev/*" { capabilities = ["read", "list"] }
EOF

bao policy write eso-homelab-mgmt - <<EOF
path "secret/data/mgmt/*"   { capabilities = ["read"] }
path "secret/metadata/mgmt/*" { capabilities = ["read", "list"] }
EOF

> **Shared platform secrets (v5.1 fix):** some secrets are consumed by *every* cluster — the Cloudflare API token for the Let's Encrypt DNS-01 issuer (Phase 2.4c) and the Garage S3 credentials for backups. The per-cluster prefixes above cannot reach them, so each ESO policy additionally gets read on a shared `secret/platform/*` prefix. Add these two lines to **all three** `eso-*` policies:
>
> ```hcl
> path "secret/data/platform/*"     { capabilities = ["read"] }
> path "secret/metadata/platform/*" { capabilities = ["read", "list"] }
> ```
>
> Write shared secrets to `secret/platform/...` (e.g. `secret/platform/cert-manager/cloudflare`, `secret/platform/garage/harbor`) rather than under a single cluster's prefix.

# cert-manager — needs to sign certs from the internal PKI
bao policy write cert-manager - <<EOF
path "pki_int/sign/internal-services"   { capabilities = ["create", "update"] }
path "pki_int/issue/internal-services"  { capabilities = ["create", "update"] }
EOF
```

Bind ServiceAccounts to policies via roles:

```bash
# ESO role on homelab-prod — only the external-secrets/external-secrets ServiceAccount can use it
bao write auth/kubernetes-homelab-prod/role/eso \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=eso-homelab-prod \
  ttl=1h

# cert-manager role on homelab-prod
bao write auth/kubernetes-homelab-prod/role/cert-manager \
  bound_service_account_names=cert-manager \
  bound_service_account_namespaces=cert-manager \
  policies=cert-manager \
  ttl=1h

# Repeat for homelab-dev and homelab-mgmt with the appropriate policy bindings
```

#### Verification

- [ ] On each cluster, kubectl `system:auth-delegator` binding exists for `vault-tokenreview`
- [ ] `bao auth list` shows `kubernetes-homelab-prod/`, `kubernetes-homelab-dev/`, `kubernetes-homelab-mgmt/`
- [ ] Manual login test using a real pod's projected token:
  ```bash
  # From inside a pod running with the eso SA (once ESO is deployed in Phase 2.3, this confirms auth works)
  TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
  curl --cacert ca.crt --data "{\"role\":\"eso\",\"jwt\":\"${TOKEN}\"}" \
    https://vault.homelab.internal:8200/v1/auth/kubernetes-homelab-prod/login
  # Returns a client_token with the eso-homelab-prod policy attached
  ```

---

### Phase 2.3: External Secrets Operator (All Clusters)

**Goal:** ESO running in every cluster, authenticating to Vault via Kubernetes auth method, ready to materialize Vault KV secrets into K8s Secrets. From here forward, *no secret is ever committed to Git in any form* — encrypted or otherwise. Everything lives in Vault. *(v5.1: ESO talks to OpenBao through its standard HashiCorp Vault provider — validated upstream by the ESO project, no config differences.)*

#### 2.3a — Install ESO via Helm

Direct helm install for bootstrap (Flux takes over reconciliation in Phase 2.12):

```bash
# Repeat with each cluster context
kubectl --context homelab-prod create namespace external-secrets

helm --kube-context homelab-prod repo add external-secrets https://charts.external-secrets.io
helm --kube-context homelab-prod upgrade --install external-secrets \
  external-secrets/external-secrets \
  -n external-secrets \
  --version 0.10.x \
  --set installCRDs=true \
  --set serviceAccount.name=external-secrets
```

#### 2.3b — ClusterSecretStore pointing at Vault

```yaml
# Apply to each cluster, adjusting the path: kubernetes-homelab-prod vs kubernetes-homelab-dev etc.
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: vault-backend
spec:
  provider:
    vault:
      server: "https://vault.homelab.internal:8200"
      path: "secret"
      version: "v2"
      caProvider:
        type: ConfigMap
        name: homelab-root-ca
        namespace: external-secrets
        key: ca.crt
      auth:
        kubernetes:
          mountPath: "kubernetes-homelab-prod"   # cluster-specific
          role: "eso"
          serviceAccountRef:
            name: "external-secrets"
            namespace: "external-secrets"
```

The `homelab-root-ca` ConfigMap holds the Vault root CA cert from Tier 0. Pre-populate it on each cluster:

```bash
kubectl --context homelab-prod -n external-secrets create configmap homelab-root-ca \
  --from-file=ca.crt=<(pass show homelab/vault/root-ca-cert)
```

> **Why ClusterSecretStore not SecretStore:** Cluster-scoped resource means any namespace can reference it via ExternalSecret. Avoids per-namespace duplication. Acceptable because the policies are scoped *inside Vault* by path; ESO can only read what its policy allows regardless of which namespace asks.

#### 2.3c — Smoke test ESO

```bash
# Put a test secret in Vault
bao kv put secret/homelab-prod/eso-test username=alice password=test123

# Create an ExternalSecret CR pointing at it
cat <<EOF | kubectl --context homelab-prod apply -f -
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: eso-test
  namespace: default
spec:
  refreshInterval: 30s
  secretStoreRef:
    kind: ClusterSecretStore
    name: vault-backend
  target:
    name: eso-test-secret
  data:
    - secretKey: username
      remoteRef:
        key: homelab-prod/eso-test
        property: username
    - secretKey: password
      remoteRef:
        key: homelab-prod/eso-test
        property: password
EOF

# Verify the K8s Secret materialized
kubectl --context homelab-prod -n default get secret eso-test-secret -o jsonpath='{.data.username}' | base64 -d
# Returns: alice

# Cleanup
kubectl --context homelab-prod delete externalsecret eso-test
bao kv delete secret/homelab-prod/eso-test
```

#### Verification

- [ ] ESO pods Running on all three clusters
- [ ] `kubectl get clustersecretstore` returns `vault-backend` with `Ready: True`
- [ ] Smoke test passes on each cluster
- [ ] ESO logs show no `permission denied` from Vault (would indicate policy/role mismatch)

---

### Phase 2.4: cert-manager + Two Issuers

**Goal:** cert-manager installed on every cluster. Internal services get short-lived certs from Vault PKI. Public services get Let's Encrypt certs via Cloudflare DNS-01.

#### 2.4a — Install cert-manager

```bash
# Repeat per cluster
kubectl --context homelab-prod create namespace cert-manager

helm --kube-context homelab-prod repo add jetstack https://charts.jetstack.io
helm --kube-context homelab-prod upgrade --install cert-manager \
  jetstack/cert-manager \
  -n cert-manager \
  --version v1.15.x \
  --set installCRDs=true \
  --set serviceAccount.name=cert-manager
```

#### 2.4b — Vault PKI ClusterIssuer (internal services)

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: vault-pki
spec:
  vault:
    server: "https://vault.homelab.internal:8200"
    path: "pki_int/sign/internal-services"
    caBundle: |   # the homelab root CA cert, base64-encoded
      LS0tLS1CRUdJTi...
    auth:
      kubernetes:
        mountPath: "/v1/auth/kubernetes-homelab-prod"
        role: "cert-manager"
        serviceAccountRef:
          name: cert-manager
```

The `caBundle` is the base64-encoded contents of `~/homelab-root-ca.crt` (from Tier 0). Same on every cluster.

#### 2.4c — Let's Encrypt ClusterIssuer (public services via Cloudflare DNS-01)

Cloudflare API token stored in Vault, materialized via ESO:

```bash
# Store the Cloudflare API token in Vault (token scoped to Zone:DNS:Edit on your domain only)
bao kv put secret/platform/cert-manager/cloudflare api-token="<your-cloudflare-api-token>"
```

ExternalSecret to materialize it:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: cloudflare-api-token
  namespace: cert-manager
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: vault-backend
  target:
    name: cloudflare-api-token-secret
  data:
    - secretKey: api-token
      remoteRef:
        key: platform/cert-manager/cloudflare
        property: api-token
```

The ClusterIssuer itself:

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: you@yourdomain.com
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
      - dns01:
          cloudflare:
            apiTokenSecretRef:
              name: cloudflare-api-token-secret
              key: api-token
        selector:
          dnsZones:
            - yourdomain.com
```

#### Verification

- [ ] cert-manager pods Running on all three clusters
- [ ] `kubectl get clusterissuer` shows both `vault-pki` and `letsencrypt-prod` with `Ready: True`
- [ ] Test internal cert:
  ```yaml
  apiVersion: cert-manager.io/v1
  kind: Certificate
  metadata: { name: cert-test, namespace: default }
  spec:
    secretName: cert-test-tls
    issuerRef: { kind: ClusterIssuer, name: vault-pki }
    commonName: test.homelab.internal
    duration: 24h
    renewBefore: 8h
  ```
  After ~30 seconds: `kubectl get cert cert-test` shows `Ready: True`, the secret contains a cert chain rooted at the homelab root CA, expires in 24h.
- [ ] Delete test cert + secret

---

### Phase 2.5: Vault's Listener Cert Now Managed by cert-manager

**Goal:** Replace the manually-issued 30-day Vault listener cert from Phase 0.7d with cert-manager rotation. This closes the loop — Vault uses its own PKI, automated.

The challenge: cert-manager lives in Kubernetes; Vault lives outside Kubernetes. Two reasonable approaches:

1. **Pull approach (recommended):** A small wrapper script on each Vault VM runs every 12 hours via systemd timer. It reads a Certificate from a designated K8s namespace on homelab-prod via API, copies cert + key to `/etc/openbao/`, reloads Vault. cert-manager handles renewal; the script just copies.

2. **Push approach:** A K8s CronJob in homelab-prod issues a cert via direct Vault PKI API call (not cert-manager) and SCPs it onto each Vault VM. Bypasses cert-manager and reintroduces SSH-based automation, so the pull approach is cleaner.

Skipping the full implementation in this doc — it's a Tier 2 stretch item rather than a hard requirement. **Action:** Add a calendar reminder to manually rotate Vault's cert every 28 days until the automation is built. Or build the systemd timer + script and reference it from an ADR. Either way, the 30-day TTL means you have time.

> **Honest scope call:** I'm flagging this as a known TODO rather than building it inline because the implementation isn't novel and is exactly the kind of integration glue you'll want to write yourself. The architectural decision (pull vs push, where to run it) is documented; the code is left as exercise.

---

### Phase 2.6: Cilium Gateway API Resources

**Goal:** Each cluster has a Gateway resource that terminates TLS for inbound traffic, with HTTPRoutes mapping hostnames to backend Services. cert-manager auto-provisions certs to the Gateway's TLS listener.

#### 2.6a — GatewayClass

Cilium provides the GatewayClass automatically when Gateway API is enabled (set in Tier 1 Cilium config). Verify:

```bash
kubectl --context homelab-prod get gatewayclass
# Should show: cilium  cilium.io/gateway-controller
```

#### 2.6b — Gateway resource per cluster

Each cluster gets one shared Gateway that serves all internal HTTPS traffic. Define on homelab-prod:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: homelab-prod-gateway
  namespace: gateway-system
spec:
  gatewayClassName: cilium
  listeners:
    - name: https
      protocol: HTTPS
      port: 443
      hostname: "*.homelab-prod.homelab.internal"
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Secret
            name: homelab-prod-wildcard-tls
      allowedRoutes:
        namespaces:
          from: All
    - name: http
      protocol: HTTP
      port: 80
      hostname: "*.homelab-prod.homelab.internal"
      allowedRoutes:
        namespaces:
          from: All
```

> **Two things to get right here (v5.1 fixes):**
> 1. **Create the namespace first** — `kubectl create namespace gateway-system` on each cluster. Nothing else in the doc creates it.
> 2. **Kubernetes Secrets are namespaced.** The wildcard TLS Secret produced below lives in `gateway-system`, but the Gateway listener is the only thing that reads it there — that part is fine. What does *not* work is other namespaces (Harbor, Grafana, Keycloak) referencing `homelab-prod-wildcard-tls` / `mgmt-wildcard-tls` directly, which several later phases do. Those workloads sit behind the Gateway and should terminate TLS at it — drop the per-app `existingSecret`/`tls.secretName` references and route via `HTTPRoute` instead. If a specific app genuinely needs its own cert in its own namespace, give it its own short `Certificate` from the `vault-pki` ClusterIssuer rather than sharing the Gateway's.

Backing Certificate:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: homelab-prod-wildcard
  namespace: gateway-system
spec:
  secretName: homelab-prod-wildcard-tls
  issuerRef:
    kind: ClusterIssuer
    name: vault-pki
  commonName: "*.homelab-prod.homelab.internal"
  dnsNames:
    - "*.homelab-prod.homelab.internal"
  duration: 720h        # 30 days — wildcards are precious, give them more life than service certs
  renewBefore: 240h
```

> **24h for service-specific certs, 30d for wildcards:** Service-specific certs are easy to rotate (one app's cert at a time). Wildcards cover many services — a botched rotation breaks everything. Longer TTL trades faster recovery for less risk of routine churn. Document the tradeoff.

#### 2.6c — DNS for the cluster wildcard

Once the Gateway gets an LB IP from BGP, update VyOS with a wildcard:

```bash
# On bgp-01 and bgp-02 — assuming the Gateway gets 192.168.50.240
set system static-host-mapping host-name homelab-prod-gw.homelab.internal inet 192.168.50.240
```

VyOS doesn't natively serve wildcard DNS, so each consumer service needs a static A record. When you deploy `harbor.homelab-prod.homelab.internal`, add it to VyOS as `inet 192.168.50.240`. Inelegant but explicit — every hostname is documented and grep-able. If this grows beyond ~20 entries, time to deploy CoreDNS as a platform service.

Mirror Gateway resources to homelab-dev (`*.homelab-dev.homelab.internal`, LB pool `192.168.60.240-250`) and homelab-mgmt (`*.mgmt.homelab.internal`).

#### Verification

- [ ] `kubectl get gateway -A` on each cluster shows Gateway `Programmed: True`
- [ ] LB IP allocated (visible in Gateway `.status.addresses`)
- [ ] LB IP is pingable from workstation via BGP route
- [ ] TLS handshake against the Gateway returns a cert chained to the homelab root CA

---

### Phase 2.7: ExternalDNS

**Goal:** DNS records for Kubernetes Services, Gateway API HTTPRoutes, and Ingresses are created automatically. Users and tenants don't touch VyOS static host mappings. DNS for `*.apps.homelab.internal` is owned by a programmable backend, with VyOS forwarding to it.

> **Zone split (v5.1 fix):** earlier drafts used `homelab.local` for this programmable zone. That was wrong twice over: `.local` is reserved for mDNS (RFC 6762) and would collide on any Bonjour/Avahi network, and the Vault PKI role from Phase 0.7c only allows `homelab.internal`, so **no cert could ever be issued for a `.local` name**. The programmable zone is now `apps.homelab.internal` — a subdomain of the existing zone, covered by the PKI role's `allow_subdomains=true`, and cleanly delegated: VyOS owns static `*.homelab.internal` platform records, CoreDNS owns everything under `apps.`.

> **Why this matters:** Without ExternalDNS, every new service is a ticket — someone updates VyOS static host mappings, commits, deploys. That doesn't scale to multi-tenant. When the friend creates a KServe InferenceService in Tier 5, the DNS record must appear without an admin in the loop. ExternalDNS watches Gateway API and Service resources and writes records to a backend it owns.

#### 2.7a — Stand up a CoreDNS-with-etcd authority

CoreDNS is in every Kubernetes cluster as the in-cluster DNS. For *homelab-wide* DNS that VyOS forwards to, a separate CoreDNS deployment with a writable backend is needed. The `etcd` plugin makes CoreDNS read records from etcd that ExternalDNS writes to.

Deploy on homelab-mgmt (3 replicas of CoreDNS, 3 replicas of etcd, both in `coredns-homelab` namespace):

```yaml
# Helm values for CoreDNS
servers:
  - zones:
      - zone: apps.homelab.internal
    port: 53
    plugins:
      - name: errors
      - name: cache
        parameters: 30
      - name: etcd
        configBlock: |
          path /skydns
          endpoint http://etcd.coredns-homelab.svc.cluster.local:2379
      - name: forward
        parameters: ". /etc/resolv.conf"
      - name: prometheus
        parameters: 0.0.0.0:9153
```

Expose via `LoadBalancer` from `homelab-mgmt-lb-pool`. Assign `192.168.40.245` and `192.168.40.246` (two LBs for HA, both listening UDP/TCP 53).

The etcd cluster here is dedicated to CoreDNS — NOT the Kubernetes etcd, NOT shared with anything else. Bitnami's etcd chart works fine; 3 replicas with PVCs on NFS.

#### 2.7b — VyOS forwarding configuration

On bgp-01 and bgp-02:

```
set service dns forwarding domain apps.homelab.internal server 192.168.40.245
set service dns forwarding domain apps.homelab.internal server 192.168.40.246
```

VyOS now forwards any query for `*.apps.homelab.internal` to the in-cluster CoreDNS, falling back to upstream resolvers for everything else. Test from a non-cluster host: `dig +short anything.apps.homelab.internal @bgp-01.homelab.internal`.

#### 2.7c — Install ExternalDNS per workload cluster

One ExternalDNS deployment per workload cluster (homelab-prod, homelab-dev), each watching only its own resources. The `txtOwnerId` tag prevents two ExternalDNS instances from fighting over the same records.

```yaml
# homelab-gitops/apps/external-dns/values.yaml
provider: coredns
env:
  - name: ETCD_URLS
    value: "http://etcd.coredns-homelab.svc.cluster.local:2379"
sources:
  - service
  - gateway-httproute
  - ingress
policy: sync  # create, update, AND delete
txtOwnerId: homelab-prod  # or homelab-dev
txtPrefix: "external-dns-"
domainFilters:
  - apps.homelab.internal
interval: 30s
```

`policy: sync` is important: ExternalDNS deletes records when their owning Services/Routes are deleted. Without it, you accumulate orphaned records forever.

#### 2.7d — Tenant usage pattern

ExternalDNS reads hostnames from Gateway API `hostnames` directly:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: iris-classifier
  namespace: mlops-user-abc123
spec:
  hostnames:
    - iris-classifier.abc123.kserve.apps.homelab.internal
  parentRefs:
    - name: kserve-gateway
      namespace: kserve
```

Create the HTTPRoute → DNS record appears in CoreDNS etcd within ~30s → resolution works immediately after the CoreDNS cache TTL (also 30s).

For Service resources without a Gateway, the annotation pattern:

```yaml
metadata:
  annotations:
    external-dns.alpha.kubernetes.io/hostname: my-service.apps.homelab.internal
```

#### 2.7e — Split: keep platform DNS static, tenant DNS programmatic

Platform service records (vault, harbor, flux, grafana, keycloak, mlflow, etc.) **stay** on VyOS as static host mappings. They're hand-curated, change rarely, and you don't want them dependent on the cluster being up to resolve "where is Vault?" Tenant records (mlops-*, kserve-*, *.user namespaces) live in CoreDNS, programmatically managed.

This split avoids the chicken-and-egg of "Cluster is down because Vault is down, Vault is down because cert-manager can't reach DNS, DNS is down because cluster is down."

#### Verification

- [ ] CoreDNS responding on 192.168.40.245:53 for `apps.homelab.internal`: `dig +short test.apps.homelab.internal @192.168.40.245` returns NXDOMAIN (no records yet, but not a timeout)
- [ ] VyOS forwarding `*.apps.homelab.internal` to CoreDNS (test from workstation: `dig +short anything.apps.homelab.internal`)
- [ ] ExternalDNS deployed on both workload clusters, healthy
- [ ] Create a test HTTPRoute with `hostnames: [test-record.apps.homelab.internal]` → record appears in CoreDNS within 60s
- [ ] Delete the HTTPRoute → record disappears within 60s
- [ ] Two clusters' ExternalDNS don't conflict: verify with TXT records (`dig TXT external-dns-test-record.apps.homelab.internal`)
- [ ] Platform services (`vault.homelab.internal`, `harbor.homelab-prod.homelab.internal`) still resolve correctly through the static VyOS path

---

### Phase 2.8: CloudNativePG Operator (homelab-prod)

**Goal:** The Postgres operator installed on homelab-prod. From this point onward, every app needing Postgres gets a `Cluster` CR — no single-pod Postgres deployments anywhere in v5.

#### 2.8a — Install via Helm

```bash
kubectl --context homelab-prod create namespace cnpg-system

helm --kube-context homelab-prod repo add cnpg https://cloudnative-pg.github.io/charts
helm --kube-context homelab-prod upgrade --install cnpg \
  cnpg/cloudnative-pg \
  -n cnpg-system \
  --version 0.22.x
```

#### 2.8b — Backup destination (Garage S3)

CloudNativePG ships native S3 backup support. Store the Garage credentials for it:

```bash
bao kv put secret/homelab-prod/cnpg/backup-s3 \
  access-key="<garage-cnpg-key>" \
  secret-key="<garage-cnpg-secret>"
```

Materialize via ExternalSecret into the namespace each `Cluster` lives in (each app's database gets backups to its own prefix in the `harbor-registry` bucket — or a dedicated `postgres-backups` bucket, decide and stay consistent).

> **Defense-relevant note:** CloudNativePG supports continuous archiving (WAL shipping) on top of base backups. Configure both. RPO of seconds, RTO of minutes for any Postgres workload, demonstrated and tested. That's a real production capability.

#### Verification

- [ ] `kubectl get pods -n cnpg-system` shows operator Running
- [ ] CRDs installed: `kubectl get crd | grep cnpg` shows `Clusters`, `Backups`, `ScheduledBackups`, `Poolers`

---

### Phase 2.9: Harbor on homelab-prod

**Goal:** Harbor operational at `harbor.homelab-prod.homelab.internal`, using CloudNativePG for its database, Garage for blob storage, with Cosign signing keys stored in Vault Transit (not on disk).

#### 2.9a — Postgres cluster for Harbor

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: harbor-postgres
  namespace: harbor
spec:
  instances: 2                  # primary + standby
  storage:
    size: 20Gi
    storageClass: nfs-csi      # whatever you named the NFS storage class in Tier 1
  backup:
    barmanObjectStore:
      destinationPath: s3://harbor-registry/postgres-backups
      endpointURL: http://garage-01.homelab.internal:3900
      s3Credentials:
        accessKeyId:
          name: garage-cnpg-creds
          key: access-key
        secretAccessKey:
          name: garage-cnpg-creds
          key: secret-key
    retentionPolicy: "14d"
```

#### 2.9b — Harbor values (Helm)

```yaml
# harbor-values.yaml — committed to homelab-gitops
expose:
  type: ingress
  tls:
    enabled: true
    certSource: secret
    secret:
      secretName: homelab-prod-wildcard-tls   # the Gateway wildcard from Phase 2.6
  ingress:
    hosts:
      core: harbor.homelab-prod.homelab.internal
    className: cilium

externalURL: https://harbor.homelab-prod.homelab.internal

# External Postgres via CloudNativePG
database:
  type: external
  external:
    host: harbor-postgres-rw.harbor.svc
    port: "5432"
    coreDatabase: registry
    username: harbor
    existingSecret: harbor-postgres-app   # CNPG auto-creates this secret

# External storage via Garage S3
persistence:
  imageChartStorage:
    type: s3
    s3:
      region: garage
      bucket: harbor-registry
      regionendpoint: http://garage-01.homelab.internal:3900
      existingSecret: garage-harbor-creds
      v4auth: true

# Trivy integrated for image scanning
trivy:
  enabled: true

# Disable bundled chartmuseum (legacy, deprecated)
chartmuseum:
  enabled: false

# Disable bundled redis — for v5 it's fine to leave it on
redis:
  type: internal
```

#### 2.9c — Cosign signing keys in Vault Transit

Already set up `transit/keys/cosign-harbor` in Tier 0 Phase 0.8. Harbor doesn't natively support Vault Transit for signing yet, so the integration pattern is:

1. CI pipelines (in Tier 4) call `cosign sign --key hashivault://transit/keys/cosign-harbor` to sign images using the in-Vault key *(cosign's `hashivault://` KMS provider is API-compatible with OpenBao and reads `VAULT_ADDR`/`VAULT_TOKEN`)*
2. The public key is published to a well-known location for verification
3. Kyverno verifies signatures using the published public key (Phase 2.14)

Export the public key for verification:

```bash
bao read -field=public_key transit/keys/cosign-harbor/public_key/1 > ~/cosign-harbor.pub
# Store in a ConfigMap on each cluster that Kyverno can reference.
# ORDERING (v5.1): the `kyverno` namespace doesn't exist until Phase 2.14 — run these three
# commands there, not here. Export the key now; create the ConfigMaps after Kyverno installs.
# All THREE clusters need it (the signature ClusterPolicy applies cluster-wide everywhere).
kubectl --context homelab-prod -n kyverno create configmap cosign-public-keys \
  --from-file=harbor.pub=~/cosign-harbor.pub
# Mirror to homelab-dev and homelab-mgmt
kubectl --context homelab-dev -n kyverno create configmap cosign-public-keys \
  --from-file=harbor.pub=~/cosign-harbor.pub
kubectl --context homelab-mgmt -n kyverno create configmap cosign-public-keys \
  --from-file=harbor.pub=~/cosign-harbor.pub
```

> **Why the key never touches disk on signers:** Anyone signing images authenticates to Vault (via AppRole in CI), invokes the signing operation server-side, gets back a signature. The private key never leaves Vault. If a CI runner is compromised, the attacker can sign while they have the AppRole token (mitigated by short TTLs), but cannot exfiltrate the key for offline use. The defense equivalent uses an HSM-backed Transit key — same pattern, hardware-rooted trust.

#### Verification

- [ ] Harbor UI loads at `https://harbor.homelab-prod.homelab.internal`
- [ ] Login with admin credentials (auto-generated by Helm, stored in `harbor` namespace; will OIDC-integrate to Keycloak in Tier 3)
- [ ] Create a project, push a test image: `docker push harbor.homelab-prod.homelab.internal/test/hello:v1`
- [ ] Pull from a fresh node: `docker pull harbor.homelab-prod.homelab.internal/test/hello:v1`
- [ ] Sign with Cosign using the Vault Transit key:
  ```bash
  export VAULT_ADDR=https://vault.homelab.internal:8200
  export VAULT_TOKEN=...
  cosign sign --key hashivault://transit/keys/cosign-harbor \
    harbor.homelab-prod.homelab.internal/test/hello:v1
  ```
- [ ] Verify signature: `cosign verify --key ~/cosign-harbor.pub harbor.homelab-prod.homelab.internal/test/hello:v1`
- [ ] CloudNativePG backup runs successfully and a base backup appears in Garage

---

### Phase 2.10: Air-Gap Pivot for Workload Clusters

**Goal:** homelab-prod and homelab-dev stop pulling images from Docker Hub, Quay, gcr.io, etc. All workload image pulls go through Harbor as a pull-through proxy or replicated registry. Mgmt-plane retains upstream access for observability bootstrap.

#### 2.10a — Configure Harbor proxy projects

In Harbor UI, create proxy-cache projects for each upstream you regularly pull from:

- `dockerhub` → proxy for `docker.io`
- `quay` → proxy for `quay.io`
- `ghcr` → proxy for `ghcr.io`
- `gcr` → proxy for `gcr.io`
- `registryk8s` → proxy for `registry.k8s.io`

Now `harbor.homelab-prod.homelab.internal/dockerhub/library/nginx:latest` transparently fetches and caches `docker.io/library/nginx:latest`.

#### 2.10b — RKE2 containerd registry mirror config

On each homelab-prod and homelab-dev node, write `/etc/rancher/rke2/registries.yaml`:

```yaml
mirrors:
  docker.io:
    endpoint:
      - "https://harbor.homelab-prod.homelab.internal/v2/dockerhub"
  quay.io:
    endpoint:
      - "https://harbor.homelab-prod.homelab.internal/v2/quay"
  ghcr.io:
    endpoint:
      - "https://harbor.homelab-prod.homelab.internal/v2/ghcr"
  gcr.io:
    endpoint:
      - "https://harbor.homelab-prod.homelab.internal/v2/gcr"
  registry.k8s.io:
    endpoint:
      - "https://harbor.homelab-prod.homelab.internal/v2/registryk8s"

configs:
  "harbor.homelab-prod.homelab.internal":
    tls:
      ca_file: /etc/ssl/certs/homelab-root-ca.crt
    # No credentials needed for public read on proxy projects
    # Auth required only for pushing — that's a CI concern, not a node concern
```

Restart rke2-server / rke2-agent on each node to pick up the new config. Use the Ansible role to apply the file and restart in rolling order (one node at a time, wait for it to come back Ready).

> **Critical subtlety — egress firewall enforcement:** The registries.yaml config makes nodes *prefer* Harbor, but doesn't *prevent* direct upstream pulls if something hardcodes a registry URL bypassing containerd. To truly enforce air-gap, add egress firewall rules at VyOS:
>
> ```bash
> # On bgp-01 and bgp-02, deny VLAN 50 and VLAN 60 from initiating outbound to known registries
> # (homelab-mgmt VLAN 40 keeps full egress for now)
> set firewall name VLAN50-EGRESS rule 100 action drop
> set firewall name VLAN50-EGRESS rule 100 description "Drop docker.io egress (force Harbor)"
> set firewall name VLAN50-EGRESS rule 100 destination address 0.0.0.0/0  # broad, refine with FQDN-resolved IPs
> ```
>
> In practice, FQDN-based blocking in VyOS is fiddly. The defense-grade way is an egress proxy (Squid) on VyOS allow-listing only Harbor. **For Tier 2, document the gap. Implement explicit FQDN-resolved blocks for `docker.io`, `quay.io`, `ghcr.io`, `gcr.io`, `registry.k8s.io` in a Tier 2 follow-up.** The pull-through configuration is the first step; the firewall enforcement is the verification.

#### Verification

- [ ] On a homelab-prod node: `crictl pull docker.io/library/nginx:1.27` succeeds; check Harbor UI — the `dockerhub/library/nginx` image now exists in Harbor
- [ ] On the same node: try to `curl https://registry-1.docker.io` directly — should fail once firewall enforcement is added (Tier 2 follow-up)
- [ ] Mgmt-plane nodes are NOT configured with `registries.yaml` mirrors — they pull directly upstream

---

### Phase 2.11: Zarf — Air-Gapped Package Delivery *(v5)*

**Goal:** Stand up Zarf so an entire application (images + manifests + Helm charts, even the CNI) can be packaged into one tarball and deployed into a cluster that has never touched the internet. This complements the Harbor mirror from 2.10: Harbor answers "pull images offline," Zarf answers "deliver a whole app and its dependencies offline."

> **Why both:** The Harbor mirror keeps a connected-ish cluster fed. Zarf is the tool for true disconnected delivery — the DoD/Platform One pattern — and it's the backbone of the ephemeral air-gap drills (see the Ephemeral Environments section). Practicing it here on a stable cluster means the drills exercise the workflow, not debug it.

#### 2.11a — Install the Zarf CLI + init package

```bash
brew install zarf   # or the release binary; pin the version
zarf version

# Init Zarf against Harbor as the in-cluster registry seed
zarf init --confirm --registry-url harbor.homelab-prod.homelab.internal
```

#### 2.11b — Author a package (`zarf.yaml`)

Zarf resolves and bundles the images referenced by the manifests/charts automatically:

```yaml
kind: ZarfPackageConfig
metadata:
  name: hello-otel
  version: "1.4.2"
components:
  - name: hello-otel
    required: true
    manifests:
      - name: app
        namespace: hello
        files: [manifests/hello-otel.yaml]
    images:
      - harbor.homelab-prod.homelab.internal/apps/hello-otel:v1.4.2
```

```bash
zarf package create . --confirm   # -> zarf-package-hello-otel-amd64-1.4.2.tar.zst
```

#### 2.11c — Deploy into a disconnected cluster

```bash
# The tarball is the ONLY input — no internet
zarf package deploy zarf-package-hello-otel-amd64-1.4.2.tar.zst --confirm
```

#### 2.11d — How Zarf and Flux coexist

**Zarf gets bits into the air-gap; Flux keeps them reconciled once there.** For the ephemeral air-gap clusters, the package bundles Cilium + Flux + the app; after one `zarf package deploy` the disconnected cluster is fully GitOps-managed from a local Forgejo mirror.

#### Verification

- [ ] `zarf version` works; init package stored off-internet (Garage or USB)
- [ ] `zarf package create` embeds images (`zarf package inspect <tar>` lists them)
- [ ] With egress blocked, `zarf package deploy` brings the app up with zero internet pulls
- [ ] Embedded image digests match the signed Harbor tags

---

### Phase 2.12: Flux on Workload Clusters (homelab-prod, homelab-dev)

**Goal:** Flux installed on both RKE2 workload clusters, each reconciling its own path in `homelab-gitops`, GitHub connected, ready for workloads (Tier 4) with Flagger progressive delivery.

> **v5 (ADR-002):** This replaces v4's ArgoCD-on-homelab-prod. There is no central UI driving remote clusters; each cluster runs its own Flux and reconciles its own slice of the repo. Cross-cluster visibility comes from a single read-only Flux UI (Weave GitOps or Capacitor) on homelab-mgmt, wired to Keycloak OIDC in Phase 3.14.

#### 2.12a — Bootstrap Flux on homelab-prod

```bash
flux --context homelab-prod bootstrap github \
  --owner=yourorg \
  --repository=homelab-gitops \
  --branch=main \
  --path=clusters/homelab-prod \
  --personal=false \
  --components-extra=image-reflector-controller,image-automation-controller
```

The image controllers let part of the release loop live in-cluster: Flux watches Harbor for new signed tags and writes the bump back to Git, giving you the "new tag → commit" flow ApplicationSets + Renovate gave in v4.

#### 2.12b — Bootstrap Flux on homelab-dev

Identical, with `--path=clusters/homelab-dev` and `--context homelab-dev`.

#### 2.12c — Repo structure for multi-cluster + multi-env

Flux's answer to ApplicationSets is plain Kustomize composition: a shared `apps/<app>/base`, per-env overlays, and one `Kustomization` per cluster pointing at the right overlay.

```
homelab-gitops/
├── clusters/
│   ├── homelab-prod/flux-system/        # bootstrap (GitRepository + Kustomization)
│   ├── homelab-prod/apps.yaml           # Kustomization -> apps/<app>/overlays/prod
│   ├── homelab-dev/flux-system/
│   └── homelab-dev/apps.yaml            # Kustomization -> apps/<app>/overlays/dev
└── apps/
    └── hello-otel/{base,overlays/{dev,staging,prod}}
```

#### Verification

- [ ] `flux --context homelab-prod get sources git` shows the repo `Ready`
- [ ] `flux --context homelab-prod get kustomizations` shows bootstrap kustomizations `Ready`
- [ ] Same on homelab-dev
- [ ] A commit under `clusters/homelab-prod/` reconciles within ~1 min
- [ ] No ArgoCD anywhere (`kubectl get ns argocd` is NotFound on every cluster)

---

### Phase 2.13: Flux on Mgmt-Plane (Talos)

**Goal:** Flux installed on the Talos homelab-mgmt cluster, managing the observability and identity stacks (Tier 3).

```bash
flux --context homelab-mgmt bootstrap github \
  --owner=yourorg \
  --repository=homelab-gitops \
  --branch=main \
  --path=clusters/homelab-mgmt \
  --personal=false \
  --components-extra=image-reflector-controller,image-automation-controller
```

> **No special-casing for Talos:** Flux runs as ordinary in-cluster workloads, so it's indifferent to the underlying OS being Talos. The only difference from the workload clusters is intent — homelab-mgmt reconciles platform services (Prometheus, Loki, Tempo, Grafana, Keycloak, the Flux UI), not application workloads.

#### Verification

- [ ] `flux --context homelab-mgmt get sources git` shows the repo `Ready`
- [ ] `flux --context homelab-mgmt get kustomizations` shows bootstrap kustomizations `Ready`
- [ ] A commit to `clusters/homelab-mgmt/` reconciles within ~1 min

---

### Phase 2.14: Kyverno in Audit Mode

**Goal:** Kyverno installed on all clusters with a seed set of baseline policies. All policies run in `audit` mode for Tier 2 — they log violations but don't block. Switch to `enforce` happens in Tier 4 once workloads are stable.

#### 2.14a — Install

```bash
# Repeat per cluster
kubectl --context homelab-prod create namespace kyverno
helm --kube-context homelab-prod repo add kyverno https://kyverno.github.io/kyverno/
helm --kube-context homelab-prod upgrade --install kyverno kyverno/kyverno \
  -n kyverno \
  --version 3.2.x \
  --set replicaCount=3   # HA on homelab-prod + mgmt; homelab-dev can run 1
```

#### 2.14b — Seed policies (committed to gitops repo)

A starter set, all in audit mode:

1. **`require-image-signature`** — verify images pulled from `harbor.homelab-prod.homelab.internal` are signed by the Cosign key. References the `cosign-public-keys` ConfigMap from Phase 2.9c.
2. **`disallow-default-namespace`** — workloads must explicitly choose a namespace
3. **`require-resource-requests`** — every container declares CPU/memory requests
4. **`require-non-root`** — containers run as non-root by default
5. **`disallow-privileged-containers`** — no privileged: true except in explicit exception namespaces (kube-system, cilium, etc.)
6. **`require-pod-security-standards-restricted`** — pods comply with PSS restricted profile

Example signature verification policy:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-image-signature
spec:
  validationFailureAction: Audit   # Switch to Enforce in Tier 4
  webhookTimeoutSeconds: 30
  background: false
  rules:
    - name: verify-harbor-signatures
      match:
        any:
          - resources:
              kinds:
                - Pod
      verifyImages:
        - imageReferences:
            - "harbor.homelab-prod.homelab.internal/*"
          attestors:
            - count: 1
              entries:
                - keys:
                    publicKeys: |-
                      -----BEGIN PUBLIC KEY-----
                      ... (contents of ~/cosign-harbor.pub)
                      -----END PUBLIC KEY-----
```

#### Verification

- [ ] `kubectl get clusterpolicies` shows all seed policies `Ready: True`
- [ ] Deploy a non-compliant pod (e.g., privileged: true) — kubectl creates it successfully but Kyverno logs an audit violation
- [ ] Push an unsigned image to Harbor and deploy it — Kyverno audit log shows signature verification failure (but pod runs in audit mode)
- [ ] PolicyReport CRs populated: `kubectl get policyreport -A`

---

### Phase 2.15: Renovate Bot via GitHub App

**Goal:** Renovate automatically opens PRs against the gitops repo when new versions of charts, images, or terraform modules are available. Runs as a CronJob in homelab-prod. Authenticates via a GitHub App (not a personal PAT).

#### 2.15a — Create the GitHub App

In GitHub, create a new App with permissions:
- Repository contents: Read & write
- Pull requests: Read & write
- Workflows: Read & write
- Metadata: Read

Install on your `homelab-gitops` repo. Download the private key.

#### 2.15b — Store credentials in Vault

```bash
bao kv put secret/homelab-prod/renovate/github-app \
  app-id="<your-app-id>" \
  installation-id="<your-installation-id>" \
  private-key="$(cat ~/Downloads/renovate-bot.private-key.pem)"
```

#### 2.15c — Renovate config (`renovate.json` in gitops repo)

```json
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": [
    "config:recommended",
    ":semanticCommits",
    "schedule:weekly"
  ],
  "kubernetes": {
    "fileMatch": ["clusters/.+\\.ya?ml$"]
  },
  "helm-values": {
    "fileMatch": ["clusters/.+/values\\.ya?ml$"]
  },
  "flux": {
    "fileMatch": ["clusters/.+\\.ya?ml$"]
  },
  "vulnerabilityAlerts": {
    "enabled": true
  },
  "packageRules": [
    {
      "matchUpdateTypes": ["minor", "patch"],
      "automerge": false,
      "labels": ["renovate", "non-major"]
    },
    {
      "matchUpdateTypes": ["major"],
      "automerge": false,
      "labels": ["renovate", "major", "review-carefully"]
    }
  ]
}
```

#### 2.15d — CronJob deployment

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: renovate
  namespace: renovate
spec:
  schedule: "0 6 * * *"   # 6am daily
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: renovate
          containers:
            - name: renovate
              image: harbor.homelab-prod.homelab.internal/dockerhub/renovate/renovate:latest
              env:
                - name: RENOVATE_PLATFORM
                  value: github
                - name: RENOVATE_REPOSITORIES
                  value: yourorg/homelab-gitops
                - name: RENOVATE_GITHUB_APP_ID
                  valueFrom: { secretKeyRef: { name: renovate-github-app, key: app-id } }
                - name: RENOVATE_GITHUB_APP_KEY
                  valueFrom: { secretKeyRef: { name: renovate-github-app, key: private-key } }
          restartPolicy: OnFailure
```

The `renovate-github-app` secret is materialized via ESO from Vault.

#### Verification

- [ ] CronJob exists and the first scheduled run completes successfully
- [ ] Renovate opens its first PR against `homelab-gitops` (typically the "Dependency Dashboard" issue + initial onboarding PR)
- [ ] No PAT or long-lived credential anywhere outside of Vault

---

### Phase 2.16: Supply Chain Attestation — SBOMs via Syft + Cosign

**Goal:** Every image pushed to Harbor carries an SBOM (Software Bill of Materials) as a signed OCI attestation. Kyverno verifies SBOM presence at admission alongside image signatures.

> **Why this matters:** Image signing answers "is this image authentic?" SBOM attestation answers "what's actually inside this image?" For supply-chain audit — and any defense customer — both are needed. Building it in now is one CI step plus one policy line; bolting it on later means amending dozens of charts and pipelines.

#### 2.16a — Add Syft to image builds

The CI pipeline (Tier 4.6 ARC + 4.7) is where images get built. The pattern extends naturally:

```yaml
# .gitea/workflows/build-image.yaml (or .github/workflows/...)
- name: Build image
  uses: docker/build-push-action@v5
  with:
    push: true
    tags: harbor.homelab-prod.homelab.internal/myapp:${{ github.sha }}

- name: Generate SBOM with Syft
  uses: anchore/syft-action@v1
  with:
    image: harbor.homelab-prod.homelab.internal/myapp:${{ github.sha }}
    format: spdx-json
    output-file: sbom.spdx.json

- name: Sign image with Cosign + Vault Transit
  run: |
    cosign sign --key 'hashivault://transit/keys/cosign-harbor' \
      harbor.homelab-prod.homelab.internal/myapp:${{ github.sha }}

- name: Attach + sign SBOM attestation
  run: |
    cosign attest \
      --predicate sbom.spdx.json \
      --type spdxjson \
      --key 'hashivault://transit/keys/cosign-harbor' \
      harbor.homelab-prod.homelab.internal/myapp:${{ github.sha }}
```

The Cosign signing key lives in Vault Transit (already established in Tier 0.8). It never touches disk.

#### 2.16b — Kyverno policy: verify image AND SBOM at admission

Extend the existing image signature verification policy to also require an SBOM attestation:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-image-and-sbom
spec:
  validationFailureAction: Audit   # Audit during rollout, Enforce after 2 weeks
  webhookTimeoutSeconds: 30
  rules:
    - name: verify-cosign-signature
      match:
        any:
          - resources:
              kinds: [Pod]
      verifyImages:
        - imageReferences:
            - "harbor.homelab-prod.homelab.internal/*"
          attestors:
            - count: 1
              entries:
                - keys:
                    publicKeys: |-
                      <PEM from Vault Transit public key>
    - name: verify-sbom-attestation
      match:
        any:
          - resources:
              kinds: [Pod]
      verifyImages:
        - imageReferences:
            - "harbor.homelab-prod.homelab.internal/*"
          attestations:
            - type: spdxjson
              attestors:
                - count: 1
                  entries:
                    - keys:
                        publicKeys: |-
                          <same PEM>
              conditions:
                - all:
                    - key: "{{ creationInfo.created }}"
                      operator: GreaterThanOrEquals
                      value: "2026-01-01T00:00:00Z"
```

The `conditions` block on the SBOM attestation lets you reject ancient SBOMs even if signed correctly.

#### 2.16c — Harbor SBOM integration

Harbor (v2.10+) can ingest and surface SBOMs. Configure Harbor to recognize OCI referrer artifacts:

- Harbor UI → Administration → Interrogation Services
- Enable Trivy scanner (already on by default in 2.10+)
- Enable SBOM generation in repository settings
- Per-repository "SBOM generation" toggle for legacy repos that don't push their own

Harbor will display the SBOM contents per image in the UI and let you query "which images contain log4j 2.x?"

#### 2.16d — Rollout pattern

Two-week soft launch:

1. **Day 0:** Deploy the policy in `Audit` mode. Existing pods continue to work; logs show which images lack SBOM attestations.
2. **Days 1–14:** Rebuild every image you control through the new pipeline. Watch the Audit warnings drop.
3. **Day 14:** Flip to `Enforce`. New pods without signed SBOMs are rejected.

A few categories of images won't have SBOMs (third-party Helm chart sidecars, upstream operator images). For those, add a Kyverno exemption list keyed on image prefix — but document each exemption with an ADR.

#### Verification

- [ ] One image rebuilt through the new pipeline; `cosign tree harbor.homelab-prod.homelab.internal/myapp:<sha>` shows both `signature` and `attestation` references
- [ ] `cosign verify-attestation --key hashivault://transit/keys/cosign-harbor --type spdxjson harbor.homelab-prod.homelab.internal/myapp:<sha>` succeeds
- [ ] Kyverno policy in Audit mode logs SBOM-missing for older images
- [ ] After cutover to Enforce: a pod referencing a deliberately-unsigned image is rejected at admission with the SBOM-related message
- [ ] Harbor UI displays SBOM data for the test image
- [ ] Exemption list documented as an ADR in `homelab-gitops/docs/adr/`

---

### Phase 2.17: Tier 2 Verification Gate

**Tier 2 is complete when every item below passes.**

#### Network & DNS

- [ ] BGP sessions Established between every cluster node and both VyOS routers
- [ ] LB IP allocation works via `io.cilium/lb-pool` label
- [ ] Wildcard internal DNS works: `dig +short <anything>.homelab-prod.homelab.internal` returns expected IPs
- [ ] BGP failover test: stop bgp-01, all LB IPs remain reachable within 10s
- [ ] CoreDNS authoritative for `apps.homelab.internal`, reachable on `192.168.40.245`
- [ ] VyOS forwards `*.apps.homelab.internal` queries to CoreDNS (test from non-cluster host)
- [ ] ExternalDNS creates DNS records for new HTTPRoutes within 60s
- [ ] ExternalDNS deletes records when HTTPRoute is deleted (`policy: sync` working)

#### Vault integration

- [ ] Three per-cluster Kubernetes auth backends in Vault
- [ ] ESO running on all clusters, ClusterSecretStore `Ready` everywhere
- [ ] Smoke test: ExternalSecret materializes a KV value from Vault into a K8s Secret on each cluster

#### Certificates

- [ ] cert-manager running on all clusters
- [ ] Both ClusterIssuers (`vault-pki`, `letsencrypt-prod`) `Ready`
- [ ] Internal cert smoke test passes — 24h TTL cert issued, renewed before expiry
- [ ] Vault's own listener cert rotation documented (manual until automated; calendar reminder set)

#### Gateway API

- [ ] Cilium GatewayClass available
- [ ] Per-cluster Gateway resources Programmed and serving traffic on wildcard TLS

#### Platform services

- [ ] CloudNativePG operator running on homelab-prod
- [ ] Harbor at `https://harbor.homelab-prod.homelab.internal` — login works, push/pull works, Trivy scanning active, CNPG backups landing in Garage
- [ ] Cosign signing works via Vault Transit key, signatures verifiable with the published public key
- [ ] Syft generates SBOM in CI; `cosign tree <image>` shows both signature and SBOM attestation
- [ ] Kyverno policy in Audit mode logs SBOM-missing for legacy images; rebuilt images pass
- [ ] Harbor UI displays SBOM data per image

#### Air-gap pivot

- [ ] homelab-prod and homelab-dev nodes have `/etc/rancher/rke2/registries.yaml` configured
- [ ] Pulling `docker.io/...` from any workload node transparently routes through Harbor and caches
- [ ] Mgmt-plane nodes still pull upstream directly (no registries.yaml)
- [ ] (Tier 2 follow-up task documented: VyOS egress firewall to enforce, not just prefer)

#### GitOps

- [ ] Flux bootstrapped on homelab-prod and homelab-dev, each reconciling its own path; repos connected
- [ ] Flux on homelab-mgmt reconciling from gitops repo
- [ ] App-of-apps structure exists in the repo (empty apps acceptable; Tier 4 fills in)

#### Policy & dependencies

- [ ] Kyverno on all clusters with 6 seed policies in audit mode
- [ ] PolicyReports populated for at least one synthetic violation per policy (sanity-check that each rule fires)
- [ ] Renovate CronJob running, first PR opened

#### Hygiene

- [ ] No credentials in any Git-committed file (grep verified across both gitops and ansible repos)
- [ ] All workstation-side credentials live in `pass` only
- [ ] Vault audit log shows authentication events from ESO, cert-manager, Cosign signing, and Renovate (when it runs)

When every item passes: **Tier 2 is complete.** The platform is real. From here, Tier 3 layers observability and identity, then Tier 4 brings actual workloads to life on top of everything built so far.
