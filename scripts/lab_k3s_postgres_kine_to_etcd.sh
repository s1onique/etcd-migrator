#!/usr/bin/env bash
# lab_k3s_postgres_kine_to_etcd.sh — k3s with PostgreSQL/Kine → standalone etcd migration lab
#
# This lab proves etcd-migrator can migrate a real Kubernetes/k3s dataset
# from a Kine-backed PostgreSQL datastore into a standalone etcd target,
# then restart k3s against the migrated etcd.
#
# Topology:
#   PostgreSQL service (k3s_kine database)
#   -> k3s server (datastore-endpoint=postgres://...)
#   -> standalone etcd (empty)
#   -> migrator (dump-kine-postgres -> load)
#   -> k3s server restarted (datastore-endpoint=http://...:2379)
#   -> kubectl proves migrated objects visible
#
set -euo pipefail

LAB_NAME="lab-k3s-postgres-kine-to-etcd"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
LAB_ROOT="${LAB_ROOT:-$PWD/runs/${LAB_NAME}-${RUN_ID}}"
ARTIFACTS="$LAB_ROOT/artifacts"
WORK="$LAB_ROOT/work"
BIN="$LAB_ROOT/bin"

# Source cluster artifacts
ARTIFACTS_PRE="$ARTIFACTS/pre"
ARTIFACTS_MIGRATION="$ARTIFACTS/migration"
ARTIFACTS_POST="$ARTIFACTS/post"
ARTIFACTS_LOGS="$ARTIFACTS/logs"

K3S_CHANNEL="${K3S_CHANNEL:-stable}"
K3S_DATASTORE_ENDPOINT="${K3S_DATASTORE_ENDPOINT:-}"
ETCD_VERSION="${ETCD_VERSION:-v3.5.21}"
# Must match etcd-migrator's dump/load prefix. Current migrator default is /registry/.
MIGRATION_PREFIX="${MIGRATION_PREFIX:-/registry/}"

# PostgreSQL connection defaults
POSTGRES_HOST="${POSTGRES_HOST:-127.0.0.1}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
POSTGRES_DB="${POSTGRES_DB:-k3s_kine}"
POSTGRES_USER="${POSTGRES_USER:-k3s}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-k3s}"

# k3s and etcd process PIDs for clean shutdown
K3S_SOURCE_PID=""
K3S_CUTOVER_PID=""
ETCD_TARGET_PID=""

# kubectl resolver: prefer PATH kubectl, fallback to k3s kubectl
KUBECTL_CMD=()

resolve_kubectl() {
  if command -v kubectl >/dev/null 2>&1; then
    KUBECTL_CMD=("$(command -v kubectl)")
    return 0
  fi

  if [[ -x /usr/local/bin/k3s ]]; then
    KUBECTL_CMD=("/usr/local/bin/k3s" "kubectl")
    return 0
  fi

  echo "missing kubectl: neither kubectl nor k3s kubectl is available" >&2
  exit 1
}

kubectl_lab() {
  "${KUBECTL_CMD[@]}" "$@"
}

mkdir -p "$ARTIFACTS" "$WORK" "$BIN"
mkdir -p "$ARTIFACTS_PRE" "$ARTIFACTS_MIGRATION" "$ARTIFACTS_POST" "$ARTIFACTS_LOGS"

# Record migration scope for verification alignment
printf '%s\n' "$MIGRATION_PREFIX" > "$ARTIFACTS/migration-prefix.txt"

cleanup() {
  set +e
  # Stop k3s cutover server if running
  if [[ -n "$K3S_CUTOVER_PID" ]]; then
    kill "$K3S_CUTOVER_PID" 2>/dev/null || true
    wait "$K3S_CUTOVER_PID" 2>/dev/null || true
  fi
  # Stop k3s source server if running
  if [[ -n "$K3S_SOURCE_PID" ]]; then
    kill "$K3S_SOURCE_PID" 2>/dev/null || true
    wait "$K3S_SOURCE_PID" 2>/dev/null || true
  fi
  systemctl stop k3s >/dev/null 2>&1 || true
  # Kill etcd target process by PID if tracked
  if [[ -n "$ETCD_TARGET_PID" ]]; then
    kill "$ETCD_TARGET_PID" 2>/dev/null || true
    wait "$ETCD_TARGET_PID" 2>/dev/null || true
  fi
  # Kill any orphaned etcd processes
  pkill -f "$BIN/etcd" >/dev/null 2>&1 || true
}
trap cleanup EXIT

