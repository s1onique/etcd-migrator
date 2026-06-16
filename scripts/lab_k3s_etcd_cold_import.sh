#!/usr/bin/env bash
# lab_k3s_etcd_cold_import.sh — k3s embedded etcd → standalone etcd cold import lab
#
# This lab proves etcd-migrator can migrate a real Kubernetes/k3s etcd dataset
# into a clean standalone etcd target using a cold, snapshot-restored source copy.
#
# Topology:
#   k3s server (embedded etcd, hot) → snapshot → standalone source (restored)
#   → migrator → standalone target (empty)
#
set -euo pipefail

LAB_NAME="lab-k3s-etcd-cold-import"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
LAB_ROOT="${LAB_ROOT:-$PWD/runs/${LAB_NAME}-${RUN_ID}}"
ARTIFACTS="$LAB_ROOT/artifacts"
WORK="$LAB_ROOT/work"
BIN="$LAB_ROOT/bin"

K3S_CHANNEL="${K3S_CHANNEL:-stable}"
ETCD_VERSION="${ETCD_VERSION:-v3.5.21}"
OBJECT_COUNT="${OBJECT_COUNT:-20}"
UPLOAD_RAW_ETCD_ARTIFACTS="${UPLOAD_RAW_ETCD_ARTIFACTS:-false}"

mkdir -p "$ARTIFACTS" "$WORK" "$BIN"

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
    echo "Try: sudo bash scripts/lab_k3s_etcd_cold_import.sh" >&2
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

  log "Waiting for k3s node readiness"
  /usr/local/bin/kubectl wait --for=condition=Ready node --all --timeout=240s
  /usr/local/bin/kubectl version -o yaml > "$ARTIFACTS/kubectl-version.yaml"
  /usr/local/bin/k3s --version > "$ARTIFACTS/k3s-version.txt"
}

populate_k3s() {
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

  log "Populating real Kubernetes API objects"
  for ns in lab-a lab-b; do
    /usr/local/bin/kubectl create namespace "$ns" \
      --dry-run=client -o yaml | /usr/local/bin/kubectl apply -f -

    /usr/local/bin/kubectl create serviceaccount "sa-${ns}" -n "$ns" \
      --dry-run=client -o yaml | /usr/local/bin/kubectl apply -f -

    for i in $(seq 1 "$OBJECT_COUNT"); do
      /usr/local/bin/kubectl create configmap "cm-${i}" \
        -n "$ns" \
        --from-literal="key-${i}=value-${i}" \
        --dry-run=client -o yaml | /usr/local/bin/kubectl apply -f -

      /usr/local/bin/kubectl create secret generic "secret-${i}" \
        -n "$ns" \
        --from-literal="token=synthetic-${ns}-${i}" \
        --dry-run=client -o yaml | /usr/local/bin/kubectl apply -f -
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

  /usr/local/bin/kubectl apply -f "$WORK/lab-crd.yaml"

  log "Waiting for CRD to become Established"
  /usr/local/bin/kubectl wait \
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

  /usr/local/bin/kubectl apply -f "$WORK/lab-widget.yaml"

  /usr/local/bin/kubectl get ns,cm,secret,sa -A -o wide > "$ARTIFACTS/k8s-inventory.txt"
  /usr/local/bin/kubectl get crd widgets.lab.example.com -o yaml > "$ARTIFACTS/k8s-crd-widget.yaml"
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
    cp "$snapshot" "$ARTIFACTS/k3s-embedded-etcd.snapshot.db"
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

run_migrator() {
  log "Running etcd-migrator from restored source to empty target"

  # Dump from source etcd
  ./bin/etcd-migrator dump \
    --source-endpoints="http://127.0.0.1:23790" \
    --output "$WORK/source.dump.jsonl"

  # Load into target etcd
  ./bin/etcd-migrator load \
    --target-endpoints="http://127.0.0.1:24790" \
    --input "$WORK/source.dump.jsonl"

  log "Migrator completed"
}

collect_compare_evidence() {
  log "Collecting source/target comparison evidence"

  # Key-only comparison
  ETCDCTL_API=3 "$BIN/etcdctl" \
    --endpoints=http://127.0.0.1:23790 \
    get / --prefix --keys-only \
    | sort > "$WORK/source.keys"

  ETCDCTL_API=3 "$BIN/etcdctl" \
    --endpoints=http://127.0.0.1:24790 \
    get / --prefix --keys-only \
    | sort > "$WORK/target.keys"

  wc -l "$WORK/source.keys" "$WORK/target.keys" \
    > "$ARTIFACTS/key-counts.txt"

  if diff -u "$WORK/source.keys" "$WORK/target.keys" > "$ARTIFACTS/key-diff.txt"; then
    keysets_match=true
  else
    keysets_match=false
  fi

  # Key+value hash comparison (safe: base64-encoded, not uploaded to git)
  ETCDCTL_API=3 "$BIN/etcdctl" \
    --endpoints=http://127.0.0.1:23790 \
    get / --prefix --write-out=json \
    | jq -r '.kvs[] | [.key, .value] | @tsv' \
    | sort > "$WORK/source.kv.tsv"

  ETCDCTL_API=3 "$BIN/etcdctl" \
    --endpoints=http://127.0.0.1:24790 \
    get / --prefix --write-out=json \
    | jq -r '.kvs[] | [.key, .value] | @tsv' \
    | sort > "$WORK/target.kv.tsv"

  sha256sum "$WORK/source.kv.tsv" > "$ARTIFACTS/source-kv-sha256.txt"
  sha256sum "$WORK/target.kv.tsv" > "$ARTIFACTS/target-kv-sha256.txt"

  if diff -q "$WORK/source.kv.tsv" "$WORK/target.kv.tsv" >/dev/null 2>&1; then
    kv_match=true
  else
    kv_match=false
  fi

  ETCDCTL_API=3 "$BIN/etcdctl" \
    --endpoints=http://127.0.0.1:24790 \
    endpoint status --write-out=json \
    > "$ARTIFACTS/target-endpoint-status-after.json"

  # Write comparison status JSON
  cat > "$ARTIFACTS/compare-status.json" <<JSON
{
  "keysets_match": ${keysets_match},
  "kv_match": ${kv_match},
  "run_id": "${RUN_ID}"
}
JSON

  log "Compare status: keysets_match=${keysets_match}, kv_match=${kv_match}"

  if [[ "${keysets_match}" != "true" ]] || [[ "${kv_match}" != "true" ]]; then
    log "FAIL: source and target do not match"
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
  run_migrator
  collect_compare_evidence

  log "PASS: k3s embedded etcd snapshot restored and migrated into standalone target"
}

main "$@"
