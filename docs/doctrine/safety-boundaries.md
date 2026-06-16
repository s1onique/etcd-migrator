# Safety Boundaries

This document defines when it's safe to use etcd-migrator and what preconditions must be met.

## Required Preconditions

### 1. Kubernetes Cluster Shutdown

**All Kubernetes control plane components must be stopped before migration.**

Rationale: etcd-migrator is an offline, point-in-time migrator. If the source is still being written to during migration, the dump will be inconsistent.

```bash
# Stop all Kubernetes components
systemctl stop kubelet
systemctl stop kube-apiserver
systemctl stop kube-controller-manager
systemctl stop kube-scheduler
```

### 2. Target etcd Must Be Empty

**The target etcd cluster must have no existing keys.**

Rationale: etcd-migrator does not perform conflict resolution. It writes all keys from the dump to the target. If the target has existing data, keys may conflict.

### 3. Source and Target Are etcd v3 Compatible

**Both source and target must implement the etcd v3 API.**

Rationale: The tool uses `clientv3` which requires etcd v3 or compatible API (e.g., Kine with etcd API mode).

### 4. Sufficient Disk Space

**Both source and target systems must have adequate disk space.**

The dump file size is approximately equal to the etcd database size. The target must have space for the incoming data plus etcd overhead.

## Danger Zones

### Do Not Run With Active Writers

Running etcd-migrator while the source is accepting writes will result in an inconsistent dump. This can cause:
- Missing keys
- Corrupt values
- Partial data loss

### Do Not Use on Production Without Testing

Always test the migration on a non-production environment first:
1. Create a test environment
2. Run the migration
3. Verify the target
4. Start Kubernetes on the target

### Do Not Skip Verification

Always run verification after migration:
```bash
etcd-migrator verify --source dump.jsonl --target https://target:2379
```

## What Can Go Wrong

| Failure Mode | Cause | Prevention |
|-------------|-------|------------|
| Missing keys | Source written to during migration | Stop all writers |
| Wrong values | Source written to during migration | Stop all writers |
| Target won't start | Target had existing data | Verify target is empty |
| Migration tool crashes | Insufficient memory | Process in streaming mode |
| Timeout | Network issues or large dump | Ensure stable network |

## Recovery Procedures

If something goes wrong:

1. **Stop the migration immediately**
2. **Do not delete the source dump file**
3. **Identify the problem** using the error message
4. **Fix the root cause**
5. **Re-run the migration** (idempotent for empty target)

## Emergency Rollback

If the migration cannot be completed:
1. Reconfigure Kubernetes to use the original datastore
2. Restart Kubernetes components
3. Verify cluster health
4. Investigate migration failure
5. Plan retry after fixing issues