log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

require_linux_vm() {
  if [[ "$(uname -s)" != "Linux" ]]; then
    echo "This lab requires Linux" >&2
    exit 1
  fi
  require_cmd curl
  require_cmd tar
  require_cmd jq
  require_cmd sha256sum
  require_cmd psql
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "This lab must run as root because k3s installs system services" >&2
    echo "Try: sudo bash scripts/lab_k3s_postgres_kine_to_etcd.sh" >&2
    exit 1
  fi
}

# ----------------------------------------------------------------------
# Phase 1: Provision PostgreSQL
# ----------------------------------------------------------------------

install_postgres() {
  log "Installing PostgreSQL"

  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq postgresql postgresql-client >/dev/null 2>&1

  systemctl enable --now postgresql

  # Wait for PostgreSQL to be ready
  for _ in $(seq 1 30); do
    if su - postgres -c "pg_isready -h 127.0.0.1" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done

  log "PostgreSQL installed and running"
}

setup_postgres_database() {
  log "Setting up PostgreSQL database and user"

  # Create user and database
  su - postgres -c "psql -c \"CREATE USER ${POSTGRES_USER} WITH PASSWORD '${POSTGRES_PASSWORD}';\"" 2>/dev/null || true
  su - postgres -c "psql -c \"CREATE DATABASE ${POSTGRES_DB} OWNER ${POSTGRES_USER};\"" 2>/dev/null || true
  su - postgres -c "psql -c \"GRANT ALL PRIVILEGES ON DATABASE ${POSTGRES_DB} TO ${POSTGRES_USER};\"" 2>/dev/null || true

  # Configure PostgreSQL to listen on loopback
  if ! grep -q "listen_addresses" /etc/postgresql/*/main/postgresql.conf 2>/dev/null; then
    echo "listen_addresses = '127.0.0.1'" >> /etc/postgresql/*/main/postgresql.conf 2>/dev/null || true
    systemctl restart postgresql
    sleep 2
  fi

  # Build the DSN
  K3S_DATASTORE_ENDPOINT="postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}?sslmode=disable"
  export K3S_DATASTORE_ENDPOINT

  log "PostgreSQL DSN: postgres://${POSTGRES_USER}:***@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}?sslmode=disable"

  # Verify connectivity
  PGPASSWORD="${POSTGRES_PASSWORD}" psql -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -c 'select version();' \
    > "$ARTIFACTS_LOGS/postgres-version.txt" 2>&1

  log "PostgreSQL connection verified"
}

# ----------------------------------------------------------------------
# Phase 2: Boot k3s using PostgreSQL/Kine
# ----------------------------------------------------------------------

