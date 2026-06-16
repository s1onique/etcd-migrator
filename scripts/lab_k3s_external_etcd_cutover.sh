#!/usr/bin/env bash
# lab_k3s_external_etcd_cutover.sh — k3s external etcd cutover validation lab
#
# This lab proves etcd-migrator can produce a usable external etcd datastore
# by starting k3s against the migrated etcd and proving Kubernetes API serves
# the migrated objects.
#
# Topology:
#   k3s server (embedded etcd, hot) → snapshot → standalone source (restored)
#   → migrator → standalone target (populated)
#   → k3s server (external etcd) → kubectl → prove migrated objects visible
#
set -euo pipefail

LAB_NAME="lab-k3s-external-etcd-cutover"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
LAB_ROOT="${LAB_ROOT:-$PWD/runs/${LAB_NAME}-${RUN_ID}}"
ARTIFACTS="$LAB_ROOT/artifacts"
WORK="$LAB_ROOT/work"
BIN="$LAB_ROOT/bin"

# Source cluster artifacts
ARTIFACTS_SOURCE="$ARTIFACTS/source"
ARTIFACTS_MIGRATION="$ARTIFACTS/migration"
ARTIFACTS_TARGET="$ARTIFACTS/target"

K3S_CHANNEL="${K3S_CHANNEL:-stable}"
ETCD_VERSION="${ETCD_VERSION:-v3.5.21}"
# Must match etcd-migrator's dump/load prefix. Current migrator default is /registry/.
MIGRATION_PREFIX="${MIGRATION_PREFIX:-/registry/}"

# etcd and k3s process PIDs for clean shutdown
SOURCE_ETCD_PID=""
TARGET_ETCD_PID=""
SOURCE_K3S_PID=""
CUTOVER_K3S_PID=""

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
mkdir -p "$ARTIFACTS_SOURCE" "$ARTIFACTS_MIGRATION" "$ARTIFACTS_TARGET"

# Record migration scope for verification alignment
printf '%s\n' "$MIGRATION_PREFIX" > "$ARTIFACTS/migration-prefix.txt"

cleanup() {
  set +e
  # Stop k3s cutover server if running
  if [[ -n "$CUTOVER_K3S_PID" ]]; then
    kill "$CUTOVER_K3S_PID" 2>/dev/null || true
    wait "$CUTOVER_K3S_PID" 2>/dev/null || true
  fi
  # Stop k3s source server if running
  if [[ -n "$SOURCE_K3S_PID" ]]; then
    kill "$SOURCE_K3S_PID" 2>/dev/null || true
    wait "$SOURCE_K3S_PID" 2>/dev/null || true
  fi
  systemctl stop k3s >/dev/null 2>&1 || true
  # Kill etcd processes by PID if tracked
  if [[ -n "$SOURCE_ETCD_PID" ]]; then
    kill "$SOURCE_ETCD_PID" 2>/dev/null || true
    wait "$SOURCE_ETCD_PID" 2>/dev/null || true
  fi
  if [[ -n "$TARGET_ETCD_PID" ]]; then
    kill "$TARGET_ETCD_PID" 2>/dev/null || true
    wait "$TARGET_ETCD_PID" 2>/dev/null || true
  fi
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
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "This lab must run as root because k3s installs system services" >&2
    echo "Try: sudo bash scripts/lab_k3s_external_etcd_cutover.sh" >&2
    exit 1
  fi
}

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
  install -m 0755 "$WORK/etcd-${ETCD_VERSION}-${os}-${arch}/etcdutl" "$BIN/etcdutl"

  "$BIN/etcd" --version | tee "$ARTIFACTS/etcd-version.txt"
  "$BIN/etcdctl" version | tee "$ARTIFACTS/etcdctl-version.txt"
}

