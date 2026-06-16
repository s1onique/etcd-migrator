# etcd-migrator

Offline etcd v3 API key/value migrator for Kubernetes datastore migration.

## Overview

etcd-migrator performs an offline, current-state, key/value migration between etcd v3-compatible endpoints. It is designed for cutover scenarios where Kubernetes is migrated from a Kine-backed PostgreSQL datastore to a real etcd cluster.

## Features

- **Offline-first**: Operates on snapshots, not live replication
- **Narrow scope**: Only raw keys and values are preserved
- **Deterministic verification**: Digest-based consistency checks
- **Streaming**: Handles large dumps without loading into memory

## Quick Start

### Build

```bash
make build
```

### Run Tests

```bash
make test
```

### Quality Gate

```bash
make gate
# or
./scripts/quality_gate.sh
```

## Usage

### Dump keys from source

```bash
etcd-migrator dump \
  --source-endpoints https://source:2379 \
  --prefix /registry/ \
  --output dump.jsonl
```

### Load into target

```bash
etcd-migrator load \
  --target-endpoints https://target:2379 \
  --input dump.jsonl
```

### Inspect a dump

```bash
etcd-migrator inspect --input dump.jsonl
```

### Verify migration

```bash
etcd-migrator verify \
  --source dump.jsonl \
  --target-endpoints https://target:2379
```

## Migration Contract

etcd-migrator **preserves**:
- Raw keys
- Raw values

etcd-migrator **records but does not preserve**:
- version, create_revision, mod_revision, lease

etcd-migrator **does not preserve**:
- Revision history
- Watches
- Compaction state
- Lease identity

See [docs/doctrine/migration-contract.md](docs/doctrine/migration-contract.md) for details.

## Safety Boundaries

⚠️ **Before migration:**
1. Stop all Kubernetes control plane components
2. Verify target etcd is empty

⚠️ **After migration:**
1. Run verification
2. Update kube-apiserver configuration
3. Start Kubernetes components

See [docs/doctrine/safety-boundaries.md](docs/doctrine/safety-boundaries.md) for details.

## Documentation

- [Migration Contract](docs/doctrine/migration-contract.md)
- [Safety Boundaries](docs/doctrine/safety-boundaries.md)
- [Verification Doctrine](docs/doctrine/verification-doctrine.md)
- [Epic: Offline Kine-etcd API Migrator](docs/epics/offline-kine-etcd-api-migrator.md)
- [Runbook: Kine-to-Etcd Migration](docs/runbooks/offline-kubernetes-kine-to-etcd.md)

## Development

### Prerequisites

- Go 1.22+
- etcd v3 client (go.etcd.io/etcd/client/v3)

### Quality Gates

All PRs must pass:
```bash
make gate
```

This runs:
- `gofmt -l .` (formatting check)
- `go vet ./...` (static analysis)
- `go test ./...` (tests)

## License

MIT
