# Production Runbook: k3s Datastore Cutover Artifact Contract

**Contract version:** 1.0.0  
**Applies to:** k3s datastore cutover from Kine/PostgreSQL to etcd  
**Tool:** etcd-migrator preflight, dump, load, inspect  
**Audience:** SRE, platform engineers, release-governance reviewers

> **Purpose:** This document defines the mandatory artifact contract for any k3s datastore cutover attempt. It makes cutover auditable and fail-closed: operators must archive required artifacts, verify go/no-go classifications, confirm backup evidence exists, and have rollback artifacts prepared before touching the live k3s datastore.

> **Non-goal:** This contract does not implement a new migration engine or change the preflight JSON schema.

---

## 1. Artifact Inventory

Every attempted cutover must produce and retain the following artifact set. Artifacts are mandatory unless marked optional.

### 1.1 Preflight Artifacts

| Artifact | Purpose | Producer | Filename Pattern | Sensitive? | Retention | Go/No-Go Relevance |
|----------|---------|----------|------------------|------------|-----------|---------------------|
| `preflight.json` | Machine-readable readiness assessment | `etcd-migrator preflight` | `preflight-YYYYMMDD-HHMMSS.json` | No | Minimum 90 days post-cutover, or until burn-in completes | **Critical** — determines go/no-go |
| `preflight.txt` | Human-readable preflight summary | `etcd-migrator preflight` (text output) | `preflight-YYYYMMDD-HHMMSS.txt` | No | Same as above | **Critical** — audit trail |

> **Security note:** Operators must archive `preflight.json` before cutover. Do not rely solely on console output. Console output is ephemeral and may not survive an incident.

### 1.2 Source Datastore Backup Evidence

| Artifact | Purpose | Producer | Filename Pattern | Sensitive? | Retention | Go/No-Go Relevance |
|----------|---------|----------|------------------|------------|-----------|---------------------|
| PostgreSQL logical dump | Database backup for rollback | Operator (pg_dump, barman, etc.) | `postgres-backup-YYYYMMDD-HHMMSS.sql` or equivalent | **Yes** — contains cluster data | Minimum 90 days | **Mandatory** before cutover |
| PostgreSQL backup metadata | Proof of backup completion | Operator | `postgres-backup-metadata.json` | No | Same as above | **Mandatory** — confirms backup succeeded |
| Source dump artifact | etcd-migrator-produced JSONL dump | `etcd-migrator dump` | `source-dump-YYYYMMDD-HHMMSS.jsonl` | **Yes** — contains all K8s keys/values | Minimum 90 days | **Mandatory** — migration input |

### 1.3 Target etcd Evidence

| Artifact | Purpose | Producer | Filename Pattern | Sensitive? | Retention | Go/No-Go Relevance |
|----------|---------|----------|------------------|------------|-----------|---------------------|
| Target pre-cutover snapshot | Target state before migration (if non-empty) | Operator (etcdctl snapshot save) | `target-snapshot-pre-YYYYMMDD-HHMMSS.db` | No | Until cutover is confirmed stable | **Conditional** — required if target has existing data |
| Target etcd health report | Proof of target etcd health | `etcd-migrator inspect` or `etcdctl endpoint health` | `target-health-YYYYMMDD-HHMMSS.json` | No | Minimum 90 days | **Mandatory** — confirms target is healthy |

### 1.4 Migration/Import Command Transcript

| Artifact | Purpose | Producer | Filename Pattern | Sensitive? | Retention | Go/No-Go Relevance |
|----------|---------|----------|------------------|------------|-----------|---------------------|
| Migration command transcript | Proof of migration execution | Operator (scripted with tee/script) | `migration-transcript-YYYYMMDD-HHMMSS.log` | **Yes** — may contain endpoint URLs | Minimum 90 days | **Mandatory** — audit trail |
| Target post-migration status | Proof of post-migration state | `etcd-migrator inspect` | `target-post-migration-YYYYMMDD-HHMMSS.json` | No | Same as above | **Mandatory** — validation input |