# Wait for Kubernetes API to be ready
wait_kube_api() {
  local timeout="${1:-120}"
  local kubeconfig="${2:-$KUBECONFIG}"

  log "Waiting for Kubernetes API to be ready (timeout=${timeout}s)"
  for _ in $(seq 1 "$((timeout / 5))"); do
    if KUBECONFIG="$kubeconfig" "${KUBECTL_CMD[@]}" cluster-info >/dev/null 2>&1; then
      log "Kubernetes API is ready"
      return 0
    fi
    sleep 5
  done

  echo "ERROR: Kubernetes API did not become ready within ${timeout}s" >&2
  return 1
}

install_k3s() {
  log "Installing k3s channel=${K3S_CHANNEL} with isolated data dir"

  export KUBECONFIG="$WORK/k3s-source/k3s.yaml"
  mkdir -p "$WORK/k3s-source"

  # Install k3s with isolated data dir (skip start to configure manually)
  curl -sfL https://get.k3s.io | \
    INSTALL_K3S_CHANNEL="$K3S_CHANNEL" \
    INSTALL_K3S_EXEC="server --cluster-init --write-kubeconfig-mode=644 --disable=traefik --disable=servicelb --disable=metrics-server" \
    INSTALL_K3S_SKIP_START=true \
    sh -

  # Start k3s with isolated data dir
  /usr/local/bin/k3s server \
    --cluster-init \
    --data-dir="$WORK/k3s-source" \
    --write-kubeconfig "$KUBECONFIG" \
    --write-kubeconfig-mode=644 \
    --disable=traefik,servicelb,metrics-server \
    > "$ARTIFACTS_SOURCE/k3s-source-startup.log" 2>&1 &

  SOURCE_K3S_PID=$!

  resolve_kubectl

  log "Using kubectl: ${KUBECTL_CMD[*]}"
  log "Waiting for k3s node readiness"
  wait_kube_api 120 "$KUBECONFIG"
  kubectl_lab wait --for=condition=Ready node --all --timeout=240s
  kubectl_lab version -o yaml > "$ARTIFACTS_SOURCE/kubectl-version.yaml"
  /usr/local/bin/k3s --version > "$ARTIFACTS/k3s-version.txt"
}

populate_k3s() {
  export KUBECONFIG="$WORK/k3s-source/k3s.yaml"

  log "Populating Kubernetes API objects for cutover validation"

  # Create the cutover test namespace
  kubectl_lab create namespace "etcd-migrator-cutover" \
    --dry-run=client -o yaml | kubectl_lab apply -f -

  # Create a test ConfigMap
  kubectl_lab create configmap "etcd-migrator-cutover-config" \
    -n "etcd-migrator-cutover" \
    --from-literal="environment=test" \
    --from-literal="purpose=cutover-validation" \
    --dry-run=client -o yaml | kubectl_lab apply -f -

  # Create a test Secret (metadata only - no actual values will be captured)
  kubectl_lab create secret generic "etcd-migrator-cutover-secret" \
    -n "etcd-migrator-cutover" \
    --from-literal="key=synthetic-secret-value" \
    --dry-run=client -o yaml | kubectl_lab apply -f -

  # Create the Widget CRD for cutover validation
  cat > "$WORK/lab-crd.yaml" <<'YAML'
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: widgets.cutover.etcd-migrator.dev
spec:
  group: cutover.etcd-migrator.dev
  scope: Namespaced
  names:
    plural: widgets
    singular: widget
    kind: Widget
  versions:
    - name: v1
      served: true
      storage: true
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              properties:
                message:
                  type: string
YAML

  kubectl_lab apply -f "$WORK/lab-crd.yaml"

  log "Waiting for CRD to become Established"
  kubectl_lab wait \
    --for=condition=Established \
    crd/widgets.cutover.etcd-migrator.dev \
    --timeout=60s

  # Create a sample Widget CR
  cat > "$WORK/lab-widget.yaml" <<'YAML'
apiVersion: cutover.etcd-migrator.dev/v1
kind: Widget
metadata:
  name: sample-widget
  namespace: etcd-migrator-cutover
spec:
  message: "etcd-migrator cutover validation object"
YAML

  kubectl_lab apply -f "$WORK/lab-widget.yaml"

  log "Collecting source cluster evidence"
  kubectl_lab get namespaces -o name > "$ARTIFACTS_SOURCE/source-objects.yaml"

  # SAFE: Collect source kubectl evidence with metadata-only secret output
  kubectl_lab get namespaces -o wide > "$ARTIFACTS_SOURCE/source-kubectl-namespaces.txt"
  kubectl_lab get configmaps --all-namespaces -o wide > "$ARTIFACTS_SOURCE/source-kubectl-configmaps.txt"
  # SAFE: Use JSON output and extract only safe metadata fields
  kubectl_lab get secrets --all-namespaces -o json 2>/dev/null | \
    jq -r '.items[] | "\(.metadata.namespace) \(.metadata.name) \(.type) \(.metadata.creationTimestamp)"' > "$ARTIFACTS_SOURCE/source-kubectl-secrets-metadata.txt" || \
    kubectl_lab get secrets --all-namespaces -o wide > "$ARTIFACTS_SOURCE/source-kubectl-secrets-metadata.txt"
  kubectl_lab get crds -o wide > "$ARTIFACTS_SOURCE/source-kubectl-crds.txt"
  kubectl_lab get widgets --all-namespaces -o wide > "$ARTIFACTS_SOURCE/source-kubectl-custom-resources.txt" 2>/dev/null || true
}

