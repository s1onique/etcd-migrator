# Lab: k3s etcd Cold Import Replay/Idempotence

## Objective

Prove `etcd-migrator`'s replay/idempotence contract when loading the same cold-import dump into the same standalone target twice. Operators may rerun a migration after uncertainty, timeout, interrupted logs, or manual error. The product must have an explicit, tested contract for what happens when the same dump is loaded twice into the same target.

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
        +-- standalone-etcd-target (empty)
        |      migrator writes here
        |
        +-- migrator dump (once)
        |
        +-- migrator load #1 (first load)
        |
        +-- migrator load #2 (replay)
```

## Accepted Replay Contracts

### Preferred: Idempotent Success

The second load is idempotent:

- First load succeeds.
- Target keyset and KV hash match source after first load.
- Second load of the exact same dump succeeds.
- Target keyset and KV hash still match source after second load.
- No duplicate/corrupt/drifted state is introduced.

### Acceptable: Safe Fail Without Mutation

The second load fails safely before mutation:

- First load succeeds.
- Target keyset and KV hash match source after first load.
- Second load exits nonzero with a clear deterministic diagnostic.
- Target keyset and KV hash after the failed second load still match the post-first-load target and the source.
- No partial mutation, drift, or corruption is introduced.

## Design Principles

1. **Offline-first**: The tool operates on snapshots, not live replication
2. **Narrow scope**: Only raw keys and values are preserved; metadata is recorded but not restored
3. **Deterministic**: Digest-based verification ensures consistency across runs
4. **Real lab**: Real Linux VM, real daemon processes, real protocol/storage boundary
5. **Replay-safe**: Either idempotent success or deterministic safe-fail without mutation

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
| `replay_expectation` | Replay contract expectation | `auto` |
| `upload_raw_etcd_artifacts` | Dangerous: upload raw etcd snapshot/dumps | `false` |

### Replay Expectation Options

- `auto`: Accept either idempotent success or safe-fail, but record which happened.
- `idempotent`: Require second load success.
- `safe-fail`: Require second load nonzero and no mutation.

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

### 7. Run etcd-migrator dump (once)

```bash
etcd-migrator dump \
  --source-endpoints="http://127.0.0.1:23790" \
  --prefix="/registry/" \
  --output source.dump.jsonl
```

### 8. Run First etcd-migrator load

```bash
etcd-migrator load \
  --target-endpoints="http://127.0.0.1:24790" \
  --prefix="/registry/" \
  --input source.dump.jsonl
```

Collect after-first-load evidence:
- source keyset
- target keyset
- source KV hash
- target KV hash
- key diff
- endpoint status

### 9. Run Second etcd-migrator load (replay)

```bash
etcd-migrator load \
  --target-endpoints="http://127.0.0.1:24790" \
  --prefix="/registry/" \
  --input source.dump.jsonl
```

Capture:
- second load exit code
- stdout
- stderr
- duration

Collect after-second-load evidence:
- source keyset
- target keyset
- source KV hash
- target KV hash
- key diff
- endpoint status

### 10. Decide Replay Outcome

- `idempotent_success`: second load succeeds, target unchanged
- `safe_fail_no_mutation`: second load fails nonzero, target unchanged
- `unsafe_mutation`: target changed after second load
- `unexpected_failure`: other failure

### 11. Write replay-status.json

```json
{
  "migration_prefix": "/registry/",
  "replay_expectation": "auto",
  "first_load_exit_code": 0,
  "second_load_exit_code": 0,
  "first_load_keysets_match": true,
  "first_load_kv_match": true,
  "second_load_keysets_match": true,
  "second_load_kv_match": true,
  "target_hash_unchanged_after_second_load": true,
  "replay_outcome": "idempotent_success",
  "contract_satisfied": true,
  "run_id": "..."
}
```

## Security Boundaries

### Do NOT Upload by Default

- Raw etcd snapshots (*.db, *snapshot*)
- Raw dumps (*dump*, *.jsonl)
- Full key/value exports containing Secrets

### Safe Artifacts (Always Uploaded)

```
migration-prefix.txt
k3s-version.txt
kubectl-version.yaml
etcd-version.txt
etcdctl-version.txt
etcdutl-version.txt
k3s-snapshot-status.json
k3s-snapshot.sha256
k3s-etcd-endpoint-status.json

dump-summary.txt
first-load-summary.txt
second-load-exit-code.txt
second-load-stdout.txt
second-load-stderr.txt

