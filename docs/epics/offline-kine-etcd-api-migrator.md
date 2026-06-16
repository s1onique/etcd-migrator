# Epic: Offline Kine-compatible etcd API Migrator

## Overview

Build an offline, current-state, key/value migrator for moving Kubernetes data from a Kine-backed PostgreSQL datastore to a real etcd cluster.

## Context

Many Kubernetes deployments use Kine to store data in PostgreSQL (or other SQL databases) instead of a real etcd cluster. While this works for development and small production environments, it has limitations:

- No native etcd client support
- Performance degradation at scale
- Missing etcd ecosystem tooling

etcd-migrator enables cutover from Kine+PostgreSQL to a real etcd cluster.

## Goals

1. **Offline-first**: Migrate from snapshots, not live replication
2. **Minimal scope**: Only key/value pairs, no revision history
3. **Deterministic verification**: Digest-based consistency checks
4. **ETCD v3 compatible**: Works with real etcd, Kine, and other etcd v3 API implementations

## Non-Goals

- Live replication or CDC (Change Data Capture)
- Two-phase commit or distributed transactions
- Preserving leases or revision history
- Real-time migration or blue-green deployments

## Story Map

### Sprint 1: Foundation

- [x] Scaffold Go repo with module path
- [x] Add AGENTS.md with implementation guidelines
- [x] Create Makefile with test/vet/gate targets
- [x] Implement dump.Record with base64 key/value
- [x] Implement JSONL writer/reader with validation
- [x] Implement deterministic digest
- [x] Add comprehensive tests
- [x] Wire quality gate

### Sprint 2: Source Dump

- [x] Implement etcd v3 source prefix dump
- [x] Add pagination by key
- [x] Record source metadata from mvccpb.KeyValue
- [x] Support plaintext source endpoint
- [ ] Support TLS/auth flags
- [x] Add --source-endpoints flag

### Sprint 3: Target Load

- [x] Implement empty-target guarded load
- [x] Add --target-endpoints flag
- [x] Two-phase validate-then-batched-write load
- [x] Verify target is empty before starting

### Sprint 4: Verification

- [ ] Implement dump-vs-target verifier
- [x] Add inspect command for dump analysis
- [ ] Compute digest from live etcd
- [ ] Compare digests with detailed diff

### Local Artifact Tooling

- [x] `inspect-dump`: Read-only dump analysis without etcd connection
  - Validates JSONL records (base64 key/value decoding)
  - Collects stats: count, bytes, lease count, revision ranges
  - Computes deterministic digest for consistency verification
  - Reports migration-risk metadata (lease-bearing records)
  - Command: `etcd-migrator inspect --input dump.jsonl`

### Future: Production Hardening

- [ ] Add Kine+PostgreSQL integration harness
- [ ] Add cutover runbook
- [ ] Add integration tests
- [ ] Add benchmarks

## Technical Decisions

### Why Go?

- Official etcd v3 client is Go-native
- Static single-binary deployment
- Excellent for SRE tooling

### Why JSONL?

- Human-readable for debugging
- Line-by-line processing for streaming
- Base64 handles binary keys/values

### Why Narrow Scope?

- Kubernetes reconciles leases and versions on first write
- Simpler code = fewer bugs
- Faster migration

## Dependencies

- `go.etcd.io/etcd/client/v3`: Official etcd v3 client
- Go 1.22+

## Risks

| Risk | Mitigation |
|------|------------|
| Source still being written to | Stop all Kubernetes components before migration |
| Target not empty | Verify target is empty before starting |
| Large dump exhausts memory | Streaming JSONL processing |
| Network timeout | Ensure stable network, consider retries |
