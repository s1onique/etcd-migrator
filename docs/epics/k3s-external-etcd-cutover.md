# Epic: External-etcd k3s Cutover Validation Lab

## Overview

Prove that an etcd migration is usable by Kubernetes, not merely byte-equivalent at the key/value layer.

After migrating `/registry/` data from the source k3s datastore into a standalone etcd target, start a fresh k3s server configured to use that standalone etcd as its external datastore and prove that Kubernetes can boot, read the migrated objects, and serve them through the Kubernetes API.

This epic closes the gap between:

1. source/target etcd key equality, and
2. k3s successfully running against the migrated standalone etcd.

## Problem Statement

Current replay and comparison labs prove that the migration tool can copy and compare etcd keys. That is necessary but not sufficient for cutover confidence.

A successful real-world cutover requires proving that k3s can consume the migrated etcd dataset as its external datastore and that expected Kubernetes resources are visible through `kubectl`.

The next serious proof should therefore validate the migrated datastore through the Kubernetes control plane, not only through direct etcd inspection.

## Scope

Implement a lab that:

1. Starts or prepares a source k3s cluster with representative Kubernetes objects.
2. Migrates the relevant `/registry/` keyspace into a standalone etcd target.
3. Starts a k3s server configured with that standalone etcd as its external datastore.
4. Waits for the Kubernetes API to become available.
5. Uses `kubectl` against the cutover k3s API to prove migrated resources are readable.
6. Emits safe artifacts suitable for CI upload and human review.

## Required Kubernetes Proofs

The lab must capture `kubectl get` evidence for at least:

* Namespaces.
* ConfigMaps.
* Secrets metadata only; no secret values.
* CRDs.
* Custom resources for at least one installed CRD.
* Nodes and readiness status, where applicable.
* System pods or control-plane readiness, where applicable.

Secret proof must be metadata-only. Do not dump Secret `.data`, decoded values, service-account tokens, kubeconfigs, certificates, private keys, or bearer tokens.

## Acceptance Criteria

### Functional acceptance

- [x] A standalone etcd target is populated by the migration tool.
- [x] A k3s server can start using the migrated standalone etcd as its external datastore.
- [x] `kubectl` can connect to the cutover k3s API server.
- [x] Migrated namespaces are visible through `kubectl get namespaces`.
- [x] Migrated ConfigMaps are visible through `kubectl get configmaps --all-namespaces`.
- [x] Migrated Secrets are visible by name/type/namespace only through safe metadata output.
- [x] Migrated CRDs are visible through `kubectl get crds`.
- [x] At least one migrated custom resource instance is visible through `kubectl get`.
- [x] Node readiness is captured where meaningful for the lab topology.
- [x] The lab fails closed if expected migrated resources are missing.

### Safety acceptance

- [x] Artifacts must not contain Secret values.
- [x] Artifacts must not contain kubeconfig client keys, certificates, bearer tokens, service-account tokens, or private keys.
- [x] Any kubeconfig captured as an artifact must be redacted or omitted.
- [x] `kubectl get secrets` output must be restricted to safe columns or sanitized JSON.
- [x] The verifier must fail if unsafe fields such as `.data`, `.stringData`, token-like values, private keys, or kubeconfig credentials appear in uploaded artifacts.

### Verification acceptance

- [x] Add a verifier for the cutover artifact bundle.
- [x] Verifier checks required artifact files exist.
- [x] Verifier checks k3s external datastore startup completed.
- [x] Verifier checks Kubernetes API became reachable.
- [x] Verifier checks required `kubectl get` proof files are present.
- [x] Verifier checks expected test objects are present.
- [x] Verifier checks Secret outputs are metadata-only.
- [x] Verifier checks no forbidden sensitive material appears in artifacts.
- [x] Verifier fails if failure artifacts contain unsafe material.

### CI acceptance

- [x] Add a manual GitHub Actions workflow with a cutover-validation mode.
- [x] The workflow uploads the safe cutover artifact bundle.
- [x] The workflow runs the artifact verifier.
- [x] The workflow is manually triggerable.
- [ ] Existing dump/load/replay workflows continue to pass.

## Suggested Test Fixtures

The cutover lab creates deterministic source-cluster objects such as:

* Namespace: `etcd-migrator-cutover`
* ConfigMap: `etcd-migrator-cutover-config`
* Secret: `etcd-migrator-cutover-secret`
* CRD: `widgets.cutover.etcd-migrator.dev`
* Custom resource: `sample-widget`

## Artifact Layout

```
<lab-dir>/artifacts/
  migration-prefix.txt
  cutover-status.json
  k3s-version.txt
  etcd-version.txt
  etcdctl-version.txt
  source/
    source-kubectl-namespaces.txt
    source-kubectl-configmaps.txt
    source-kubectl-secrets-metadata.txt
    source-kubectl-crds.txt
    source-kubectl-custom-resources.txt
    k3s-snapshot-status.json
    k3s-snapshot.sha256
  migration/
    migrate.log
    compare.log
    compare-status.json
    source-kv-sha256.txt
    target-kv-sha256.txt
    key-counts.txt
    key-diff.txt
  target/
    external-etcd-health.txt
    target-etcd.log
    k3s-start.log
    cutover-kubectl-namespaces.txt
    cutover-kubectl-configmaps.txt
    cutover-kubectl-secrets-metadata.txt
    cutover-kubectl-crds.txt
    cutover-kubectl-custom-resources.txt
    cutover-kubectl-nodes.txt
    cutover-kubectl-system-pods.txt
  verification/
    artifact-safety-scan.txt
```

## Non-goals

* Do not add new migration semantics unless the cutover lab exposes a real bug.
* Do not dump full Secret bodies.
* Do not require production-grade HA external etcd.
* Do not turn this into a backup/restore product.
* Do not claim production cutover readiness solely from this lab; this is a bounded CI/lab proof.

## Implementation Files

- `scripts/lab_k3s_external_etcd_cutover.sh` - Main lab script
- `scripts/verify_k3s_external_etcd_cutover_artifact.sh` - Artifact verifier
- `.github/workflows/k3s-external-etcd-cutover.yml` - GitHub Actions workflow
- `fixtures/k3s_external_etcd_cutover_artifact/` - Test fixtures

## Running Locally

```bash
# Set required environment variables
export K3S_CHANNEL=stable
export ETCD_VERSION=v3.5.21

# Run as root (required for k3s)
sudo bash scripts/lab_k3s_external_etcd_cutover.sh

# Verify artifacts
bash scripts/verify_k3s_external_etcd_cutover_artifact.sh runs/lab-k3s-external-etcd-cutover-*/

# Run verifier self-test
bash scripts/verify_k3s_external_etcd_cutover_artifact.sh --self-test
```

## Close Criteria

The epic can close when:

- [ ] The cutover lab runs locally on a suitable Linux runner.
- [ ] The manual GitHub Actions workflow passes.
- [ ] The artifact verifier passes.
- [ ] Uploaded artifacts prove k3s booted against the migrated standalone etcd.
- [ ] Uploaded artifacts prove expected Kubernetes objects are served through the cutover API.
- [ ] Artifact safety scan passes.
- [ ] Existing migration replay, compare, and quality gates remain green.

Final status should be:

`[Closed / external-etcd k3s cutover proof captured]`

Only close after real workflow artifacts are available.

## References

- [k3s: server command](https://docs.k3s.io/cli/server)
- [k3s: etcd server configuration](https://docs.k3s.io/datastore/etcd)
- [etcd: How to save the database](https://etcd.io/docs/v3.5/tutorials/how-to-save-database/)
