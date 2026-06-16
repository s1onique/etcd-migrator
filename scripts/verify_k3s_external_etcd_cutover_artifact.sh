#!/usr/bin/env bash
# verify_k3s_external_etcd_cutover_artifact.sh — Deterministic verifier for k3s external etcd cutover artifacts
#
# Validates a cutover artifact directory and fails closed when the artifact set is
# missing, malformed, unsafe, or does not prove k3s can boot against the migrated
# external etcd.
#
# Usage:
#   scripts/verify_k3s_external_etcd_cutover_artifact.sh <artifact-dir>
#   scripts/verify_k3s_external_etcd_cutover_artifact.sh --self-test
#
# Exit 0 only when the artifact directory proves a successful safe cutover lab run.
# Exit non-zero with clear diagnostics for missing/malformed/unsafe artifacts.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES_DIR="$SCRIPT_DIR/../fixtures/k3s_external_etcd_cutover_artifact"

# Colors for diagnostics
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

err() {
  echo -e "${RED}ERROR${NC}: $*" >&2
}

warn() {
  echo -e "${YELLOW}WARNING${NC}: $*" >&2
}

info() {
  echo -e "${GREEN}INFO${NC}: $*"
}

usage() {
  echo "Usage: $0 [--self-test | <artifact-dir>]"
  echo ""
  echo "  <artifact-dir>    Path to the lab artifact directory to verify"
  echo "  --self-test       Run self-test against fixture directories"
  echo "  --help            Show this help message"
}

# ----------------------------------------------------------------------
# Core verification functions
# ----------------------------------------------------------------------

