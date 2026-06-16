# ACT: Add full VM K3s PostgreSQL/Kine to standalone etcd migration lab

## Status: OPEN (implementation scaffold complete, awaiting live workflow proof)

## Implementation Summary

All implementation items have been completed:

- [x] Kine PostgreSQL source package (`internal/kine/`) - with correct Kine schema (id, name, created, deleted, create_revision, prev_revision, lease, value, old_value)
- [x] `dump-kine-postgres` command in CLI
- [x] `compare-dump-to-target` command in CLI
- [x] Lab script (`scripts/lab_k3s_postgres_kine_to_etcd.sh`)
- [x] Artifact verifier (`scripts/verify_k3s_postgres_kine_to_etcd_artifact.sh`) - fail-closed on non-empty target
- [x] GitHub Actions workflow (`.github/workflows/lab-k3s-postgres-kine-to-etcd.yml`)
- [x] Epic documentation (`docs/epics/k3s-postgres-kine-to-etcd-lab.md`)
- [x] Test fixtures (`fixtures/k3s_postgres_kine_to_etcd_artifact/`)
- [x] Quality gate passes (`go test ./...`, `go vet ./...`, `gofmt -l .`)

## Schema Fixes Applied

Based on hard blocker review:

1. **Kine Schema**: Now uses actual Kine PostgreSQL columns:
   - `id, name, created, deleted, create_revision, prev_revision, lease, value, old_value`
   - Filters to `deleted = 0` rows only
   - Skips `/prev`, `/next`, `/compact` marker keys

2. **PostgreSQL Driver**: Added `_ "github.com/lib/pq"` blank import for driver registration

3. **Compare Command**: Uses `DigestRecords` which hashes only key/value (not metadata), so comparison succeeds after etcd assigns fresh revisions

4. **Verifier Fail-Closed**: Non-empty target etcd now causes verifier failure, not just warning

5. **psql Row Count**: Uses `psql -At -c "SELECT count(*) FROM kine WHERE deleted = 0;"` for machine-readable output

6. **CLI Smoke Test**: Removed `|| true` from workflow build step; `--help` now properly validated

## Close Criteria

The ACT should close only after:

- [ ] Manual GitHub Actions workflow passes on a real runner
- [ ] Workflow artifacts uploaded proving all 7 phases ran successfully
- [ ] Artifact verifier passes on captured evidence
- [ ] Artifact safety scan passes

## Final Close Event

```text
[Closed / k3s PostgreSQL-Kine to standalone-etcd migration proof captured]
```

Only after real workflow artifacts are available.