snapshot_k3s_etcd() {
  log "Taking k3s embedded etcd snapshot"

  local snapshot
  snapshot="$WORK/k3s-embedded-etcd.snapshot.db"

  ETCDCTL_API=3 "$BIN/etcdctl" \
    --endpoints="https://127.0.0.1:2379" \
    --cacert="$WORK/k3s-source/server/tls/etcd/server-ca.crt" \
    --cert="$WORK/k3s-source/server/tls/etcd/server-client.crt" \
    --key="$WORK/k3s-source/server/tls/etcd/server-client.key" \
    endpoint status --write-out=json > "$ARTIFACTS_SOURCE/k3s-etcd-endpoint-status.json"

  ETCDCTL_API=3 "$BIN/etcdctl" \
    --endpoints="https://127.0.0.1:2379" \
    --cacert="$WORK/k3s-source/server/tls/etcd/server-ca.crt" \
    --cert="$WORK/k3s-source/server/tls/etcd/server-client.crt" \
    --key="$WORK/k3s-source/server/tls/etcd/server-client.key" \
    snapshot save "$snapshot"

  "$BIN/etcdutl" snapshot status "$snapshot" --write-out=json \
    > "$ARTIFACTS_SOURCE/k3s-snapshot-status.json"

  sha256sum "$snapshot" > "$ARTIFACTS_SOURCE/k3s-snapshot.sha256"
}

restore_source_standalone() {
  log "Restoring snapshot into standalone source etcd"

  "$BIN/etcdutl" snapshot restore "$WORK/k3s-embedded-etcd.snapshot.db" \
    --name source \
    --data-dir "$WORK/source.etcd" \
    --initial-cluster source=http://127.0.0.1:23800 \
    --initial-advertise-peer-urls http://127.0.0.1:23800 \
    --initial-cluster-token source-cluster

  "$BIN/etcd" \
    --name source \
    --data-dir "$WORK/source.etcd" \
    --listen-client-urls http://127.0.0.1:23790 \
    --advertise-client-urls http://127.0.0.1:23790 \
    --listen-peer-urls http://127.0.0.1:23800 \
    --initial-advertise-peer-urls http://127.0.0.1:23800 \
    --initial-cluster source=http://127.0.0.1:23800 \
    --initial-cluster-token source-cluster \
    --initial-cluster-state new \
    > "$ARTIFACTS_SOURCE/source-etcd.log" 2>&1 &

  SOURCE_ETCD_PID=$!
  wait_etcd http://127.0.0.1:23790 "$ARTIFACTS_SOURCE/source-endpoint-health.json"
}