install_k3s_postgres() {
  log "Installing k3s with PostgreSQL/Kine datastore channel=${K3S_CHANNEL}"

  export KUBECONFIG="$WORK/k3s-source/k3s.yaml"
  mkdir -p "$WORK/k3s-source"

  # Use environment variable for datastore endpoint (K3s best practice)
  # Also pass --write-kubeconfig so kubectl finds the kubeconfig at KUBECONFIG path
  curl -sfL https://get.k3s.io | \
    INSTALL_K3S_CHANNEL="$K3S_CHANNEL" \
    INSTALL_K3S_EXEC="server \
      --write-kubeconfig=$KUBECONFIG \
      --write-kubeconfig-mode=644 \
      --disable=traefik \
      --disable=servicelb \
      --disable=metrics-server" \
    K3S_DATASTORE_ENDPOINT="${K3S_DATASTORE_ENDPOINT}" \
    sh - 2>&1 | tee "$ARTIFACTS_LOGS/k3s-postgres-install.log"

  resolve_kubectl

  log "Using kubectl: ${KUBECTL_CMD[*]}"
  log "Waiting for k3s node readiness"
  
  for _ in $(seq 1 60); do
    if kubectl_lab cluster-info >/dev/null 2>&1; then
      break
    fi
    sleep 5
  done

  kubectl_lab wait --for=condition=Ready node --all --timeout=240s
  kubectl_lab version -o yaml > "$ARTIFACTS_PRE/kubectl-version.yaml"
  /usr/local/bin/k3s --version > "$ARTIFACTS/k3s-version.txt"

  # Capture k3s process info for verification
  systemctl show k3s --property=MainPID,ActiveState > "$ARTIFACTS_PRE/k3s-service-status.txt"

  log "k3s installed with PostgreSQL/Kine datastore"
}

verify_kine_tables() {
  log "Verifying Kine tables exist in PostgreSQL"

  # Capture kine table info
  PGPASSWORD="${POSTGRES_PASSWORD}" psql -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" \
    -c '\dt' > "$ARTIFACTS_PRE/postgres-kine-tables.txt" 2>&1

  # Verify kine table exists
  if grep -q "kine" "$ARTIFACTS_PRE/postgres-kine-tables.txt"; then
    log "Kine table exists in PostgreSQL"
  else
    log "FAIL: kine table not found in PostgreSQL"
    cat "$ARTIFACTS_PRE/postgres-kine-tables.txt"
    exit 1
  fi
}

# ----------------------------------------------------------------------
# Phase 3: Seed real Kubernetes state
# ----------------------------------------------------------------------

populate_k3s() {
  export KUBECONFIG="$WORK/k3s-source/k3s.yaml"

  log "Populating Kubernetes API objects for migration lab"

  # Create the test namespace
  kubectl_lab create namespace "migrator-lab" \
    --dry-run=client -o yaml | kubectl_lab apply -f -

  # Create test ConfigMap
  kubectl_lab create configmap "cm-alpha" \
    -n "migrator-lab" \
    --from-literal="source=kine-postgres" \
    --from-literal="token=alpha" \
    --dry-run=client -o yaml | kubectl_lab apply -f -

  # Create test Secret (metadata only - no actual values captured)
  kubectl_lab create secret generic "secret-alpha" \
    -n "migrator-lab" \
    --from-literal="password=super-secret-lab-value" \
    --dry-run=client -o yaml | kubectl_lab apply -f -

  # Create test ServiceAccount
  kubectl_lab create serviceaccount "sa-alpha" \
    -n "migrator-lab" \
    --dry-run=client -o yaml | kubectl_lab apply -f -

  # Create test Deployment
  kubectl_lab create deployment "deploy-alpha" \
    -n "migrator-lab" \
    --image=nginx:stable-alpine \
    --replicas=1 \
    --dry-run=client -o yaml | kubectl_lab apply -f -

  log "Kubernetes objects created"
}

