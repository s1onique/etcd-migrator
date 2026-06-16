# Verification Doctrine

This document describes how etcd-migrator verifies migration correctness.

## Verification Strategy

etcd-migrator uses a **deterministic digest** to verify that the target contains exactly the same key/value pairs as the source dump.

## The Digest

The digest is computed as:

```
SHA-256( sorted records by raw key, each as key + NUL + value + NUL )
```

Key properties:
- **Order-independent**: Same digest regardless of how records are ordered
- **Metadata-free**: Only raw key and value bytes are hashed (not versions, revisions, leases)
- **Deterministic**: Same input always produces same digest
- **Standard**: SHA-256, hex-encoded

## Verification Workflow

### 1. Pre-Migration: Source Digest

Before migration, compute the digest of the source dump:

```bash
etcd-migrator dump --source-endpoints https://source:2379 \
                   --prefix /registry/ \
                   --output dump.jsonl
# Digest is printed to stderr or can be saved
```

### 2. Post-Migration: Target Digest

After migration, compute the digest of the target:

```bash
etcd-migrator verify --target-endpoints https://target:2379 \
                     --input dump.jsonl
# Returns: digest match or mismatch
```

### 3. Compare Digests

Compare the pre-migration digest with the post-migration digest:
- **Match**: All keys and values migrated correctly
- **Mismatch**: Some keys or values differ

## Verification Commands

### Inspect a Dump

```bash
etcd-migrator inspect --input dump.jsonl
# Outputs: key count, approximate size, digest
```

### Verify Against Target

```bash
etcd-migrator verify --source dump.jsonl --target https://target:2379
# Compares source digest with recomputed target digest
```

### Verify Command Output

The verify command outputs:
- Source digest (from dump)
- Target digest (from live etcd)
- Match/mismatch result
- List of missing keys (if any)
- List of extra keys (if any)

## Limitations

Verification cannot detect:
- **Stale data**: If source was still being written to
- **Corrupted source**: If source dump was corrupt before verification
- **Non-etcd data**: Data outside the etcd datastore

Verification can detect:
- **Missing keys**: Keys in source but not in target
- **Extra keys**: Keys in target but not in source
- **Wrong values**: Keys with different values
- **Digest mismatch**: Overall data difference

## Why Digest Over Comparison

Comparing key-by-key against large datasets is slow and error-prone. A digest:
- **Fast**: O(n) single pass through data
- **Compact**: 64 hex characters
- **Complete**: Covers all keys and values
- **Verifiable**: Can be stored and compared later

## Verification Failure Handling

If verification fails:

1. **Identify the issue type** (missing keys, extra keys, or value mismatch)
2. **For missing keys**: Re-run migration or investigate target connectivity
3. **For extra keys**: Clear target and re-migrate (verify target is empty before starting)
4. **For value mismatch**: Investigate source consistency at dump time