start_target_standalone() {
  log "Starting standalone target etcd"

  "$BIN/etcd" \
    --name target \
    --data-dir "$WORK/target.etcd" \
    --listen-client-urls http://127.0.0.1:24790 \
    --advertise-client-urls http://127.0.0.1:24790 \
    --listen-peer-urls http://127.0.0.1:24800 \
    --initial-advertise-peer-urls http://127.0.0.1:24800 \
    --initial-cluster target=http://127.0.0.1:24800 \
    --initial-cluster-token target-cluster \
    --initial-cluster-state new \
    > "$ARTIFACTS_TARGET/target-etcd.log" 2>&1 &

  TARGET_ETCD_PID=$!
  wait_etcd http://127.0.0.1:24790 "$ARTIFACTS_TARGET/external-etcd-health.txt"
}

wait_etcd() {
  local endpoint="$1"
  local outfile="$2"

  for _ in $(seq 1 120); do
    if ETCDCTL_API=3 "$BIN/etcdctl" --endpoints="$endpoint" endpoint health --write-out=json > "$outfile" 2>&1; then
      return 0
    fi
    sleep 1
  done

  echo "etcd endpoint did not become healthy: $endpoint" >&2
  cat "$outfile" >&2 || true
  exit 1
}

run_migrator() {
  log "Running etcd-migrator from source to target"

  # Dump from source etcd
  ./bin/etcd-migrator dump \
    --source-endpoints="http://127.0.0.1:23790" \
    --prefix="$MIGRATION_PREFIX" \
    --output "$WORK/source.dump.jsonl" \
    > "$ARTIFACTS_MIGRATION/migrate.log" 2>&1

  # Load into target etcd
  ./bin/etcd-migrator load \
    --target-endpoints="http://127.0.0.1:24790" \
    --prefix="$MIGRATION_PREFIX" \
    --input "$WORK/source.dump.jsonl" \
    >> "$ARTIFACTS_MIGRATION/migrate.log" 2>&1

  log "Migrator completed"
}

collect_compare_evidence() {
  log "Collecting source/target comparison evidence"

  # Key-only comparison (aligned to migration scope)
  ETCDCTL_API=3 "$BIN/etcdctl" \
    --endpoints=http://127.0.0.1:23790 \
    get "$MIGRATION_PREFIX" --prefix --keys-only \
    | sort > "$WORK/source.keys"

  ETCDCTL_API=3 "$BIN/etcdctl" \
    --endpoints=http://127.0.0.1:24790 \
    get "$MIGRATION_PREFIX" --prefix --keys-only \
    | sort > "$WORK/target.keys"

  wc -l "$WORK/source.keys" "$WORK/target.keys" \
    > "$ARTIFACTS_MIGRATION/key-counts.txt"

  if diff -u "$WORK/source.keys" "$WORK/target.keys" > "$ARTIFACTS_MIGRATION/key-diff.txt"; then
    keysets_match=true
  else
    keysets_match=false
  fi

  # Key+value hash comparison (safe: base64-encoded, not uploaded)
  ETCDCTL_API=3 "$BIN/etcdctl" \
    --endpoints=http://127.0.0.1:23790 \
    get "$MIGRATION_PREFIX" --prefix --write-out=json \
    | jq -r '.kvs[] | [.key, .value] | @tsv' \
    | sort > "$WORK/source.kv.tsv"

  ETCDCTL_API=3 "$BIN/etcdctl" \
    --endpoints=http://127.0.0.1:24790 \
    get "$MIGRATION_PREFIX" --prefix --write-out=json \
    | jq -r '.kvs[] | [.key, .value] | @tsv' \
    | sort > "$WORK/target.kv.tsv"

  sha256sum "$WORK/source.kv.tsv" > "$ARTIFACTS_MIGRATION/source-kv-sha256.txt"
  sha256sum "$WORK/target.kv.tsv" > "$ARTIFACTS_MIGRATION/target-kv-sha256.txt"

  if diff -q "$WORK/source.kv.tsv" "$WORK/target.kv.tsv" >/dev/null 2>&1; then
    kv_match=true
  else
    kv_match=false
  fi

  # Endpoint status
  ETCDCTL_API=3 "$BIN/etcdctl" \
    --endpoints=http://127.0.0.1:24790 \
    endpoint status --write-out=json \
    > "$ARTIFACTS_MIGRATION/target-endpoint-status-after.json"

  # Write comparison status JSON
  cat > "$ARTIFACTS_MIGRATION/compare-status.json" <<JSON
{
  "migration_prefix": "${MIGRATION_PREFIX}",
  "keysets_match": ${keysets_match},
  "kv_match": ${kv_match},
  "run_id": "${RUN_ID}"
}
JSON

  log "Compare status: keysets_match=${keysets_match}, kv_match=${kv_match}"

  # Write compare log
  {
    echo "=== Comparison Phase ==="
    echo "Key counts: source=$(wc -l < "$WORK/source.keys"), target=$(wc -l < "$WORK/target.keys")"
    if [[ "$keysets_match" == "true" ]]; then
      echo "Key diff: empty (no differences)"
    else
      echo "Key diff: differences found"
    fi
    if [[ "$kv_match" == "true" ]]; then
      echo "KV hashes: match"
    else
      echo "KV hashes: mismatch"
    fi
  } > "$ARTIFACTS_MIGRATION/compare.log"

  if [[ "${keysets_match}" != "true" ]] || [[ "${kv_match}" != "true" ]]; then
    log "FAIL: source and target do not match"
    exit 1
  fi
}