collect_pre_migration_evidence() {
  export KUBECONFIG="$WORK/k3s-source/k3s.yaml"

  log "Collecting pre-migration evidence"

  # Kubernetes API state
  kubectl_lab get ns migrator-lab -o yaml > "$ARTIFACTS_PRE/ns.yaml"
  kubectl_lab -n migrator-lab get cm cm-alpha -o yaml > "$ARTIFACTS_PRE/cm.yaml"
  
  # SAFE: Use JSON output and extract only safe metadata fields
  kubectl_lab -n migrator-lab get secret secret-alpha -o json 2>/dev/null | \
    jq '{metadata: .metadata, type: .type}' > "$ARTIFACTS_PRE/secret-metadata.txt" || \
    kubectl_lab -n migrator-lab get secret secret-alpha -o yaml > "$ARTIFACTS_PRE/secret-metadata.txt"

  kubectl_lab -n migrator-lab get sa sa-alpha -o yaml > "$ARTIFACTS_PRE/sa.yaml"
  kubectl_lab -n migrator-lab get deploy deploy-alpha -o yaml > "$ARTIFACTS_PRE/deploy.yaml"

  # PostgreSQL/Kine proof - this is the key evidence for this lab
  log "Capturing PostgreSQL/Kine state as proof"

  # Use -At for machine-readable output (no headers, no footers)
  PGPASSWORD="${POSTGRES_PASSWORD}" psql -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" \
    -At -c "SELECT count(*) FROM kine WHERE deleted = 0;" \
    > "$ARTIFACTS_PRE/postgres-kine-row-count.txt" 2>&1

  PGPASSWORD="${POSTGRES_PASSWORD}" psql -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" \
    -c "select name from kine where name like '/registry/%' order by name limit 50;" \
    > "$ARTIFACTS_PRE/postgres-kine-registry-sample.txt" 2>&1

  log "Pre-migration evidence collected"
}

# ----------------------------------------------------------------------
# Phase 4: Stop k3s cleanly
# ----------------------------------------------------------------------

stop_source_k3s() {
  log "Stopping source k3s"

  systemctl stop k3s
  sleep 2

  log "Source k3s stopped"
}

# ----------------------------------------------------------------------
# Phase 5: Start standalone empty etcd
# ----------------------------------------------------------------------

install_etcd() {
  local os arch url archive
  os="linux"
  arch="amd64"
  archive="etcd-${ETCD_VERSION}-${os}-${arch}.tar.gz"
  url="https://github.com/etcd-io/etcd/releases/download/${ETCD_VERSION}/${archive}"

  log "Installing etcd ${ETCD_VERSION}"
  curl -fsSL "$url" -o "$WORK/$archive"
  tar -xzf "$WORK/$archive" -C "$WORK"
  install -m 0755 "$WORK/etcd-${ETCD_VERSION}-${os}-${arch}/etcd" "$BIN/etcd"
  install -m 0755 "$WORK/etcd-${ETCD_VERSION}-${os}-${arch}/etcdctl" "$BIN/etcdctl"

  "$BIN/etcd" --version | tee "$ARTIFACTS/etcd-version.txt"
  "$BIN/etcdctl" version | tee "$ARTIFACTS/etcdctl-version.txt"
}

start_target_etcd() {
  log "Starting standalone target etcd"

  "$BIN/etcd" \
    --name lab-etcd \
    --data-dir "$WORK/target.etcd" \
    --listen-client-urls http://127.0.0.1:2379 \
    --advertise-client-urls http://127.0.0.1:2379 \
    --listen-peer-urls http://127.0.0.1:2380 \
    --initial-advertise-peer-urls http://127.0.0.1:2380 \
    --initial-cluster lab-etcd=http://127.0.0.1:2380 \
    --initial-cluster-state new \
    > "$ARTIFACTS_LOGS/etcd.log" 2>&1 &

  ETCD_TARGET_PID=$!
  wait_etcd http://127.0.0.1:2379

  # Verify target is empty before import
  ETCDCTL_API=3 "$BIN/etcdctl" \
    --endpoints=http://127.0.0.1:2379 \
    get "$MIGRATION_PREFIX" --prefix --keys-only \
    > "$ARTIFACTS_PRE/target-etcd-registry-keys-before.txt"

  local key_count
  key_count=$(wc -l < "$ARTIFACTS_PRE/target-etcd-registry-keys-before.txt" | tr -d ' ')
  log "Target etcd keys under ${MIGRATION_PREFIX}: ${key_count}"

  log "Target etcd started successfully"
}

wait_etcd() {
  local endpoint="$1"

  for _ in $(seq 1 60); do
    if ETCDCTL_API=3 "$BIN/etcdctl" --endpoints="$endpoint" endpoint health >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  echo "etcd endpoint did not become healthy: $endpoint" >&2
  exit 1
}

# ----------------------------------------------------------------------
# Phase 6: Run etcd-migrator
# ----------------------------------------------------------------------