### 1.5 Post-Import Validation Artifact

| Artifact | Purpose | Producer | Filename Pattern | Sensitive? | Retention | Go/No-Go Relevance |
|----------|---------|----------|------------------|------------|-----------|---------------------|
| Validation report | Digest comparison between source dump and target | `etcd-migrator inspect` | `validation-YYYYMMDD-HHMMSS.json` | No | Minimum 90 days | **Mandatory** — proves migration correctness |

### 1.6 Rollback Evidence

| Artifact | Purpose | Producer | Filename Pattern | Sensitive? | Retention | Go/No-Go Relevance |
|----------|---------|----------|------------------|------------|-----------|---------------------|
| Rollback command block | Exact rollback commands | Operator (documented from this runbook) | `rollback-commands-YYYYMMDD-HHMMSS.sh` | **Yes** — contains hostnames/paths | Until burn-in completes | **Mandatory** — must exist before cutover |
| Rollback command transcript | Proof of rollback (if rollback executed) | Operator | `rollback-transcript-YYYYMMDD-HHMMSS.log` | **Yes** — contains hostnames/paths | Minimum 90 days post-rollback | **Conditional** — only if rollback executed |
| Original k3s config | Configuration before changes | Operator | `k3s-config-original-YYYYMMDD-HHMMSS.yaml` | **Yes** — contains datastore endpoints | Minimum 90 days | **Mandatory** — rollback input |

### 1.7 CI Lab Reference Artifacts

| Artifact | Purpose | Producer | Filename Pattern | Sensitive? | Retention | Go/No-Go Relevance |
|----------|---------|----------|------------------|------------|-----------|---------------------|
| CI lab preflight artifact | Proof of lab rehearsal | CI (etcd-migrator preflight) | `ci-lab-preflight-*.json` | No | Minimum 90 days | **Context** — proves rehearsed mechanism works |
| CI lab validation artifact | Proof of lab migration success | CI (etcd-migrator inspect) | `ci-lab-validation-*.json` | No | Same as above | **Context** — proves rehearsed mechanism is correct |

---

## 2. preflight.json Consumption Contract

Production operators **must** archive `preflight.json` before cutover. This is not optional.

### 2.1 Required Fields to Inspect

Before cutover, operators must inspect the following fields in `preflight.json`:

| Field Path | Type | Required? | Inspection Guidance |
|------------|------|-----------|---------------------|
| `go_no_go` | boolean | **Yes** | `true` = potentially safe to proceed, `false` = NO-GO unless explicitly documented |
| `classification` | string | **Yes** | See Section 3 (Go/No-Go Matrix) for semantics |
| `source_endpoint.healthy` | boolean | **Yes** | Must be `true` for any GO decision |
| `source_endpoint.endpoints` | array | **Yes** | Verify endpoints are correct |
| `source_endpoint.error` | string | If unhealthy | Note the error message for diagnosis |
| `target_endpoint.healthy` | boolean | **Yes** | Must be `true` for any GO decision |
| `target_endpoint.endpoints` | array | **Yes** | Verify endpoints are correct |
| `target_endpoint.error` | string | If unhealthy | Note the error message for diagnosis |
| `prefix` | string | **Yes** | Verify this matches the intended migration prefix |
| `conflict_policy` | string | **Yes** | Verify this matches the intended policy |
| `source_prefix_key_count` | integer | **Yes** | Non-zero indicates data to migrate |
| `target_prefix_key_count` | integer | **Yes** | Zero for `fresh-import`, non-zero may indicate conflict |
| `errors` | array | **Yes** | Must be empty for GO decision |
| `warnings` | array | **Yes** | Inspect warnings for non-fatal concerns |
| `tool_version` | string | **Yes** | Record for reproducibility |
| `timestamp` | string | **Yes** | Verify this is recent (within maintenance window) |

### 2.2 Production Preflight Archival Requirement