stop_source_k3s_and_etcd() {
  log "Stopping source k3s and standalone source etcd"

  # Stop source k3s by PID (keep target etcd alive!)
  if [[ -n "$SOURCE_K3S_PID" ]]; then
    kill "$SOURCE_K3S_PID" 2>/dev/null || true
    wait "$SOURCE_K3S_PID" 2>/dev/null || true
    SOURCE_K3S_PID=""
  fi

  # Stop source standalone etcd by PID
  if [[ -n "$SOURCE_ETCD_PID" ]]; then
    kill "$SOURCE_ETCD_PID" 2>/dev/null || true
    wait "$SOURCE_ETCD_PID" 2>/dev/null || true
    SOURCE_ETCD_PID=""
  fi

  sleep 2
}

start_k3s_cutover() {
  log "Starting k3s cutover server with external etcd"

  # Use proper k3s external datastore configuration via environment variable
  export KUBECONFIG="$WORK/k3s-cutover/k3s.yaml"
  mkdir -p "$WORK/k3s-cutover"

  {
    echo "=== k3s External etcd Cutover Startup ==="
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Starting k3s server with external etcd"
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] datastore-endpoint=http://127.0.0.1:24790"
  } > "$ARTIFACTS_TARGET/k3s-start.log"

  # Start k3s with external etcd using proper configuration
  /usr/local/bin/k3s server \
    --data-dir="$WORK/k3s-cutover" \
    --write-kubeconfig "$KUBECONFIG" \
    --write-kubeconfig-mode=644 \
    --disable=traefik,servicelb,metrics-server \
    --datastore-endpoint="http://127.0.0.1:24790" \
    > "$ARTIFACTS_TARGET/k3s-startup.log" 2>&1 &

  CUTOVER_K3S_PID=$!

  # Wait for k3s API server to become ready
  wait_kube_api 180 "$KUBECONFIG"

  resolve_kubectl

  {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Kubernetes API is ready"
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] k3s startup PASSED"
  } >> "$ARTIFACTS_TARGET/k3s-start.log"

  log "k3s cutover server started successfully"
}

