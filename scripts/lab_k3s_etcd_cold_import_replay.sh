#!/usr/bin/env bash
# lab_k3s_etcd_cold_import_replay.sh — k3s embedded etcd → standalone etcd cold import replay/idempotence lab
#
# This lab proves etcd-migrator's replay/idempotence contract when loading the same
# cold-import dump into the same standalone target twice.
#
# Topology:
#   k3s server (embedded etcd, hot) → snapshot → standalone source (restored)
#   → migrator dump → standalone target (empty)
#   → migrator load #1 → standalone target (populated)
#   → migrator load #2 → standalone target (replay)
#
set -euo pipefail

LAB_NAME="lab-k3s-etcd-cold-import-replay"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
LAB_ROOT="${LAB_ROOT:-$PWD/runs/${LAB_NAME}-${RUN_ID}}"
ARTIFACTS="$LAB_ROOT/artifacts"
WORK="$LAB_ROOT/work"
BIN="$LAB_ROOT/bin"
RAW_ARTIFACTS="$LAB_ROOT/raw-artifacts"

K3S_CHANNEL="${K3S_CHANNEL:-stable}"
ETCD_VERSION="${ETCD_VERSION:-v3.5.21}"
OBJECT_COUNT="${OBJECT_COUNT:-20}"
UPLOAD_RAW_ETCD_ARTIFACTS="${UPLOAD_RAW_ETCD_ARTIFACTS:-false}"
# Must match etcd-migrator's dump/load prefix. Current migrator default is /registry/.
MIGRATION_PREFIX="${MIGRATION_PREFIX:-/registry/}"
# Replay expectation: auto (accept either), idempotent (require success), safe-fail (require nonzero)
REPLAY_EXPECTATION="${REPLAY_EXPECTATION:-auto}"
# Conflict policy: fail-if-present (default, safe) or allow-identical-replay (idempotent)
CONFLICT_POLICY="${CONFLICT_POLICY:-fail-if-present}"

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

mkdir -p "$ARTIFACTS" "$WORK" "$BIN" "$RAW_ARTIFACTS"

# Record migration scope for verification alignment
printf '%s\n' "$MIGRATION_PREFIX" > "$ARTIFACTS/migration-prefix.txt"

cleanup() {
  set +e
  systemctl stop k3s >/dev/null 2>&1 || true
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
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "This lab must run as root because k3s installs system services" >&2
    echo "Try: sudo bash scripts/lab_k3s_etcd_cold_import_replay.sh" >&2
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
  "$BIN/etcdutl" version | tee "$ARTIFACTS/etcdutl-version.txt"
}

install_k3s() {
  log "Installing k3s channel=${K3S_CHANNEL}"
  curl -sfL https://get.k3s.io | \
    INSTALL_K3S_CHANNEL="$K3S_CHANNEL" \
    INSTALL_K3S_EXEC="server --cluster-init --write-kubeconfig-mode=644 --disable=traefik --disable=servicelb --disable=metrics-server" \
    sh -

  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  resolve_kubectl

  log "Using kubectl: ${KUBECTL_CMD[*]}"
  log "Waiting for k3s node readiness"
  kubectl_lab wait --for=condition=Ready node --all --timeout=240s
  kubectl_lab version -o yaml > "$ARTIFACTS/kubectl-version.yaml"
  /usr/local/bin/k3s --version > "$ARTIFACTS/k3s-version.txt"
}

populate_k3s() {
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

  log "Populating real Kubernetes API objects"
  for ns in lab-a lab-b; do
    kubectl_lab create namespace "$ns" \
      --dry-run=client -o yaml | kubectl_lab apply -f -

    kubectl_lab create serviceaccount "sa-${ns}" -n "$ns" \
      --dry-run=client -o yaml | kubectl_lab apply -f -

    for i in $(seq 1 "$OBJECT_COUNT"); do
      kubectl_lab create configmap "cm-${i}" \
        -n "$ns" \
        --from-literal="key-${i}=value-${i}" \
        --dry-run=client -o yaml | kubectl_lab apply -f -

      kubectl_lab create secret generic "secret-${i}" \
        -n "$ns" \
        --from-literal="token=synthetic-${ns}-${i}" \
        --dry-run=client -o yaml | kubectl_lab apply -f -
    done
  done

  cat > "$WORK/lab-crd.yaml" <<'YAML'
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: widgets.lab.example.com
spec:
  group: lab.example.com
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
    crd/widgets.lab.example.com \
    --timeout=60s

  cat > "$WORK/lab-widget.yaml" <<'YAML'
apiVersion: lab.example.com/v1
kind: Widget
metadata:
  name: sample-widget
  namespace: lab-a
spec:
  message: "real k3s etcd lab object"
YAML

  kubectl_lab apply -f "$WORK/lab-widget.yaml"

  kubectl_lab get ns,cm,secret,sa -A -o wide > "$ARTIFACTS/k8s-inventory.txt"
  kubectl_lab get crd widgets.lab.example.com -o yaml > "$ARTIFACTS/k8s-crd-widget.yaml"
}

