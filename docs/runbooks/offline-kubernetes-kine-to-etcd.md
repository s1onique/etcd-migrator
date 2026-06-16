# Runbook: Offline Kubernetes Kine-to-Etcd Migration

This runbook describes the procedure for migrating Kubernetes from a Kine-backed PostgreSQL datastore to a real etcd cluster using etcd-migrator.

## Prerequisites

- etcd-migrator binary installed
- Source: Kine with PostgreSQL backend
- Target: Empty etcd v3 cluster
- Sufficient disk space on both systems
- Network connectivity between systems

## Phase 1: Preparation (Before Maintenance Window)

### 1.1 Verify Target Is Empty

```bash
# Connect to target etcd
etcdctl --endpoints=https://target:2379 get / --prefix --limit=0

# Should return: "0 keys"
```

### 1.2 Take Note of Current State

Record the current Kubernetes version and any important configuration.

### 1.3 Test Migration in Non-Production

Before touching production:
1. Create a test environment with similar data
2. Run the full migration procedure
3. Verify the test cluster starts correctly
4. Document any issues

## Phase 2: Shutdown (Maintenance Window Start)

### 2.1 Stop All Kubernetes Components

On every node:

```bash
# Stop kubelet (this stops all pods)
systemctl stop kubelet

# Stop control plane components
systemctl stop kube-apiserver
systemctl stop kube-controller-manager
systemctl stop kube-scheduler
```

### 2.2 Verify No Active Writes

```bash
# Check etcd/Kine for recent activity
# No writes should occur during this window
```

## Phase 3: Migration

### 3.1 Create Dump from Source

```bash
etcd-migrator dump \
  --source-endpoints https://source-kine:2379 \
  --prefix /registry/ \
  --output /tmp/k8s-dump.jsonl
```

The dump will be created. Record the digest displayed.

### 3.2 Load Into Target

```bash
etcd-migrator load \
  --target-endpoints https://target-etcd:2379 \
  --input /tmp/k8s-dump.jsonl
```

### 3.3 Verify Migration

```bash
etcd-migrator verify \
  --source /tmp/k8s-dump.jsonl \
  --target-endpoints https://target-etcd:2379
```

Expected output: `Digest match`

## Phase 4: Startup

### 4.1 Update Kubernetes Configuration

Update kube-apiserver to use the new etcd endpoints:

```bash
# Update /etc/kubernetes/manifests/kube-apiserver.yaml
# Change --etcd-servers to point to new etcd
```

### 4.2 Start Control Plane

```bash
systemctl start kube-apiserver
systemctl start kube-controller-manager
systemctl start kube-scheduler
```

Wait for control plane to be healthy.

### 4.3 Start kubelet on Nodes

```bash
systemctl start kubelet
```

### 4.4 Verify Cluster Health

```bash
kubectl get nodes
kubectl get pods --all-namespaces
kubectl cluster-info
```

## Phase 5: Rollback (If Needed)

If migration fails:

### 5.1 Stop New Cluster

```bash
systemctl stop kubelet
systemctl stop kube-apiserver
systemctl stop kube-controller-manager
systemctl stop kube-scheduler
```

### 5.2 Revert Configuration

Update kube-apiserver to use original Kine endpoint.

### 5.3 Start Original Cluster

```bash
systemctl start kube-apiserver
systemctl start kube-controller-manager
systemctl start kube-scheduler
systemctl start kubelet
```

### 5.4 Verify Original Cluster

```bash
kubectl get nodes
kubectl cluster-info
```

## Troubleshooting

### Migration Hangs

- Check network connectivity
- Verify endpoints are correct
- Check for firewall issues

### Verification Fails

- Ensure target was empty before migration
- Check for concurrent writes during dump
- Re-run migration if needed

### Cluster Won't Start

- Check etcd logs for errors
- Verify all nodes point to new etcd
- Check for remaining Kine references

## Checklist

- [ ] Verified target is empty
- [ ] Stopped all Kubernetes components
- [ ] Verified no active writes
- [ ] Created dump from source
- [ ] Recorded source digest
- [ ] Loaded dump into target
- [ ] Verified digest match
- [ ] Updated kube-apiserver configuration
- [ ] Started control plane
- [ ] Started kubelet on all nodes
- [ ] Verified cluster health