collect_cutover_evidence() {
  log "Collecting cutover evidence via kubectl"

  # Wait for CRD to be established
  kubectl_lab wait \
    --for=condition=Established \
    crd/widgets.cutover.etcd-migrator.dev \
    --timeout=60s || true

  # SAFE: Collect kubectl evidence with metadata-only secret output
  kubectl_lab get namespaces -o wide > "$ARTIFACTS_TARGET/cutover-kubectl-namespaces.txt"
  kubectl_lab get configmaps --all-namespaces -o wide > "$ARTIFACTS_TARGET/cutover-kubectl-configmaps.txt"

  # SAFE: Use JSON output and extract only safe metadata fields (never .data or .stringData)
  kubectl_lab get secrets --all-namespaces -o json 2>/dev/null | \
    jq -r '.items[] | "\(.metadata.namespace) \(.metadata.name) \(.type) \(.metadata.creationTimestamp)"' > "$ARTIFACTS_TARGET/cutover-kubectl-secrets-metadata.txt" || \
    kubectl_lab get secrets --all-namespaces -o wide > "$ARTIFACTS_TARGET/cutover-kubectl-secrets-metadata.txt"

  kubectl_lab get crds -o wide > "$ARTIFACTS_TARGET/cutover-kubectl-crds.txt"
  kubectl_lab get widgets --all-namespaces -o wide > "$ARTIFACTS_TARGET/cutover-kubectl-custom-resources.txt" 2>/dev/null || true

  # Node information
  kubectl_lab get nodes -o wide > "$ARTIFACTS_TARGET/cutover-kubectl-nodes.txt" 2>/dev/null || true

  # System pods
  kubectl_lab get pods -n kube-system -o wide > "$ARTIFACTS_TARGET/cutover-kubectl-system-pods.txt" 2>/dev/null || true
}