snapshot_k3s_etcd() {
  log "Taking k3s embedded etcd snapshot"

  local snapshot
  snapshot="$WORK/k3s-embedded-etcd.snapshot.db"

  ETCDCTL_API=3 "$BIN/etcdctl" \
    --endpoints="https://127.0.0.1:2379" \
    --cacert="/var/lib/rancher/k3s/server/tls/etcd/server-ca.crt" \
    --cert="/var/lib/rancher/k3s/server/tls/etcd/server-client.crt" \
    --key="/var/lib/rancher/k3s/server/tls/etcd/server-client.key" \
    endpoint status --write-out=json > "$ARTIFACTS/k3s-etcd-endpoint-status.json"

  ETCDCTL_API=3 "$BIN/etcdctl" \
    --endpoints="https://127.0.0.1:2379" \
    --cacert="/var/lib/rancher/k3s/server/tls/etcd/server-ca.crt" \
    --cert="/var/lib/rancher/k3s/server/tls/etcd/server-client.crt" \
    --key="/var/lib/rancher/k3s/server/tls/etcd/server-client.key" \
    snapshot save "$snapshot"

  "$BIN/etcdutl" snapshot status "$snapshot" --write-out=json \
    > "$ARTIFACTS/k3s-snapshot-status.json"

  sha256sum "$snapshot" > "$ARTIFACTS/k3s-snapshot.sha256"

  if [[ "$UPLOAD_RAW_ETCD_ARTIFACTS" == "true" ]]; then
    mkdir -p "$RAW_ARTIFACTS"
    cp "$snapshot" "$RAW_ARTIFACTS/k3s-embedded-etcd.snapshot.db"
  fi
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
    > "$ARTIFACTS/source-etcd.log" 2>&1 &

  wait_etcd http://127.0.0.1:23790 "$ARTIFACTS/source-endpoint-health.json"
}