```
PREREQUISITE: Before cutover, archive preflight.json
COMMAND:     cp preflight-*.json /path/to/secure-artifact-store/
RATIONALE:   Console output is ephemeral; preflight.json is the authoritative record
```

### 2.3 Current Schema Notes

The current `preflight.json` schema exposes the following fields that are documented above:
- `go_no_go`, `classification`, `source_endpoint`, `target_endpoint`, `prefix`, `conflict_policy`, `source_prefix_key_count`, `target_prefix_key_count`, `warnings`, `errors`, `tool_version`, `timestamp`

**TODO (non-breaking):** Add `run_id` or `execution_id` field for traceability across multiple invocations.

**TODO (non-breaking):** Add `source_type` and `target_type` fields to distinguish between etcd, Kine, and other backend types.

---

## 3. Go/No-Go Matrix

Every preflight `classification` has explicit GO/NO-GO semantics. The default rule is: **any unrecognized classification is NO-GO**.

| Classification | Go/No-Go | Conditions for GO | Operator Action |
|----------------|----------|-------------------|-----------------|
| `fresh-import` | **GO** | Source is healthy, target is healthy, source backup exists, rollback evidence exists, target is empty within migration prefix | Proceed with cutover |
| `identical-replay` | **GO (conditional)** | Conflict policy explicitly allows `allow-identical-replay`, operator intentionally replaying same source data, backup exists, rollback evidence exists | Operator must acknowledge they are replaying identical data |
| `conflict` | **NO-GO** | None | Operator **must stop**. Inspect target contents and backups. Resolve conflict before proceeding |
| `empty-source` | **NO-GO** | None for production cutover | Production cutover is not appropriate. Only for documented dry runs or intentionally empty lab scenarios |
| `unhealthy-source` | **NO-GO** | None | Source etcd must be healthy before cutover. Investigate and resolve |
| `unhealthy-target` | **NO-GO** | None | Target etcd must be healthy before cutover. Investigate and resolve |
| `invalid-prefix` | **NO-GO** | None | Prefix must be valid. Check prefix configuration |
| `unknown` | **NO-GO** | None | Preflight encountered an unexpected state. Do not cut over |
| *(any unrecognized)* | **NO-GO** | None (default) | Treat as NO-GO. Document and escalate |

### 3.1 Go Decision Requirements

For a `fresh-import` or `identical-replay` GO decision, **all** of the following must be true:

1. [ ] `go_no_go` is `true` in `preflight.json`
2. [ ] `classification` is `fresh-import` or `identical-replay` (with explicit acknowledgment)
3. [ ] `source_endpoint.healthy` is `true`
4. [ ] `target_endpoint.healthy` is `true`
5. [ ] Source datastore backup evidence exists (see Section 4)
6. [ ] Rollback command block is prepared and accessible (see Section 5)
7. [ ] `preflight.json` is archived (see Section 2.2)
8. [ ] Maintenance window is approved
9. [ ] Operator has shell access to k3s node and datastore hosts

---

## 4. Backup Evidence Contract

Backup evidence must exist and be verified **before cutover begins**.

### 4.1 Kine/PostgreSQL Source Backup

| Requirement | Detail |
|-------------|--------|
| Backup command | PostgreSQL logical dump: `pg_dump -Fc -f <backup-file> <database>` or physical backup via barman |
| Artifact filename | `postgres-backup-YYYYMMDD-HHMMSS.dump` or equivalent |
| Command exit status | Must be `0` (success) |
| Size evidence | Record size in bytes (e.g., `ls -la postgres-backup-*.dump`) |
| Hash evidence | Record SHA256: `sha256sum postgres-backup-*.dump > postgres-backup-*.sha256` |
| Restore-readiness note | Test restore in lab before production cutover |

### 4.2 k3s Current Datastore State

| Requirement | Detail |
|-------------|--------|
| k3s service state | Before cutover: `systemctl is-active k3s` should return `active` |
| Datastore config evidence | Copy of `/etc/k3s/k3s.yaml` with datastore endpoints (redact tokens) |
| Source dump artifact | Generated by `etcd-migrator dump --source-endpoints <endpoints> --prefix <prefix> --output source-dump.jsonl` |
| Source dump hash | Record SHA256 of dump: `sha256sum source-dump-*.jsonl > source-dump-*.sha256` |