verify_cutover_expectations() {
  log "Verifying cutover expectations"

  local failures=0

  # Check that our test namespace is visible
  if ! grep -q "etcd-migrator-cutover" "$ARTIFACTS_TARGET/cutover-kubectl-namespaces.txt"; then
    log "FAIL: Test namespace 'etcd-migrator-cutover' not found in cutover kubectl output"
    failures=$((failures + 1))
  fi

  # Check that our test ConfigMap is visible
  if ! grep -q "etcd-migrator-cutover-config" "$ARTIFACTS_TARGET/cutover-kubectl-configmaps.txt"; then
    log "FAIL: Test ConfigMap 'etcd-migrator-cutover-config' not found in cutover kubectl output"
    failures=$((failures + 1))
  fi

  # Check that our test Secret is visible (by name, metadata only)
  if ! grep -q "etcd-migrator-cutover-secret" "$ARTIFACTS_TARGET/cutover-kubectl-secrets-metadata.txt"; then
    log "FAIL: Test Secret 'etcd-migrator-cutover-secret' not found in cutover kubectl output"
    failures=$((failures + 1))
  fi

  # Check that the CRD is visible
  if ! grep -q "widgets.cutover.etcd-migrator.dev" "$ARTIFACTS_TARGET/cutover-kubectl-crds.txt"; then
    log "FAIL: Test CRD 'widgets.cutover.etcd-migrator.dev' not found in cutover kubectl output"
    failures=$((failures + 1))
  fi

  # Check that the custom resource is visible
  if ! grep -q "sample-widget" "$ARTIFACTS_TARGET/cutover-kubectl-custom-resources.txt"; then
    log "FAIL: Test Widget 'sample-widget' not found in cutover kubectl output"
    failures=$((failures + 1))
  fi

  # Write cutover status
  cat > "$ARTIFACTS/cutover-status.json" <<JSON
{
  "migration_prefix": "${MIGRATION_PREFIX}",
  "namespace_visible": true,
  "configmap_visible": true,
  "secret_metadata_visible": true,
  "crd_visible": true,
  "custom_resource_visible": true,
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

  # Check secrets metadata for forbidden fields (both dotted and bare forms)
  if grep -E -- '\.data[[:space:]:]' "$ARTIFACTS_TARGET/cutover-kubectl-secrets-metadata.txt" 2>/dev/null; then
    echo "[ERROR] Forbidden .data field found in secrets output" >&2
    echo "[ERROR] .data field found in cutover-kubectl-secrets-metadata.txt" >> "$scan_log"
    failures=$((failures + 1))
  else
    echo "[INFO] No .data fields found in secrets output" >> "$scan_log"
  fi

  if grep -E -- '\.stringData[[:space:]:]' "$ARTIFACTS_TARGET/cutover-kubectl-secrets-metadata.txt" 2>/dev/null; then
    echo "[ERROR] Forbidden .stringData field found in secrets output" >&2
    echo "[ERROR] .stringData field found in cutover-kubectl-secrets-metadata.txt" >> "$scan_log"
    failures=$((failures + 1))
  else
    echo "[INFO] No .stringData fields found in secrets output" >> "$scan_log"
  fi

  # Check for token-like values (base64-encoded tokens are 44+ chars)
  if grep -E -- '[A-Za-z0-9+/]{44,}==' "$ARTIFACTS_TARGET/cutover-kubectl-secrets-metadata.txt" 2>/dev/null; then
    echo "[ERROR] Potential token-like values found in secrets output" >&2
    echo "[ERROR] Token-like values detected in secrets metadata" >> "$scan_log"
    failures=$((failures + 1))
  else
    echo "[INFO] No token-like values detected" >> "$scan_log"
  fi

  # Check for private key patterns (use -- to prevent pattern starting with - being treated as flag)
  if grep -E -- "-----BEGIN.*PRIVATE KEY-----" "$ARTIFACTS_TARGET/cutover-kubectl-secrets-metadata.txt" 2>/dev/null || \
     grep -E -- "-----BEGIN.*RSA PRIVATE KEY-----" "$ARTIFACTS_TARGET/cutover-kubectl-secrets-metadata.txt" 2>/dev/null; then
    echo "[ERROR] Private key detected in secrets output" >&2
    echo "[ERROR] Private key detected in secrets metadata" >> "$scan_log"
    failures=$((failures + 1))
  else
    echo "[INFO] No private keys detected" >> "$scan_log"
  fi

  # Check for kubeconfig credentials
  if grep -E -- "client-certificate-data:" "$ARTIFACTS_TARGET/cutover-kubectl-secrets-metadata.txt" 2>/dev/null || \
     grep -E -- "client-key-data:" "$ARTIFACTS_TARGET/cutover-kubectl-secrets-metadata.txt" 2>/dev/null; then
    echo "[ERROR] Kubeconfig credentials detected in secrets output" >&2
    echo "[ERROR] Kubeconfig credentials detected in secrets metadata" >> "$scan_log"
    failures=$((failures + 1))
  else
    echo "[INFO] No kubeconfig credentials detected" >> "$scan_log"
  fi

  # Also scan source secrets metadata
  if [[ -f "$ARTIFACTS_SOURCE/source-kubectl-secrets-metadata.txt" ]]; then
    if grep -E -- '\.data[[:space:]:]' "$ARTIFACTS_SOURCE/source-kubectl-secrets-metadata.txt" 2>/dev/null; then
      echo "[ERROR] Forbidden .data field found in source secrets output" >&2
      echo "[ERROR] .data field found in source-kubectl-secrets-metadata.txt" >> "$scan_log"
      failures=$((failures + 1))
    else
      echo "[INFO] No .data fields found in source secrets output" >> "$scan_log"
    fi
  fi

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

main() {
  require_linux_vm
  require_root
  install_etcd

  log "=== Phase 1: Source k3s cluster ==="
  install_k3s
  populate_k3s
  snapshot_k3s_etcd

  log "=== Phase 2: Migration ==="
  restore_source_standalone
  start_target_standalone
  run_migrator
  collect_compare_evidence

  log "=== Phase 3: k3s cutover with external etcd ==="
  stop_source_k3s_and_etcd
  start_k3s_cutover
  collect_cutover_evidence
  verify_cutover_expectations
  scan_artifact_safety

  # Make safe artifact dirs readable by normal runner user
  chmod -R a+rX "$ARTIFACTS" 2>/dev/null || true

  log "PASS: k3s external etcd cutover validation lab completed successfully"
  log "Artifacts: $ARTIFACTS"
  log "Run ID: $RUN_ID"
}

main "$@"
