# Lab: k3s etcd Cold Import

## Objective

Prove `etcd-migrator` can migrate a real Kubernetes/k3s etcd dataset into a clean standalone etcd target using a cold, snapshot-restored source copy.

## Lab Topology

```
GitHub manual workflow (workflow_dispatch)
        |
        v
Linux VM runner (ubuntu-24.04)
        |
        +-- k3s server --cluster-init
        |      embedded etcd, hot, real Kubernetes writes
        |
        +-- snapshot k3s embedded etcd
        |
        +-- standalone-etcd-source
        |      restored from snapshot
        |      cold/immutable source copy
        |
        +-- standalone-etcd-target
               empty target
               migrator writes here
```

Key point: **k3s embedded etcd is the real producer, not the cold source**. We snapshot it, restore into standalone etcd #1, then migrate into standalone etcd #2.

## Design Principles

1. **Offline-first**: The tool operates on snapshots, not live replication
2. **Narrow scope**: Only raw keys and values are preserved; metadata is recorded but not restored
3. **Deterministic**: Digest-based verification ensures consistency across runs
4. **Real lab**: Real Linux VM, real daemon processes, real protocol/storage boundary

## Prerequisites

- Linux (Ubuntu 24.04 in CI)
- curl, tar, jq, sha256sum
- Go toolchain
- k3s supports `--cluster-init` for embedded etcd clustering

## Workflow Inputs

| Input | Description | Default |
|-------|-------------|---------|
| `k3s_channel` | k3s install channel | `stable` |
| `etcd_version` | Standalone etcd release | `v3.5.21` |
| `object_count` | Synthetic Kubernetes object count per namespace | `20` |
| `upload_raw_etcd_artifacts` | Dangerous: upload raw etcd snapshot/dumps | `false` |

## Lab Steps

### 1. Install Standalone etcd

Download and install etcd binaries (etcd, etcdctl, etcdutl) from GitHub releases.

### 2. Install k3s with Embedded etcd

```bash
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_CHANNEL="stable" \
  INSTALL_K3S_EXEC="server --cluster-init --write-kubeconfig-mode=644 --disable=traefik --disable=servicelb --disable=metrics-server" \
  sh -
```

Flags:
- `--cluster-init`: Initialize embedded etcd in cluster mode
- `--disable=traefik,servicelb,metrics-server`: Minimal components for the lab

### 3. Populate Real Kubernetes Objects

Create:
- 2 namespaces: `lab-a`, `lab-b`
- ServiceAccount per namespace
- ConfigMaps and Secrets per namespace (default: 20 each)
- CustomResourceDefinition: `widgets.lab.example.com`
- Sample Widget CR in `lab-a`

### 4. Snapshot k3s Embedded etcd

```bash
ETCDCTL_API=3 etcdctl \
  --endpoints="https://127.0.0.1:2379" \
  --cacert="/var/lib/rancher/k3s/server/tls/etcd/server-ca.crt" \
  --cert="/var/lib/rancher/k3s/server/tls/etcd/server-client.crt" \
  --key="/var/lib/rancher/k3s/server/tls/etcd/server-client.key" \
  snapshot save snapshot.db
```

Capture snapshot status with `etcdutl`:

```bash
etcdutl snapshot status snapshot.db --write-out=json
```

### 5. Restore Snapshot into Standalone Source etcd

```bash
etcdutl snapshot restore snapshot.db \
  --name source \
  --data-dir source.etcd \
  --initial-cluster source=http://127.0.0.1:23800 \
  --initial-advertise-peer-urls http://127.0.0.1:23800
```

Start source etcd on port 23790.

### 6. Start Empty Target Standalone etcd

Start clean target etcd on port 24790.

### 7. Run etcd-migrator

```bash
# Dump from source
etcd-migrator dump \
  --source-endpoints="http://127.0.0.1:23790" \
  --output source.dump.jsonl

# Load into target
etcd-migrator load \
  --target-endpoints="http://127.0.0.1:24790" \
  --input source.dump.jsonl
```

### 8. Collect Comparison Evidence

- Compare key counts between source and target
- Generate key diff report
- Capture target endpoint status

## Security Boundaries

### Do NOT Upload by Default

- Raw etcd snapshots (*.db, *snapshot*)
- Raw dumps (*dump*)
- Full key/value exports containing Secrets

### Safe Artifacts (Always Uploaded)