### 4.3 Target etcd Evidence

| Requirement | Detail |
|-------------|--------|
| etcd endpoint health | All target endpoints must respond: `etcdctl --endpoints=<endpoints> endpoint health` |
| Snapshot evidence (if non-empty) | If target contains pre-existing data under migration prefix: `etcdctl snapshot save target-snapshot-pre.db` |
| Member list/status | `etcdctl --endpoints=<endpoints> member list` |

### 4.4 Security: Sensitive Artifact Handling

> **WARNING:** The following must **NEVER** be stored in public CI artifacts or shared artifact stores:
> - Raw Kubernetes Secret values
> - kubeconfig client key material
> - PostgreSQL passwords or connection strings
> - Bearer tokens, authorization tokens
> - Unredacted DSNs (database connection strings)
> - Private keys (RSA, EC, etc.)

**Required practice:**
- Redact secrets before archiving artifacts for audit
- Use placeholder values in CI artifacts: `<REDACTED>`, `***`, `CONNECTION_STRING_REDACTED`
- Keep raw secrets in a secure, access-controlled secrets store (HashiCorp Vault, AWS Secrets Manager, etc.)
- Artifacts that accidentally contain secrets must be immediately invalidated and regenerated

---

## 5. Rollback Readiness Contract

Rollback must be **ready before cutover starts**. Operators must have all rollback artifacts prepared and verified.

### 5.1 Rollback Artifact Requirements

| Artifact | Purpose | When Required |
|----------|---------|---------------|
| Original k3s datastore configuration | k3s config before cutover | Always |
| Original systemd unit/environment backup | If k3s service was modified | If modified |
| Source datastore backup path | To restore source datastore | Always |
| Target etcd pre-cutover snapshot path | To restore target etcd | If target had existing data |
| Rollback command block | Exact commands to execute | Always |
| Verification command block | Commands to verify rollback success | Always |

### 5.2 Rollback Command Skeletons

Use these placeholders where environment-specific values are needed. **Do not invent real hostnames, credentials, or secret values.**

#### 5.2.1 Stop k3s

```bash
# Stop k3s service on control plane node(s)
sudo systemctl stop k3s

# Verify k3s is stopped
sudo systemctl is-active k3s
# Expected output: "inactive" or "failed"
```

#### 5.2.2 Restore Previous k3s Datastore Configuration

```bash
# Restore k3s configuration from backup
sudo cp /path/to/backup/k3s-config-original-<timestamp>.yaml /etc/k3s/k3s.yaml

# If k3s uses environment file, restore it
sudo cp /path/to/backup/k3s.env-backup-<timestamp> /etc/systemd/system/k3s.service.d/10-k3s.env
sudo systemctl daemon-reload
```

#### 5.2.3 Restore/Repoint to Previous Kine/PostgreSQL Datastore

```bash
# Verify PostgreSQL is accessible
pg_isready -h <KINE_POSTGRES_HOST> -p 5432

# Point k3s back to Kine endpoint
# Edit /etc/k3s/k3s.yaml or /etc/k3s/k3s-arg-file if used
sudo vi /etc/k3s/k3s.yaml
# Set datastore-endpoint to: postgresql://<KINE_USER>@<KINE_POSTGRES_HOST>:<KINE_PORT>/<KINE_DATABASE>

# Update k3s to use Kine (if switching back from external etcd)
sudo systemctl set-environment K3S_DATASTORE_ENDPOINT="postgresql://<KINE_USER>@<KINE_POSTGRES_HOST>:<KINE_PORT>/<KINE_DATABASE>?sslmode=require"
sudo systemctl daemon-reload
```

#### 5.2.4 Restart k3s

```bash
# Restart k3s service
sudo systemctl start k3s

# Wait for k3s to be ready
sleep 30

# Check k3s service status
sudo systemctl status k3s --no-pager
```