verify_artifact_dir() {
  local artifact_dir="$1"
  local failures=0

  info "Verifying cutover artifact directory: $artifact_dir"

  # 1. Check migration-prefix.txt exists and equals /registry/
  if [[ ! -f "$artifact_dir/migration-prefix.txt" ]]; then
    err "Missing required file: migration-prefix.txt"
    failures=$((failures + 1))
  else
    local prefix_file
    prefix_file="$(cat "$artifact_dir/migration-prefix.txt")"
    if [[ "$prefix_file" != "/registry/" ]]; then
      err "migration-prefix.txt must be '/registry/', got '$prefix_file'"
      failures=$((failures + 1))
    fi
  fi

  # 2. Check cutover-status.json exists
  if [[ ! -f "$artifact_dir/cutover-status.json" ]]; then
    err "Missing required file: cutover-status.json"
    failures=$((failures + 1))
  elif ! jq empty "$artifact_dir/cutover-status.json" 2>/dev/null; then
    err "cutover-status.json is not valid JSON"
    failures=$((failures + 1))
  fi

  # 3. Check external-etcd-health.txt exists
  if [[ ! -f "$artifact_dir/target/external-etcd-health.txt" ]]; then
    err "Missing required file: target/external-etcd-health.txt"
    failures=$((failures + 1))
  fi

  # 4. Check k3s-start.log exists and contains success indicators
  if [[ ! -f "$artifact_dir/target/k3s-start.log" ]]; then
    err "Missing required file: target/k3s-start.log"
    failures=$((failures + 1))
  else
    if ! grep -q "Kubernetes API is ready" "$artifact_dir/target/k3s-start.log"; then
      err "k3s-start.log does not contain 'Kubernetes API is ready'"
      failures=$((failures + 1))
    fi
    if ! grep -q "k3s startup PASSED" "$artifact_dir/target/k3s-start.log"; then
      err "k3s-start.log does not contain 'k3s startup PASSED'"
      failures=$((failures + 1))
    fi
  fi

  # 5. Check source kubectl evidence exists
  if [[ ! -f "$artifact_dir/source/source-kubectl-namespaces.txt" ]]; then
    err "Missing required file: source/source-kubectl-namespaces.txt"
    failures=$((failures + 1))
  fi
  if [[ ! -f "$artifact_dir/source/source-kubectl-configmaps.txt" ]]; then
    err "Missing required file: source/source-kubectl-configmaps.txt"
    failures=$((failures + 1))
  fi
  if [[ ! -f "$artifact_dir/source/source-kubectl-secrets-metadata.txt" ]]; then
    err "Missing required file: source/source-kubectl-secrets-metadata.txt"
    failures=$((failures + 1))
  fi
  if [[ ! -f "$artifact_dir/source/source-kubectl-crds.txt" ]]; then
    err "Missing required file: source/source-kubectl-crds.txt"
    failures=$((failures + 1))
  fi

  # 6. Check cutover kubectl evidence exists
  if [[ ! -f "$artifact_dir/target/cutover-kubectl-namespaces.txt" ]]; then
    err "Missing required file: target/cutover-kubectl-namespaces.txt"
    failures=$((failures + 1))
  fi
  if [[ ! -f "$artifact_dir/target/cutover-kubectl-configmaps.txt" ]]; then
    err "Missing required file: target/cutover-kubectl-configmaps.txt"
    failures=$((failures + 1))
  fi
  if [[ ! -f "$artifact_dir/target/cutover-kubectl-secrets-metadata.txt" ]]; then
    err "Missing required file: target/cutover-kubectl-secrets-metadata.txt"
    failures=$((failures + 1))
  fi
  if [[ ! -f "$artifact_dir/target/cutover-kubectl-crds.txt" ]]; then
    err "Missing required file: target/cutover-kubectl-crds.txt"
    failures=$((failures + 1))
  fi
  if [[ ! -f "$artifact_dir/target/cutover-kubectl-custom-resources.txt" ]]; then
    err "Missing required file: target/cutover-kubectl-custom-resources.txt"
    failures=$((failures + 1))
  fi

  # 7. Check expected test objects are present in cutover output
  if ! grep -q "etcd-migrator-cutover" "$artifact_dir/target/cutover-kubectl-namespaces.txt" 2>/dev/null; then
    err "Cutover namespaces missing test namespace 'etcd-migrator-cutover'"
    failures=$((failures + 1))
  fi
  if ! grep -q "etcd-migrator-cutover-config" "$artifact_dir/target/cutover-kubectl-configmaps.txt" 2>/dev/null; then
    err "Cutover configmaps missing test ConfigMap 'etcd-migrator-cutover-config'"
    failures=$((failures + 1))
  fi
  if ! grep -q "etcd-migrator-cutover-secret" "$artifact_dir/target/cutover-kubectl-secrets-metadata.txt" 2>/dev/null; then
    err "Cutover secrets metadata missing test Secret 'etcd-migrator-cutover-secret'"
    failures=$((failures + 1))
  fi
  if ! grep -q "widgets.cutover.etcd-migrator.dev" "$artifact_dir/target/cutover-kubectl-crds.txt" 2>/dev/null; then
    err "Cutover CRDs missing test CRD 'widgets.cutover.etcd-migrator.dev'"
    failures=$((failures + 1))
  fi
  if ! grep -q "sample-widget" "$artifact_dir/target/cutover-kubectl-custom-resources.txt" 2>/dev/null; then
    err "Cutover custom resources missing test Widget 'sample-widget'"
    failures=$((failures + 1))
  fi

  # 8. Check comparison artifacts exist
  if [[ ! -f "$artifact_dir/migration/compare-status.json" ]]; then
    err "Missing required file: migration/compare-status.json"
    failures=$((failures + 1))
  elif ! jq empty "$artifact_dir/migration/compare-status.json" 2>/dev/null; then
    err "migration/compare-status.json is not valid JSON"
    failures=$((failures + 1))
  else
    local keysets_match kv_match
    keysets_match="$(jq -r '.keysets_match // empty' "$artifact_dir/migration/compare-status.json")"
    kv_match="$(jq -r '.kv_match // empty' "$artifact_dir/migration/compare-status.json")"
    if [[ "$keysets_match" != "true" ]]; then
      err "migration/compare-status.json .keysets_match must be true, got '$keysets_match'"
      failures=$((failures + 1))
    fi
    if [[ "$kv_match" != "true" ]]; then
      err "migration/compare-status.json .kv_match must be true, got '$kv_match'"
      failures=$((failures + 1))
    fi
  fi

  # 9. Check source/target KV hashes exist and match
  if [[ ! -f "$artifact_dir/migration/source-kv-sha256.txt" ]]; then
    err "Missing required file: migration/source-kv-sha256.txt"
    failures=$((failures + 1))
  fi
  if [[ ! -f "$artifact_dir/migration/target-kv-sha256.txt" ]]; then
    err "Missing required file: migration/target-kv-sha256.txt"
    failures=$((failures + 1))
  fi
  if [[ -f "$artifact_dir/migration/source-kv-sha256.txt" ]] && [[ -f "$artifact_dir/migration/target-kv-sha256.txt" ]]; then
    local src_hash tgt_hash
    src_hash="$(cut -d' ' -f1 "$artifact_dir/migration/source-kv-sha256.txt")"
    tgt_hash="$(cut -d' ' -f1 "$artifact_dir/migration/target-kv-sha256.txt")"
    if [[ "$src_hash" != "$tgt_hash" ]]; then
      err "KV hash mismatch: source=$src_hash, target=$tgt_hash"
      failures=$((failures + 1))
    fi
  fi

  # 10. Verify secret outputs are metadata-only (no .data or .stringData values) - check both dotted and bare forms
  # Check for .data field (dotted form)
  if grep -E -- '(^|[[:space:]])\.data[[:space:]:]' "$artifact_dir/target/cutover-kubectl-secrets-metadata.txt" 2>/dev/null; then
    err "Unsafe: .data field found in cutover-kubectl-secrets-metadata.txt"
    failures=$((failures + 1))
  fi
  # Check for .stringData field (dotted form)
  if grep -E -- '(^|[[:space:]])\.stringData[[:space:]:]' "$artifact_dir/target/cutover-kubectl-secrets-metadata.txt" 2>/dev/null; then
    err "Unsafe: .stringData field found in cutover-kubectl-secrets-metadata.txt"
    failures=$((failures + 1))
  fi
  # Check for bare data: field (unsafe YAML key in secret output)
  if grep -E -- '(^|[[:space:]])data:[[:space:]]' "$artifact_dir/target/cutover-kubectl-secrets-metadata.txt" 2>/dev/null; then
    err "Unsafe: bare 'data:' field found in cutover-kubectl-secrets-metadata.txt"
    failures=$((failures + 1))
  fi
  # Check for bare stringData: field (unsafe YAML key in secret output)
  if grep -E -- '(^|[[:space:]])stringData:[[:space:]]' "$artifact_dir/target/cutover-kubectl-secrets-metadata.txt" 2>/dev/null; then
    err "Unsafe: bare 'stringData:' field found in cutover-kubectl-secrets-metadata.txt"
    failures=$((failures + 1))
  fi

  # 11. Check for forbidden sensitive material patterns in all artifacts (use -- to prevent pattern being treated as flag)
  local sensitive_patterns=(
    "-----BEGIN.*PRIVATE KEY-----"
    "-----BEGIN.*RSA PRIVATE KEY-----"
    "client-certificate-data:"
    "client-key-data:"
  )
  for pattern in "${sensitive_patterns[@]}"; do
    if grep -rE -- "$pattern" "$artifact_dir/" 2>/dev/null; then
      err "Forbidden sensitive pattern '$pattern' found in artifacts"
      failures=$((failures + 1))
    fi
  done

  # 12. Check safe artifact directory does not contain raw snapshots
  local raw_snapshot_files
  raw_snapshot_files=$(find "$artifact_dir" -type f \( -name '*.db' \) 2>/dev/null || true)
  if [[ -n "$raw_snapshot_files" ]]; then
    err "Unsafe raw snapshot files present: $raw_snapshot_files"
    failures=$((failures + 1))
  fi

  # 13. Check safe artifact directory does not contain raw migrator dumps
  local raw_dump_files
  raw_dump_files=$(find "$artifact_dir" -type f \( -name '*.jsonl' \) 2>/dev/null || true)
  if [[ -n "$raw_dump_files" ]]; then
    err "Unsafe raw dump files present: $raw_dump_files"
    failures=$((failures + 1))
  fi

  # 14. Check key-diff.txt exists and is empty
  if [[ -f "$artifact_dir/migration/key-diff.txt" ]] && [[ -s "$artifact_dir/migration/key-diff.txt" ]]; then
    err "key-diff.txt is not empty (keyset mismatch detected)"
    failures=$((failures + 1))
  fi

  if [[ $failures -eq 0 ]]; then
    info "Cutover artifact verification PASSED for: $artifact_dir"
    return 0
  else
    err "Cutover artifact verification FAILED: $failures error(s) detected"
    return 1
  fi
}

