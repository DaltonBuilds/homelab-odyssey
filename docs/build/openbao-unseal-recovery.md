# OpenBao — auto-unseal failure and recovery

Tracked by [HOMELAB-49](https://daltonbuilds.youtrack.cloud/issue/HOMELAB-49). Applies from 2026-11-08, when the cluster moved from Shamir to the GCP Cloud KMS seal ([HOMELAB-48](https://daltonbuilds.youtrack.cloud/issue/HOMELAB-48)). The accepted risk is recorded as an amendment to [ADR-006](01-adrs.md). Read this page before acting: several GCP operations here are irreversible, and a wrong command can lose the cluster for good.

## How a node unseals now

On every start, each node (vault-01/02/03) does the following:

1. Reads `/etc/openbao/gcp-kms.json`, the key of service account `vault-unseal-sa`.
2. Exchanges it for an OAuth token at `oauth2.googleapis.com` (HTTPS egress from VLAN 40, DNS, a correct clock).
3. Calls Cloud KMS: project `daltonbuilds-homelab-vault`, `us-central1`, keyring `vault-unseal`, key `vault-unseal-key`. It reads key metadata (`cryptoKeys.get`) and decrypts its stored root key with the **key version that encrypted it**.
4. Unseals, and rejoins Raft.

Every link has to work. **A running node doesn't need KMS to keep serving**, so failures show up on restart, not before.

## What the recovery keys can and can't do

The five Shamir shares from init are now **recovery keys** (`bao status`: `Recovery Seal Type shamir`, `Total Recovery Shares 5`, threshold 3).

- **They can** authorize privileged operations: `bao operator generate-root` (a new root token), and a seal migration back to Shamir or to another KMS.
- **They can't** unseal. Recovery keys can't decrypt the root key. If KMS is unavailable, no key you hold will open a node.

## Where each credential lives

| What | Where | Note |
|---|---|---|
| Recovery keys (5) + initial root token | `pass` → `homelab/vault/recovery-keys` | Moved from `homelab/vault-init-shamir` on 2026-11-08. The root token stays here until Tier 1 revokes it. |
| Recovery keys 1–3, paper | Physical safe | Relabelled "OpenBao recovery keys" on 2026-11-08 |
| GPG key that opens `pass` | Workstation + offline export in the safe | Without it, the `pass` entries are unreadable |
| SA key (`vault-unseal-sa`) | `pass` → `homelab/vault/gcp-kms-sa`; nodes `/etc/openbao/gcp-kms.json` (`openbao 0400`) | Created 2026-10-30; rotate yearly |
| KMS key | GCP, `daltonbuilds-homelab-vault` | Only the owner's account can disable or destroy versions |
| Root CA key (offline) | `pass` → `homelab/pki/root-ca-key` + passphrase-encrypted copy in the safe | Never on a node; needed only to sign a new intermediate (Phase 0.7b) |

## First look: is it the seal?

```bash
# on the node (before Phase 0.7d: VAULT_ADDR=http://127.0.0.1:8200, no VAULT_CACERT)
VAULT_ADDR=https://127.0.0.1:8200 VAULT_CACERT=/etc/openbao/ca.pem bao status   # Sealed true + Seal Type gcpckms → the unseal path failed
sudo journalctl -u openbao -b --no-pager | grep -iE 'seal|kms|oauth|google|permission|denied|unavailable'
curl -s -o /dev/null -w '%{http_code}\n' https://cloudkms.googleapis.com/   # 404 = reachable; 000 = no egress
chronyc tracking | grep 'System time'                                       # badly wrong clock breaks OAuth
```

If `bao status` fails with `certificate has expired` or `unknown authority` instead, the problem is the listener certificate, not the seal: see the renewal failure modes in Phase 0.7e.

From the workstation, `gcp/vault-kms.sh check` (homelab-infra) reports the project, billing, API, key and rotation, SA, role, binding and SA keys in one pass. It's read-only.

## Failures and what to do

**Never** run `bao operator init` on a sealed node, and never wipe `/opt/openbao/data` to "fix" a seal error. That destroys the cluster's data.

### Internet, DNS or GCP outage

- **Running nodes keep serving.** Don't restart healthy nodes, and postpone PVE host reboots.
- A node that restarts during the outage stays sealed. Once KMS is reachable again, check `bao status`; if it's still sealed, `sudo systemctl restart openbao`.
- If all three restart during the outage, the cluster is down until KMS is reachable. That's the accepted cost of auto-unseal (ADR-006 amendment).

### SA key deleted, disabled or expired

The symptom is permission or authentication errors in the journal on restart.

- **Disabled:** `gcloud iam service-accounts keys enable <KEY_ID> --iam-account=vault-unseal-sa@daltonbuilds-homelab-vault.iam.gserviceaccount.com`
- **Deleted:** create a new key (`gcp/vault-kms.sh key` into `pass`, homelab-infra README). Then run `vault-baseline.yaml -e vault_baseline_gcp_kms_rotate=true` and restart the nodes one at a time; each should auto-unseal before you move to the next. Delete the old key only after all three run on the new one.

### SA deleted, or IAM binding or custom role removed

- `gcp/vault-kms.sh check` shows what's missing; `gcp/vault-kms.sh apply` recreates the role, binding or SA.
- A **deleted SA** can be undeleted for 30 days by its numeric unique ID (`gcloud iam service-accounts undelete`). That restores its keys too. If it's recreated instead, it's a new identity: issue a new key and redeploy it as above.

### Key version disabled or scheduled for destruction

The version that encrypted the root key must be **enabled**. Rotation doesn't matter: older versions keep decrypting.

```bash
K="--key=vault-unseal-key --keyring=vault-unseal --location=us-central1 --project=daltonbuilds-homelab-vault"
gcloud kms keys versions list $K                     # look for DISABLED / DESTROY_SCHEDULED
gcloud kms keys versions restore <VERSION> $K        # DESTROY_SCHEDULED → DISABLED (within 30 days)
gcloud kms keys versions enable <VERSION> $K         # DISABLED → ENABLED
```

The destruction window is **30 days** (`destroyScheduledDuration 2592000s`). After that, the version is gone.

### Project deleted or billing disabled

- **Deleted:** `gcloud projects undelete daltonbuilds-homelab-vault` within 30 days. Then run `gcp/vault-kms.sh check`.
- **Billing unlinked:** re-link it (`gcloud billing projects link …`). KMS calls fail while billing is off.

### Permanent loss of the KMS key version

If the key version that encrypted the root key is destroyed (the 30-day window has passed), **the cluster's data can't be recovered**. Raft snapshots don't help: a snapshot holds the same encrypted data and needs the same seal to unseal after restore. The only path is a **new cluster** (fresh init) and re-entering every secret from its original source.

The protection is therefore on the key, not on backups:
- Only the owner's account can disable or destroy versions.
- The SA can't.
- Destruction is scheduled with a 30-day window.
- No automation in this repo ever disables or destroys a version.

## Planned changes

- **Before any upgrade past OpenBao 2.6.x:** move the built-in `gcpckms` seal to the external KMS plugin (Future Upgrades). That's a seal migration like HOMELAB-48.
- **After Phase 0.7:** replace the SA key with keyless Workload Identity Federation (Future Upgrades).
- **DR drills (planned):** snapshot and restore onto a scratch cluster, a seal migration rehearsal, and re-initializing from nothing.