#### 5.2.5 Verify Node Readiness

```bash
# Check node status (run from a node that can reach the cluster)
kubectl get nodes -o wide
# Expected: All nodes should be "Ready"

# Check for any pod errors in kube-system
kubectl get pods -n kube-system
# Expected: All pods should be "Running" or "Completed"
```

#### 5.2.6 Verify Kubernetes API Health

```bash
# Verify API server is responding
kubectl cluster-info
# Expected: "Kubernetes control plane is running"

# Verify API server version
kubectl version --short
# Expected: Server version displayed

# Verify core API resources are accessible
kubectl api-resources
# Expected: List of API resources displayed
```

#### 5.2.7 Verify No Unintended Target etcd Dependency Remains

```bash
# Check that k3s is NOT connected to target etcd
# This depends on k3s configuration; verify datastore endpoint
grep -r "K3S_DATASTORE_ENDPOINT" /etc/systemd/system/k3s.service.d/ 2>/dev/null || echo "K3S_DATASTORE_ENDPOINT not found in override files"
grep "K3S_DATASTORE_ENDPOINT" /var/lib/rancher/k3s/server/arg/env 2>/dev/null || echo "K3S_DATASTORE_ENDPOINT not found in k3s env file"

# If using Kine, verify Kine is the datastore
curl -s https://<KINE_ENDPOINT>:2379/health 2>/dev/null || echo "Kine endpoint not responding (expected if using Kine on different host)"
```

### 5.3 Post-Rollback Verification

After executing rollback, verify:

1. [ ] k3s service is `active`
2. [ ] All nodes are `Ready`
3. [ ] Core pods in `kube-system` are `Running` or `Completed`
4. [ ] `kubectl cluster-info` succeeds
5. [ ] No etcd connection to target cluster remains in k3s configuration
6. [ ] Workloads are healthy (or acceptably degraded if rollback is partial)

---

## 6. Production Cutover Checklist

### Phase 1: Before Cutover

- [ ] **Green CI lab artifacts**: CI lab preflight and validation artifacts exist and show success
- [ ] **Archived preflight.json**: `preflight.json` copied to secure artifact store
- [ ] **GO classification**: `preflight.json` shows `classification: fresh-import` or `identical-replay` (with explicit acknowledgment)
- [ ] **Backup evidence exists**:
  - [ ] PostgreSQL backup artifact exists with size/hash evidence
  - [ ] Source dump artifact exists with SHA256 recorded
  - [ ] Target etcd health report exists (or target was verified empty)
- [ ] **Rollback command block prepared**: `rollback-commands-*.sh` exists and is reviewed
- [ ] **Maintenance window approved**: Change management ticket is open
- [ ] **Operator access verified**: Shell access to k3s node and datastore hosts confirmed

### Phase 2: During Cutover

- [ ] **Stop k3s**: `sudo systemctl stop k3s` on all control plane nodes
- [ ] **Take final backup/dump**: Run `etcd-migrator dump` to capture final source state
- [ ] **Run migration/import**: `etcd-migrator load` into target etcd
- [ ] **Validate target etcd**: Run `etcd-migrator inspect` and compare digests
- [ ] **Update k3s datastore config**: Point k3s to target etcd endpoints
- [ ] **Start k3s**: `sudo systemctl start k3s` on control plane nodes
- [ ] **Verify API health**: `kubectl cluster-info` and `kubectl get nodes`

### Phase 3: After Cutover

- [ ] **Archive validation artifacts**: Copy `validation-*.json` to secure artifact store
- [ ] **Inspect k3s node readiness**: `kubectl get nodes` shows all nodes `Ready`
- [ ] **Inspect critical system namespaces**: Verify pods in `kube-system`, `default`, and critical application namespaces are healthy
- [ ] **Retain rollback artifacts until burn-in period completes**: Keep rollback command block, original config, and source dump until cutover is confirmed stable (minimum 24-48 hours, or until next maintenance window)