# ----------------------------------------------------------------------
# Self-test mode
# ----------------------------------------------------------------------

run_self_test() {
  local total=0
  local passed=0
  local failed=0

  if [[ ! -d "$FIXTURES_DIR" ]]; then
    err "Fixtures directory not found: $FIXTURES_DIR"
    exit 1
  fi

  echo
  echo "=== k3s External etcd Cutover Artifact Verifier Self-Test ==="
  echo

  for fixture_dir in "$FIXTURES_DIR"/*; do
    if [[ ! -d "$fixture_dir" ]]; then
      continue
    fi

    local fixture_name
    fixture_name="$(basename "$fixture_dir")"
    total=$((total + 1))

    echo -n "[$total] Testing fixture: $fixture_name ... "

    # Determine expected outcome from fixture name
    local expected_exit=1  # Default: expect failure
    if [[ "$fixture_name" == "good" ]]; then
      expected_exit=0
    fi

    # Run verification
    local actual_exit=0
    verify_artifact_dir "$fixture_dir" 2>&1 || actual_exit=$?

    if [[ $actual_exit -eq $expected_exit ]]; then
      echo -e "${GREEN}PASS${NC} (exit=$actual_exit)"
      passed=$((passed + 1))
    else
      echo -e "${RED}FAIL${NC} (expected exit=$expected_exit, got exit=$actual_exit)"
      failed=$((failed + 1))
    fi
  done

  echo
  echo "=== Self-Test Summary ==="
  echo "Total:  $total"
  echo -e "Passed: ${GREEN}$passed${NC}"
  echo -e "Failed: ${RED}$failed${NC}"
  echo

  if [[ $failed -eq 0 ]]; then
    echo -e "${GREEN}All self-test fixtures passed${NC}"
    exit 0
  else
    err "Self-test failed: $failed fixture(s) did not behave as expected"
    exit 1
  fi
}

# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------

main() {
  if [[ $# -eq 0 ]]; then
    usage >&2
    exit 1
  fi

  case "$1" in
    --self-test)
      run_self_test
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    -*)
      err "Unknown option: $1"
      usage >&2
      exit 1
      ;;
    *)
      if [[ $# -ne 1 ]]; then
        err "Expected exactly one artifact directory argument"
        usage >&2
        exit 1
      fi

      local artifact_dir="$1"
      if [[ ! -d "$artifact_dir" ]]; then
        err "Artifact directory does not exist: $artifact_dir"
        exit 1
      fi

      verify_artifact_dir "$artifact_dir"
      ;;
  esac
}

main "$@"