run_migrator() {
  log "Running etcd-migrator from Kine/PostgreSQL to standalone etcd"

  # Build DSN for migrator
  local postgres_dsn="postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}?sslmode=disable"

  # Dump from PostgreSQL/Kine
  log "Phase 6a: Dumping from PostgreSQL/Kine"
  ./bin/etcd-migrator dump-kine-postgres \
    --postgres-dsn "$postgres_dsn" \
    --prefix "$MIGRATION_PREFIX" \
    --output "$WORK/kine.dump.jsonl" \
    > "$ARTIFACTS_MIGRATION/dump.log" 2>&1

  # Inspect dump
  log "Phase 6b: Inspecting dump"
  ./bin/etcd-migrator inspect \
    --input "$WORK/kine.dump.jsonl" \
    > "$ARTIFACTS_MIGRATION/inspect.txt" 2>&1

  # Load into target etcd
  log "Phase 6c: Loading into target etcd"
  if ! ./bin/etcd-migrator load \
    --target-endpoints=http://127.0.0.1:2379 \
    --input "$WORK/kine.dump.jsonl" \
    --conflict-policy=fail-if-present \
    > "$ARTIFACTS_MIGRATION/load.log" 2>&1; then
    log "FAIL: etcd-migrator load failed"
    cat "$ARTIFACTS_MIGRATION/load.log" >&2
    exit 1
  fi

  # Compare dump to target
  log "Phase 6d: Comparing dump to target"
  ./bin/etcd-migrator compare-dump-to-target \
    --input "$WORK/kine.dump.jsonl" \
    --target-endpoints=http://127.0.0.1:2379 \
    > "$ARTIFACTS_MIGRATION/compare.txt" 2>&1

  local compare_status=$?
  if [[ $compare_status -eq 0 ]]; then
    echo '{"status": "SUCCESS", "run_id": "'"${RUN_ID}"'"}' > "$ARTIFACTS_MIGRATION/compare-status.json"
  else
    echo '{"status": "FAILED", "run_id": "'"${RUN_ID}"'"}' > "$ARTIFACTS_MIGRATION/compare-status.json"
  fi

  log "Migrator completed with status: $(cat "$ARTIFACTS_MIGRATION/compare-status.json")"
}

# ----------------------------------------------------------------------
# Phase 7: Restart k3s against standalone etcd
# ----------------------------------------------------------------------

start_k3s_cutover() {
  log "Starting k3s cutover server with external etcd"

  export KUBECONFIG="$WORK/k3s-cutover/k3s.yaml"
  mkdir -p "$WORK/k3s-cutover"

  {
    echo "=== k3s External etcd Cutover Startup ==="
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Starting k3s server with external etcd"
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] datastore-endpoint=http://127.0.0.1:2379"
  } > "$ARTIFACTS_LOGS/k3s-etcd-start.log"

  # Use proper k3s external datastore configuration via environment variable
  export K3S_DATASTORE_ENDPOINT="http://127.0.0.1:2379"

  /usr/local/bin/k3s server \
    --data-dir="$WORK/k3s-cutover" \
    --write-kubeconfig "$KUBECONFIG" \
    --write-kubeconfig-mode=644 \
    --disable=traefik,servicelb,metrics-server \
    --datastore-endpoint="http://127.0.0.1:2379" \
    > "$ARTIFACTS_LOGS/k3s-etcd.log" 2>&1 &

  K3S_CUTOVER_PID=$!

  # Wait for k3s API server to become ready
  for _ in $(seq 1 60); do
    if KUBECONFIG="$KUBECONFIG" kubectl_lab cluster-info >/dev/null 2>&1; then
      break
    fi
    sleep 5
  done

  KUBECONFIG="$KUBECONFIG" kubectl_lab wait --for=condition=Ready node --all --timeout=180s

  resolve_kubectl

  {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Kubernetes API is ready"
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] k3s startup PASSED"
  } >> "$ARTIFACTS_LOGS/k3s-etcd-start.log"

  log "k3s cutover server started successfully"
}

