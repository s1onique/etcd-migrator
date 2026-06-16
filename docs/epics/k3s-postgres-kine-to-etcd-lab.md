# Epic: k3s PostgreSQL/Kine to Standalone etcd Migration Lab

## Overview

Add a CI/manual lab that proves the complete real-world migration path from k3s using PostgreSQL via Kine to a standalone etcd cluster.

## Context

This lab proves **control-plane state survives a datastore backend change**, not merely that key/value copy mechanics work. It validates the full chain:

1. k3s stores Kubernetes state in PostgreSQL through Kine
2. etcd-migrator reads from the Kine `kine` table
3. etcd-migrator writes to a standalone etcd target
4. k3s restarts against the standalone etcd
5. The Kubernetes API serves the migrated objects

This is the first lab that proves the tool works with the **real source system**: k3s using PostgreSQL external datastore, not synthetic test data.

## Problem Statement

Current labs prove:
- etcd snapshot → etcd cold import works
- k3s can boot against a migrated standalone etcd

What they do NOT prove:
- etcd-migrator can read from a Kine-backed PostgreSQL source
- Real k3s writes Kubernetes state into PostgreSQL via Kine
- The migration preserves the actual Kubernetes API surface, not just key/values

## Scope

Implement a lab that:

1. **Provisions PostgreSQL** with k3s database and user
2. **Boots k3s with PostgreSQL/Kine** using `K3S_DATASTORE_ENDPOINT`
3. **Creates real Kubernetes objects** through the k3s API server
4. **Captures proof** that k3s wrote to the Kine `kine` table
5. **Migrates** using `dump-kine-postgres` → `load` → `compare-dump-to-target`
6. **Restarts k3s** against the migrated standalone etcd
7. **Proves** migrated Kubernetes objects are visible through `kubectl`
8. **Enforces artifact safety** (no Secret values, no credentials)

## Implementation Files

- `internal/kine/` — Kine PostgreSQL source package
- `cmd/etcd-migrator/main.go` — `dump-kine-postgres` and `compare-dump-to-target` commands
- `scripts/lab_k3s_postgres_kine_to_etcd.sh` — Main lab script
- `scripts/verify_k3s_postgres_kine_to_etcd_artifact.sh` — Artifact verifier
- `.github/workflows/lab-k3s-postgres-kine-to-etcd.yml` — GitHub Actions workflow
- `docs/epics/k3s-postgres-kine-to-etcd-lab.md` — This epic
- `fixtures/k3s_postgres_kine_to_etcd_artifact/` — Test fixtures for verifier

## Lab Phases

### Phase 1: PostgreSQL Provisioning
- Install PostgreSQL
- Create `k3s_kine` database with `k3s` user
- Configure loopback-only, no TLS

### Phase 2: k3s with PostgreSQL/Kine
- Boot k3s with `K3S_DATASTORE_ENDPOINT=postgres://...`
- Wait for node readiness
- Capture k3s process/service status

### Phase 3: Seed Real Kubernetes State
- Create namespace `migrator-lab`
- Create ConfigMap `cm-alpha`
- Create Secret `secret-alpha` (metadata only)
- Create ServiceAccount `sa-alpha`
- Create Deployment `deploy-alpha`

### Phase 4: Stop Source k3s
- `systemctl stop k3s`
- Freeze source state before migration

### Phase 5: Start Target etcd
- Download and install etcd v3.5.21
- Start standalone etcd on port 2379
- Verify target is empty before import

### Phase 6: Run etcd-migrator
- `dump-kine-postgres` — Read from PostgreSQL/Kine kine table
- `inspect` — Analyze the dump
- `load` — Write to standalone etcd
- `compare-dump-to-target` — Verify parity

### Phase 7: k3s Cutover
- Restart k3s with `--datastore-endpoint=http://127.0.0.1:2379`
- Wait for API readiness
- Collect kubectl evidence
- Verify expectations

## Required Kubernetes Proofs

The lab must capture `kubectl get` evidence for at least:

- Namespace `migrator-lab`
- ConfigMap `cm-alpha`
- Secret metadata only (no `.data` values)
- ServiceAccount `sa-alpha`
- Deployment `deploy-alpha`

## Acceptance Criteria

### Functional acceptance

- [x] PostgreSQL is provisioned with k3s database
- [x] k3s boots with PostgreSQL/Kine external datastore
- [x] Real Kubernetes objects are created through k3s API
- [x] Kine `kine` table is populated with `/registry/` keys
- [x] etcd-migrator reads from Kine PostgreSQL source
- [x] etcd-migrator writes to standalone etcd target
- [x] k3s restarts against standalone etcd
- [x] Migrated Kubernetes objects are visible through kubectl
- [x] The lab fails closed if any phase fails

### Safety acceptance

- [x] Artifacts do not contain Secret `.data` values
- [x] Artifacts do not contain kubeconfig credentials
- [x] Artifacts do not contain private keys
- [x] The verifier fails if unsafe fields appear in artifacts

### Verification acceptance

- [x] Add a verifier for the lab artifact bundle
- [x] Verifier checks Kine table row count > 0
- [x] Verifier checks kine registry sample contains expected keys
- [x] Verifier checks target was empty before import
- [x] Verifier checks compare status is SUCCESS
- [x] Verifier checks all Kubernetes objects visible after cutover
- [x] Verifier checks Secret outputs are metadata-only

### CI acceptance

- [x] Add manual GitHub Actions workflow
- [x] The workflow uploads the safe artifact bundle
- [x] The workflow runs the artifact verifier
- [x] The workflow is manually triggerable

## Non-Goals

- Live replication or CDC
- Two-phase commit or distributed transactions
- HA PostgreSQL or TLS
- Production-grade cutover guarantees
- Preservation of leases or revision history

## Running Locally

```bash
# Set required environment variables
export K3S_CHANNEL=stable
export ETCD_VERSION=v3.5.21

# Run as root (required for k3s and PostgreSQL)
sudo bash scripts/lab_k3s_postgres_kine_to_etcd.sh

# Verify artifacts
bash scripts/verify_k3s_postgres_kine_to_etcd_artifact.sh runs/lab-k3s-postgres-kine-to-etcd-*/

# Run verifier self-test
bash scripts/verify_k3s_postgres_kine_to_etcd_artifact.sh --self-test
```

## Close Criteria

The epic can close when:

- [x] The lab script runs on a Linux VM
- [x] The manual GitHub Actions workflow passes
- [x] The artifact verifier passes
- [x] Uploaded artifacts prove k3s booted against the migrated etcd
- [x] Uploaded artifacts prove Kine table was populated
- [x] Uploaded artifacts prove expected Kubernetes objects are served
- [x] Artifact safety scan passes

Final status should be:

`[Closed / k3s PostgreSQL/Kine to standalone etcd migration proof captured]`

Only close after real workflow artifacts are available.

## References

- [k3s: server command](https://docs.k3s.io/cli/server)
- [k3s: external datastore configuration](https://docs.k3s.io/datastore)
- [Kine: Run Kubernetes on MySQL, Postgres, sqlite](https://github.com/k3s-io/kine)
- [etcd: Disaster recovery](https://etcd.io/docs/v3.5/op-guide/recovery/)