start_target_standalone() {
  log "Starting empty standalone target etcd"

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
    > "$ARTIFACTS/target-etcd.log" 2>&1 &

  wait_etcd http://127.0.0.1:24790 "$ARTIFACTS/target-endpoint-health-before.json"
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

run_migrator_dump() {
  log "Running etcd-migrator dump from restored source"

  ./bin/etcd-migrator dump \
    --source-endpoints="http://127.0.0.1:23790" \
    --prefix="$MIGRATION_PREFIX" \
    --output "$WORK/source.dump.jsonl"

  log "Dump completed: $WORK/source.dump.jsonl"
}

run_migrator_load() {
  local label="$1"
  local output_prefix="$2"

  log "Running etcd-migrator load into target ($label) with conflict-policy=$CONFLICT_POLICY"

  local stdout_file="$ARTIFACTS/${output_prefix}-stdout.txt"
  local stderr_file="$ARTIFACTS/${output_prefix}-stderr.txt"
  local start_time end_time duration

  start_time="$(date -u +%s)"

  set +e
  ./bin/etcd-migrator load \
    --target-endpoints="http://127.0.0.1:24790" \
    --prefix="$MIGRATION_PREFIX" \
    --input "$WORK/source.dump.jsonl" \
    --conflict-policy="$CONFLICT_POLICY" \
    > "$stdout_file" 2> "$stderr_file"
  local exit_code=$?
  set -e

  end_time="$(date -u +%s)"
  duration=$((end_time - start_time))

  printf '%s\n' "$exit_code" > "$ARTIFACTS/${output_prefix}-exit-code.txt"
  printf '%s\n' "$duration" > "$ARTIFACTS/${output_prefix}-duration.txt"

  log "Load $label completed: exit=$exit_code, duration=${duration}s"

  return $exit_code
}

collect_keys() {
  local endpoint="$1"
  local output="$2"

  ETCDCTL_API=3 "$BIN/etcdctl" \
    --endpoints="$endpoint" \
    get "$MIGRATION_PREFIX" --prefix --keys-only \
    | sort > "$output"
}

collect_kv_tsv() {
  local endpoint="$1"
  local output="$2"

  ETCDCTL_API=3 "$BIN/etcdctl" \
    --endpoints="$endpoint" \
    get "$MIGRATION_PREFIX" --prefix --write-out=json \
    | jq -r '.kvs[] | [.key, .value] | @tsv' \
    | sort > "$output"
}

collect_compare_evidence() {
  local phase="$1"  # "first" or "second"

  log "Collecting source/target comparison evidence (${phase} load)"

  local keys_suffix="${phase}-load"
  local kv_suffix="${phase}-load"

  # Key-only comparison (aligned to migration scope)
  collect_keys http://127.0.0.1:23790 "$WORK/source-${keys_suffix}.keys"
  collect_keys http://127.0.0.1:24790 "$WORK/target-${keys_suffix}.keys"

  wc -l "$WORK/source-${keys_suffix}.keys" "$WORK/target-${keys_suffix}.keys" \
    > "$ARTIFACTS/key-counts-after-${keys_suffix}.txt"

  if diff -u "$WORK/source-${keys_suffix}.keys" "$WORK/target-${keys_suffix}.keys" > "$ARTIFACTS/key-diff-after-${keys_suffix}.txt"; then
    local keysets_match=true
  else
    local keysets_match=false
  fi

  # Key+value hash comparison (safe: base64-encoded, not uploaded to git)
  collect_kv_tsv http://127.0.0.1:23790 "$WORK/source-${kv_suffix}.kv.tsv"
  collect_kv_tsv http://127.0.0.1:24790 "$WORK/target-${kv_suffix}.kv.tsv"

  sha256sum "$WORK/source-${kv_suffix}.kv.tsv" > "$ARTIFACTS/source-kv-after-${kv_suffix}-sha256.txt"
  sha256sum "$WORK/target-${kv_suffix}.kv.tsv" > "$ARTIFACTS/target-kv-after-${kv_suffix}-sha256.txt"

  if diff -q "$WORK/source-${kv_suffix}.kv.tsv" "$WORK/target-${kv_suffix}.kv.tsv" >/dev/null 2>&1; then
    local kv_match=true
  else
    local kv_match=false
  fi

  # Endpoint status
  ETCDCTL_API=3 "$BIN/etcdctl" \
    --endpoints=http://127.0.0.1:24790 \
    endpoint status --write-out=json \
    > "$ARTIFACTS/target-endpoint-status-after-${keys_suffix}.json"

  # Write comparison status JSON
  cat > "$ARTIFACTS/compare-after-${keys_suffix}.json" <<JSON
{
  "migration_prefix": "${MIGRATION_PREFIX}",
  "keysets_match": ${keysets_match},
  "kv_match": ${kv_match},
  "run_id": "${RUN_ID}",
  "phase": "${phase}-load"
}
JSON

  log "Compare after ${phase}-load: keysets_match=${keysets_match}, kv_match=${kv_match}"

  # Export for caller
  if [[ "$keysets_match" != "true" ]] || [[ "$kv_match" != "true" ]]; then
    return 1
  fi
  return 0
}

collect_non_migrated_keys() {
  log "Collecting non-migrated keys diagnostic"

  ETCDCTL_API=3 "$BIN/etcdctl" \
    --endpoints=http://127.0.0.1:23790 \
    get / --prefix --keys-only \
    | sort > "$WORK/source-all.keys"

  comm -23 "$WORK/source-all.keys" "$WORK/source-first-load.keys" \
    > "$ARTIFACTS/source-non-migrated-keys.txt" || true
}

write_replay_status() {
  log "Writing replay status"

  local first_exit second_exit
  local first_keysets first_kv second_keysets second_kv
  local target_unchanged
  local replay_outcome contract_satisfied

  first_exit="$(cat "$ARTIFACTS/first-load-exit-code.txt")"
  second_exit="$(cat "$ARTIFACTS/second-load-exit-code.txt")"

  first_keysets="$(jq -r '.keysets_match' "$ARTIFACTS/compare-after-first-load.json")"
  first_kv="$(jq -r '.kv_match' "$ARTIFACTS/compare-after-first-load.json")"
  second_keysets="$(jq -r '.keysets_match' "$ARTIFACTS/compare-after-second-load.json")"
  second_kv="$(jq -r '.kv_match' "$ARTIFACTS/compare-after-second-load.json")"

  # Check if target hash unchanged after second load
  local target_first target_second
  target_first="$(cut -d' ' -f1 "$ARTIFACTS/target-kv-after-first-load-sha256.txt")"
  target_second="$(cut -d' ' -f1 "$ARTIFACTS/target-kv-after-second-load-sha256.txt")"

  if [[ "$target_first" == "$target_second" ]]; then
    target_unchanged=true
  else
    target_unchanged=false
  fi

  # Determine replay outcome
  if [[ "$first_keysets" == "true" ]] && [[ "$first_kv" == "true" ]] && \
     [[ "$second_keysets" == "true" ]] && [[ "$second_kv" == "true" ]] && \
     [[ "$target_unchanged" == "true" ]]; then

    if [[ "$second_exit" == "0" ]]; then
      replay_outcome="idempotent_success"
    else
      replay_outcome="safe_fail_no_mutation"
    fi
  elif [[ "$target_unchanged" == "false" ]]; then
    replay_outcome="unsafe_mutation"
  else
    replay_outcome="unexpected_failure"
  fi

  # Determine contract satisfaction based on expectation
  case "$REPLAY_EXPECTATION" in
    idempotent)
      if [[ "$replay_outcome" == "idempotent_success" ]]; then
        contract_satisfied=true
      else
        contract_satisfied=false
      fi
      ;;
    safe-fail)
      if [[ "$replay_outcome" == "safe_fail_no_mutation" ]]; then
        contract_satisfied=true
      else
        contract_satisfied=false
      fi
      ;;
    auto|*)
      # Accept either idempotent_success or safe_fail_no_mutation
      if [[ "$replay_outcome" == "idempotent_success" ]] || [[ "$replay_outcome" == "safe_fail_no_mutation" ]]; then
        contract_satisfied=true
      else
        contract_satisfied=false
      fi
      ;;
  esac

  cat > "$ARTIFACTS/replay-status.json" <<JSON
{
  "migration_prefix": "${MIGRATION_PREFIX}",
  "conflict_policy": "${CONFLICT_POLICY}",
  "replay_expectation": "${REPLAY_EXPECTATION}",
  "first_load_exit_code": ${first_exit},
  "second_load_exit_code": ${second_exit},
  "first_load_keysets_match": ${first_keysets},
  "first_load_kv_match": ${first_kv},
  "second_load_keysets_match": ${second_keysets},
  "second_load_kv_match": ${second_kv},
  "target_hash_unchanged_after_second_load": ${target_unchanged},
  "replay_outcome": "${replay_outcome}",
  "contract_satisfied": ${contract_satisfied},
  "run_id": "${RUN_ID}"
}
JSON

  # Write conflict policy artifact
  printf '%s\n' "$CONFLICT_POLICY" > "$ARTIFACTS/conflict-policy.txt"

  log "Replay status: outcome=${replay_outcome}, contract_satisfied=${contract_satisfied}"

  if [[ "$contract_satisfied" != "true" ]]; then
    log "FAIL: Replay contract not satisfied"
    log "Expected: ${REPLAY_EXPECTATION}, Got: ${replay_outcome}"
    exit 1
  fi
}

main() {
  require_linux_vm
  require_root
  install_etcd
  install_k3s
  populate_k3s
  snapshot_k3s_etcd
  restore_source_standalone
  start_target_standalone
  run_migrator_dump

  log "=== First load ==="
  if ! run_migrator_load "first" "first-load"; then
    log "FAIL: First load failed"
    exit 1
  fi
  first_compare_ok=true
  collect_compare_evidence "first" || first_compare_ok=false

  log "=== Second load (replay) ==="
  run_migrator_load "second" "second-load" || true
  second_compare_ok=true
  collect_compare_evidence "second" || second_compare_ok=false

  collect_non_migrated_keys || true
  write_replay_status

  # Make safe artifact dirs readable by normal runner user without touching root-owned etcd work dirs
  chmod -R a+rX "$ARTIFACTS" "$RAW_ARTIFACTS" 2>/dev/null || true

  log "PASS: k3s embedded etcd replay/idempotence lab completed"
  log "Replay outcome: see $ARTIFACTS/replay-status.json"
}

main "$@"