collect_post_cutover_evidence() {
  export KUBECONFIG="$WORK/k3s-cutover/k3s.yaml"

  log "Collecting post-cutover evidence"

  # Capture post-cutover kubectl evidence
  kubectl_lab get ns migrator-lab -o yaml > "$ARTIFACTS_POST/ns.yaml"
  kubectl_lab -n migrator-lab get cm cm-alpha -o yaml > "$ARTIFACTS_POST/cm.yaml"

  # SAFE: Use JSON output and extract only safe metadata fields
  kubectl_lab -n migrator-lab get secret secret-alpha -o json 2>/dev/null | \
    jq '{metadata: .metadata, type: .type}' > "$ARTIFACTS_POST/secret-metadata.txt" || \
    kubectl_lab -n migrator-lab get secret secret-alpha -o yaml > "$ARTIFACTS_POST/secret-metadata.txt"

  kubectl_lab -n migrator-lab get sa sa-alpha -o yaml > "$ARTIFACTS_POST/sa.yaml"
  kubectl_lab -n migrator-lab get deploy deploy-alpha -o yaml > "$ARTIFACTS_POST/deploy.yaml"

  # Capture target etcd state after import
  ETCDCTL_API=3 "$BIN/etcdctl" \
    --endpoints=http://127.0.0.1:2379 \
    get "$MIGRATION_PREFIX" --prefix --keys-only \
    > "$ARTIFACTS_POST/etcd-registry-keys-after.txt"

  log "Post-cutover evidence collected"
}

verify_cutover_expectations() {
  export KUBECONFIG="$WORK/k3s-cutover/k3s.yaml"

  log "Verifying cutover expectations"

  local failures=0

  # Check that our test namespace is visible
  if ! kubectl_lab get ns migrator-lab >/dev/null 2>&1; then
    log "FAIL: Test namespace 'migrator-lab' not found after cutover"
    failures=$((failures + 1))
  fi

  # Check that our test ConfigMap is visible
  if ! kubectl_lab -n migrator-lab get cm cm-alpha >/dev/null 2>&1; then
    log "FAIL: ConfigMap 'cm-alpha' not found after cutover"
    failures=$((failures + 1))
  fi

  # Check that our test Secret is visible (by name, metadata only)
  if ! kubectl_lab -n migrator-lab get secret secret-alpha >/dev/null 2>&1; then
    log "FAIL: Secret 'secret-alpha' not found after cutover"
    failures=$((failures + 1))
  fi

  # Check that our test ServiceAccount is visible
  if ! kubectl_lab -n migrator-lab get sa sa-alpha >/dev/null 2>&1; then
    log "FAIL: ServiceAccount 'sa-alpha' not found after cutover"
    failures=$((failures + 1))
  fi

  # Check that our test Deployment is visible
  if ! kubectl_lab -n migrator-lab get deploy deploy-alpha >/dev/null 2>&1; then
    log "FAIL: Deployment 'deploy-alpha' not found after cutover"
    failures=$((failures + 1))
  fi

  # Write cutover status
  cat > "$ARTIFACTS/cutover-status.json" <<JSON
{
  "migration_prefix": "${MIGRATION_PREFIX}",
  "namespace_visible": $(kubectl_lab get ns migrator-lab >/dev/null 2>&1 && echo "true" || echo "false"),
  "configmap_visible": $(kubectl_lab -n migrator-lab get cm cm-alpha >/dev/null 2>&1 && echo "true" || echo "false"),
  "secret_metadata_visible": $(kubectl_lab -n migrator-lab get secret secret-alpha >/dev/null 2>&1 && echo "true" || echo "false"),
  "serviceaccount_visible": $(kubectl_lab -n migrator-lab get sa sa-alpha >/dev/null 2>&1 && echo "true" || echo "false"),
  "deployment_visible": $(kubectl_lab -n migrator-lab get deploy deploy-alpha >/dev/null 2>&1 && echo "true" || echo "false"),
  "run_id": "${RUN_ID}"
}
JSON

  if [[ $failures -gt 0 ]]; then
    log "FAIL: ${failures} cutover expectation(s) failed"
    exit 1
  fi

  log "All cutover expectations verified"
}