```
k3s-version.txt
etcd-version.txt
etcdctl-version.txt
etcdutl-version.txt
k3s-etcd-endpoint-status.json
k3s-snapshot-status.json
k3s-snapshot.sha256
source-endpoint-health.json
target-endpoint-health-before.json
target-endpoint-status-after.json
key-counts.txt
key-diff.txt
source-kv-sha256.txt
target-kv-sha256.txt
compare-status.json
source-etcd.log
target-etcd.log
k8s-inventory.txt
k8s-crd-widget.yaml
kubectl-version.yaml
```

### Opt-in Raw Artifacts (Only if `upload_raw_etcd_artifacts=true`)

Currently copied when `upload_raw_etcd_artifacts=true`:

- `k3s-embedded-etcd.snapshot.db`

Raw migrator dumps remain in the lab work directory and are not uploaded.

## Acceptance Criteria

- [ ] Workflow is manual-only via `workflow_dispatch`
- [ ] k3s starts with embedded etcd using `--cluster-init`
- [ ] Lab writes real Kubernetes API objects into k3s
- [ ] k3s embedded etcd snapshot taken successfully
- [ ] Snapshot status captured with `etcdutl snapshot status`
- [ ] Snapshot restored into standalone source etcd
- [ ] Separate empty standalone target etcd starts cleanly
- [ ] `etcd-migrator` imports source data into target
- [ ] Source and target keysets match
- [ ] Source and target key/value hashes match
- [ ] `compare-status.json` shows `keysets_match=true` and `kv_match=true`
- [ ] Safe evidence artifacts uploaded
- [ ] Raw snapshots not uploaded unless explicitly opted in

## Running Locally

```bash
# Set required environment variables
export K3S_CHANNEL=stable
export ETCD_VERSION=v3.5.21
export OBJECT_COUNT=20
export UPLOAD_RAW_ETCD_ARTIFACTS=false

# Run as root (required for k3s)
sudo bash scripts/lab_k3s_etcd_cold_import.sh

# Or via Makefile
make lab-k3s-etcd-cold-import
```

## GitHub Actions

Navigate to the Actions tab and select "Lab - k3s etcd cold import" → "Run workflow".

## Artifact Verifier

The lab includes a deterministic artifact verifier that validates the proof artifacts after the lab runs.

### Verifier CLI

```bash
# Verify a downloaded artifact directory
bash scripts/verify_k3s_etcd_cold_import_artifact.sh <artifact-dir>

# Run self-test (verifies pass/fail fixtures)
bash scripts/verify_k3s_etcd_cold_import_artifact.sh --self-test
```

### Close Signal

The verifier confirms successful migration when:

| Check | Required Value |
|-------|----------------|
| `migration_prefix` | `/registry/` |
| `keysets_match` | `true` |
| `kv_match` | `true` |
| Source/target KV hash | Equal (first field only) |
| `key-diff.txt` | Empty |
| All required JSON files | Valid JSON |

### What the Verifier Checks

1. **Required files exist**: `compare-status.json`, `migration-prefix.txt`, `source-kv-sha256.txt`, `target-kv-sha256.txt`, `k3s-snapshot-status.json`, `target-endpoint-status-after.json`, `key-counts.txt`, `key-diff.txt`, `source-non-migrated-keys.txt`

2. **JSON validity**: All JSON files are parseable

3. **Migration prefix**: Must be `/registry/`

4. **Match booleans**: `keysets_match` and `kv_match` must both be `true`

5. **Hash equality**: Source and target KV hashes (first field only, ignoring filename)

6. **Key diff empty**: No diff output means source and target key sets are identical

7. **Safe artifact exclusions**: Raw snapshots, dumps, and KV exports must NOT be present

### Raw Artifact Safety

The verifier enforces these safety rules:

- **No raw etcd snapshots** (`.db` files, `*snapshot*` files except `k3s-snapshot-status.json` and `k3s-snapshot.sha256`)
- **No raw migrator dumps** (`*dump*`, `*.jsonl`)
- **No raw KV exports** (`source.kv.tsv`, `target.kv.tsv`)

Raw snapshot upload remains opt-in via the `upload_raw_etcd_artifacts` workflow input.

## References

- [GitHub: Manually running a workflow](https://docs.github.com/actions/managing-workflow-runs/manually-running-a-workflow)
- [K3s: server command](https://docs.k3s.io/cli/server)
- [etcd: How to save the database](https://etcd.io/docs/v3.5/tutorials/how-to-save-database/)