compare-after-first-load.json
compare-after-second-load.json
replay-status.json

source-kv-after-first-load-sha256.txt
target-kv-after-first-load-sha256.txt
source-kv-after-second-load-sha256.txt
target-kv-after-second-load-sha256.txt

key-counts-after-first-load.txt
key-counts-after-second-load.txt
key-diff-after-first-load.txt
key-diff-after-second-load.txt

target-endpoint-status-after-first-load.json
target-endpoint-status-after-second-load.json

source-non-migrated-keys.txt
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
- [ ] Snapshot restored into standalone source etcd
- [ ] Separate empty standalone target etcd starts cleanly
- [ ] `etcd-migrator` dumps from source once
- [ ] First `etcd-migrator load` succeeds
- [ ] Source and target keysets match after first load
- [ ] Source and target key/value hashes match after first load
- [ ] Second `etcd-migrator load` runs with same dump
- [ ] Second load exit code captured
- [ ] Source and target keysets match after second load
- [ ] Source and target key/value hashes match after second load
- [ ] Target KV hash unchanged after second load
- [ ] `replay-status.json` shows `contract_satisfied=true`
- [ ] `replay_outcome` is `idempotent_success` or `safe_fail_no_mutation`
- [ ] Safe evidence artifacts uploaded
- [ ] Raw snapshots not uploaded unless explicitly opted in

## Running Locally

```bash
# Set required environment variables
export K3S_CHANNEL=stable
export ETCD_VERSION=v3.5.21
export OBJECT_COUNT=20
export REPLAY_EXPECTATION=auto
export UPLOAD_RAW_ETCD_ARTIFACTS=false

# Run as root (required for k3s)
sudo bash scripts/lab_k3s_etcd_cold_import_replay.sh

# Or via Makefile
make lab-k3s-etcd-cold-import-replay
```

## GitHub Actions

Navigate to the Actions tab and select "Lab - k3s etcd cold import replay" → "Run workflow".

## Artifact Verifier

The lab includes a deterministic artifact verifier that validates the proof artifacts after the lab runs.

### Verifier CLI

```bash
# Verify a downloaded artifact directory
bash scripts/verify_k3s_etcd_cold_import_replay_artifact.sh <artifact-dir>

# Run self-test (verifies pass/fail fixtures)
bash scripts/verify_k3s_etcd_cold_import_replay_artifact.sh --self-test
```

### Close Signal

The verifier confirms successful replay when:

| Check | Required Value |
|-------|---------------|
| `migration_prefix` | `/registry/` |
| `first_load_exit_code` | `0` |
| `first_load_keysets_match` | `true` |
| `first_load_kv_match` | `true` |
| `second_load_keysets_match` | `true` |
| `second_load_kv_match` | `true` |
| `target_hash_unchanged_after_second_load` | `true` |
| `contract_satisfied` | `true` |
| `replay_outcome` | `idempotent_success` or `safe_fail_no_mutation` |
| Source/target KV hash after first | Equal |
| Source/target KV hash after second | Equal |
| Target KV hash after first | Equal to target after second |

### What the Verifier Checks

1. **Required files exist**: `replay-status.json`, `migration-prefix.txt`, `compare-after-first-load.json`, `compare-after-second-load.json`, hash files, key-count files, key-diff files, endpoint status files, stdout/stderr files

2. **JSON validity**: All JSON files are parseable

3. **Migration prefix**: Must be `/registry/`

4. **First load success**: `first_load_exit_code == 0`

5. **First load match**: `first_load_keysets_match == true` and `first_load_kv_match == true`

6. **Second load match**: `second_load_keysets_match == true` and `second_load_kv_match == true`

7. **Target unchanged**: `target_hash_unchanged_after_second_load == true`

8. **Contract satisfied**: `contract_satisfied == true`

9. **Valid outcome**: `replay_outcome` is `idempotent_success` or `safe_fail_no_mutation`

10. **Exit code consistency**: For `idempotent_success`, `second_load_exit_code == 0`; for `safe_fail_no_mutation`, `second_load_exit_code != 0`

11. **Hash invariants**: Source equals target after first load, source equals target after second load, target unchanged after second load

12. **Key diff empty**: No diff output means source and target key sets are identical after each load

13. **Safe artifact exclusions**: Raw snapshots, dumps, and KV exports must NOT be present

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