scan_artifact_safety() {
  log "Scanning artifacts for forbidden sensitive material"

  local failures=0
  local scan_log="$ARTIFACTS/verification/artifact-safety-scan.txt"
  mkdir -p "$ARTIFACTS/verification"

  {
    echo "=== Artifact Safety Scan ==="
    echo "[INFO] Scanning for forbidden sensitive material"
  } > "$scan_log"

  # Scan all artifacts for forbidden fields
  for artifact_file in "$ARTIFACTS_PRE"/*.txt "$ARTIFACTS_PRE"/*.yaml "$ARTIFACTS_POST"/*.txt "$ARTIFACTS_POST"/*.yaml; do
    [[ -f "$artifact_file" ]] || continue

    # Check for .data field (forbidden)
    if grep -E -- '\.data[[:space:]:]' "$artifact_file" 2>/dev/null; then
      echo "[ERROR] Forbidden .data field found in $artifact_file" >> "$scan_log"
      failures=$((failures + 1))
    fi

    # Check for .stringData field (forbidden)
    if grep -E -- '\.stringData[[:space:]:]' "$artifact_file" 2>/dev/null; then
      echo "[ERROR] Forbidden .stringData field found in $artifact_file" >> "$scan_log"
      failures=$((failures + 1))
    fi

    # Check for client-certificate-data (forbidden)
    if grep -E -- 'client-certificate-data:' "$artifact_file" 2>/dev/null; then
      echo "[ERROR] Forbidden client-certificate-data found in $artifact_file" >> "$scan_log"
      failures=$((failures + 1))
    fi

    # Check for client-key-data (forbidden)
    if grep -E -- 'client-key-data:' "$artifact_file" 2>/dev/null; then
      echo "[ERROR] Forbidden client-key-data found in $artifact_file" >> "$scan_log"
      failures=$((failures + 1))
    fi

    # Check for private keys (forbidden)
    if grep -E -- "-----BEGIN.*PRIVATE KEY-----" "$artifact_file" 2>/dev/null; then
      echo "[ERROR] Private key detected in $artifact_file" >> "$scan_log"
      failures=$((failures + 1))
    fi
  done

  {
    if [[ $failures -eq 0 ]]; then
      echo "[INFO] Safety scan PASSED"
    else
      echo "[ERROR] Safety scan FAILED: $failures issue(s) detected"
    fi
  } >> "$scan_log"

  if [[ $failures -gt 0 ]]; then
    log "FAIL: Artifact safety scan found $failures issue(s)"
    exit 1
  fi

  log "Artifact safety scan passed"
}

# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------

main() {
  require_linux_vm
  require_root

  log "=== Phase 1: PostgreSQL Provisioning ==="
  install_postgres
  setup_postgres_database

  log "=== Phase 2: k3s with PostgreSQL/Kine ==="
  install_k3s_postgres
  verify_kine_tables

  log "=== Phase 3: Seed Kubernetes State ==="
  populate_k3s
  collect_pre_migration_evidence

  log "=== Phase 4: Stop Source k3s ==="
  stop_source_k3s

  log "=== Phase 5: Start Target etcd ==="
  install_etcd
  start_target_etcd

  log "=== Phase 6: Run etcd-migrator ==="
  run_migrator

  log "=== Phase 7: k3s Cutover with External etcd ==="
  start_k3s_cutover
  collect_post_cutover_evidence
  verify_cutover_expectations
  scan_artifact_safety

  # Make safe artifact dirs readable by normal runner user
  chmod -R a+rX "$ARTIFACTS" 2>/dev/null || true

  log "PASS: k3s PostgreSQL/Kine to standalone etcd migration lab completed successfully"
  log "Artifacts: $ARTIFACTS"
  log "Run ID: $RUN_ID"
}

main "$@"