---

## 7. CI/Lab Artifact Relationship

Understanding the relationship between CI lab artifacts and production preflight artifacts is critical for safe cutover.

| Aspect | CI Lab Artifacts | Production Preflight Artifacts |
|--------|------------------|-------------------------------|
| **Purpose** | Prove rehearsed mechanism works | Prove live source/target state at cutover time |
| **Source** | CI pipeline | Live production environment |
| **When generated** | During CI run | During preflight execution before cutover |
| **Authority** | **Context only** | **Binding for go/no-go decision** |
| **Can substitute for production preflight?** | **No** | **No** |
| **Must exist for production cutover?** | **Yes** (context) | **Yes** (binding) |

### Key Principles

1. **CI lab success is NOT a substitute for production preflight.** CI proves the mechanism works in a controlled environment. Production preflight proves the specific source/target state is safe for cutover.

2. **Production preflight is NOT a substitute for backups.** Preflight is a readiness check, not a backup.

3. **Both must be retained for auditability.** CI artifacts and production artifacts together form the complete cutover audit trail.

4. **Production go decision requires:**
   - Live `preflight.json` with GO classification
   - Backup evidence exists
   - Rollback evidence is prepared

---

## 8. Runbook Contract Verifier

A verifier script is provided to check that this runbook contract document is complete and mentions all required terms.

### 8.1 Verifier Script

```bash
scripts/verify_runbook_contract.sh [--self-test | <runbook-file>]
```

### 8.2 Verifier Behavior

The verifier fails if the runbook does not mention the following core required terms:

- `preflight.json`
- `fresh-import`
- `identical-replay`
- `conflict`
- `unhealthy-source`
- `unhealthy-target`
- `invalid-prefix`
- `unknown`
- `rollback`
- `backup`
- `NO-GO`
- `GO`

### 8.3 Integration with Quality Gate

This verifier is documented as a local verifier. To wire into `make gate`, add the following to `Makefile`:

```makefile
.PHONY: verify-runbook-contract
verify-runbook-contract:
	@echo "Running runbook contract verifier self-test..."
	@bash scripts/verify_runbook_contract.sh --self-test

gate: vet fmt-check test verify-artifact verify-replay-artifact verify-preflight-artifact verify-runbook-contract
	@echo "✓ Quality gate passed"
```

This integration is a **follow-up** item and is not required to close this ACT.

---

## 9. Follow-Up Items (Non-Breaking)

The following items are intentionally deferred and do not block this ACT:

| Item | Description | Priority |
|------|-------------|----------|
| `preflight.json` schema extension | Add `run_id` field for traceability | Low |
| `preflight.json` schema extension | Add `source_type` and `target_type` fields | Low |
| Quality gate integration | Wire `verify-runbook-contract` into `make gate` | Low |
| Rollback testing evidence | Document actual rollback test in production (when available) | Medium |

---

## 10. Close Criteria

This ACT is **closed** when:

- [x] A named production runbook/artifact contract exists under `docs/runbooks/k3s-datastore-cutover.md`
- [x] `preflight.json` has a documented operator consumption contract (Section 2)
- [x] Every known preflight classification has explicit GO/NO-GO semantics (Section 3)
- [x] Backup evidence requirements are documented before cutover (Section 4)
- [x] Rollback artifacts and rollback command skeletons are documented before cutover (Section 5)
- [x] CI lab artifacts are clearly distinguished from production preflight artifacts (Section 7)
- [x] Sensitive artifact handling is documented (Section 4.4)
- [x] Any verifier added has self-test or clear deterministic checks (Section 8)

### Suggested Close Bar

This ACT is **only closed** when the runbook makes it **impossible for an operator to confuse "CI lab green" with "production cutover safe."** The production go decision must require live `preflight.json`, backup evidence, and rollback readiness together.

---

## Revision History

| Version | Date | Author | Change |
|---------|------|--------|--------|
| 1.0.0 | 2026-06-16 | etcd-migrator team | Initial production runbook artifact contract |
