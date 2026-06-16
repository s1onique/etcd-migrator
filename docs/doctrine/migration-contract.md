# Migration Contract

**etcd-migrator** performs an offline, current-state, key/value migration between etcd v3-compatible endpoints.

## What Is Preserved

- **Raw keys**: The exact binary key bytes stored in etcd
- **Raw values**: The exact binary value bytes stored in etcd

## What Is Recorded But Not Preserved

The following metadata is captured in the JSONL dump for debugging and verification purposes, but is **not restored** to the target:

- `version`: Number of times this key has been modified
- `create_revision`: Revision when this key was first created
- `mod_revision`: Revision when this key was last modified
- `lease`: Lease ID associated with this key (if any)

## What Is Not Preserved

The following are intentionally not preserved:

- **Revision history**: Historical values are not migrated
- **Watches**: No watchers or notification subscriptions are migrated
- **Compaction state**: Compaction metadata is not preserved
- **Lease identity**: Leases are not recreated; keys with leases become non-leased
- **Live consistency**: Writers must be stopped before migration

## Why This Contract Is Narrow

Kubernetes only requires current-state key/value data to function correctly. The etcd lease and revision metadata are runtime optimization details that Kubernetes reconciles:

1. **Lease removal**: Kubernetes re-acquires leases as needed after migration
2. **Version reset**: API server increments versions on first write
3. **Revision reset**: etcd handles revision numbering internally

This narrow contract enables a simple, reliable, and fast migration tool.

## Dump Format

Dumps are in JSONL format with the following schema:

```json
{
  "key_b64": "base64-encoded binary key",
  "value_b64": "base64-encoded binary value",
  "version": 1,
  "create_revision": 1,
  "mod_revision": 1,
  "lease": 0
}
```

### Base64 Encoding

The tool uses Go's `base64.RawStdEncoding` for encoding binary keys and values. This encoding:

- Uses the standard base64 alphabet (A-Z, a-z, 0-9, +, /)
- Omits padding characters (`=`)
- Produces JSON-safe strings (no `=` padding)

Note: The alphabet may contain `+` and `/` characters, which are perfectly safe in JSON strings. This is the standard base64 alphabet used by PEM, MIME, and most cryptographic specifications.

### Field Semantics

- `key_b64`: **Required**. Must be present and non-empty. Encodes the raw etcd key bytes.
- `value_b64`: **Required**. Must be present. An empty string (`""`) is valid for keys with empty values. Only a missing field is rejected.
