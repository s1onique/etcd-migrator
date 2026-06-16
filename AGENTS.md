# AGENTS.md — etcd-migrator

## Project Context

`etcd-migrator` is an offline, current-state, key/value migrator for moving Kubernetes data between etcd v3-compatible endpoints. It is designed for cutover scenarios where Kubernetes is migrated from a Kine-backed PostgreSQL datastore to a real etcd cluster.

## Design Principles

1. **Offline-first**: The tool operates on snapshots, not live replication
2. **Narrow scope**: Only raw keys and values are preserved; metadata is recorded but not restored
3. **Deterministic**: Digest-based verification ensures consistency across runs
4. **LLM-friendly**: Small, focused files that are easy to understand and modify

## Implementation Guidelines

- Module path: `github.com/spbnix/etcd-migrator`
- Language: Go (modern, static single-binary SRE tooling)
- Testing: Table-driven tests with clear error cases
- Code style: Follow `gofmt` strictly; no linter warnings

## Quality Gates

All PRs must pass:
- `go test ./...`
- `go vet ./...`
- `gofmt -l .` (no unformatted files)

Run via: `make gate`

## Key Boundaries

- **Does preserve**: raw keys, raw values
- **Does NOT preserve**: revision history, watches, compaction state, lease identity
- **Records but does not restore**: create_revision, mod_revision, version, lease ID

## File Structure

```
cmd/etcd-migrator/main.go   # CLI entry point
internal/dump/              # JSONL dump format
internal/digest/            # Stable digest over key/value pairs
internal/version/           # Version info
docs/doctrine/              # Migration contract and safety docs
```

## Important Notes for AI Assistants

1. When adding etcd client integration, use `go.etcd.io/etcd/client/v3`
2. The dump format must handle binary keys/values via base64
3. Digest must be deterministic regardless of input record order
4. All I/O should be streaming where possible to handle large dumps
