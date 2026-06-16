#!/usr/bin/env bash
# verify_k3s_postgres_kine_to_etcd_artifact.sh — Verifier for k3s PostgreSQL/Kine to etcd migration lab
#
# Validates a lab artifact directory and fails closed when the artifact set is
# missing, malformed, unsafe, or does not prove the migration succeeded.
#
# Usage:
#   scripts/verify_k3s_postgres_kine_to_etcd_artifact.sh <artifact-dir>
#   scripts/verify_k3s_postgres_kine_to_etcd_artifact.sh --self-test
#
# Exit 0 only when the artifact directory proves a successful safe lab run.
# Exit non-zero with clear diagnostics for missing/malformed/unsafe artifacts.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES_DIR="$SCRIPT_DIR/../fixtures/k3s_postgres_kine_to_etcd_artifact"

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
# JSON field helper
# ----------------------------------------------------------------------

json_field() {
  local file="$1"
  local field="$2"
  jq -r --arg field "$field" 'if has($field) then .[$field] else "__MISSING__" end' "$file"
}

# ----------------------------------------------------------------------
# Core verification functions
# ----------------------------------------------------------------------

verify_artifact_dir() {
  local artifact_dir="$1"
  local failures=0

  # =====================================================================
  # PostgreSQL/Kine proof
  # =====================================================================

  info "=== Verifying PostgreSQL/Kine Proof ==="

  # 1. Check kine row count exists and is > 0
  if [[ ! -f "$artifact_dir/pre/postgres-kine-row-count.txt" ]]; then
    err "Missing required file: pre/postgres-kine-row-count.txt"
    failures=$((failures + 1))
  else
    local row_count
    row_count=$(tr -d '[:space:]' < "$artifact_dir/pre/postgres-kine-row-count.txt")
    if ! [[ "$row_count" =~ ^[0-9]+$ ]] || [[ "$row_count" -eq 0 ]]; then
      err "kine row count must be > 0, got '$row_count'"
      failures=$((failures + 1))
    else
      info "kine row count: $row_count (> 0, PASS)"
    fi
  fi

  # 2. Check kine registry sample exists
  if [[ ! -f "$artifact_dir/pre/postgres-kine-registry-sample.txt" ]]; then
    err "Missing required file: pre/postgres-kine-registry-sample.txt"
    failures=$((failures + 1))
  else
    # 3. Check sample contains /registry/namespaces/migrator-lab
    if ! grep -q '/registry/namespaces/migrator-lab' "$artifact_dir/pre/postgres-kine-registry-sample.txt" 2>/dev/null; then
      err "kine registry sample does not contain /registry/namespaces/migrator-lab"
      failures=$((failures + 1))
    else
      info "kine registry sample contains namespace (PASS)"
    fi

    # 4. Check sample contains /registry/configmaps/migrator-lab/cm-alpha
    if ! grep -q '/registry/configmaps/migrator-lab/cm-alpha' "$artifact_dir/pre/postgres-kine-registry-sample.txt" 2>/dev/null; then
      err "kine registry sample does not contain /registry/configmaps/migrator-lab/cm-alpha"
      failures=$((failures + 1))
    else
      info "kine registry sample contains configmap (PASS)"
    fi
  fi

  # =====================================================================
  # Target etcd proof
  # =====================================================================

  info "=== Verifying Target etcd Proof ==="

  # 5. Check target was empty before import (fail-closed)
  if [[ ! -f "$artifact_dir/pre/target-etcd-registry-keys-before.txt" ]]; then
    err "Missing required file: pre/target-etcd-registry-keys-before.txt"
    failures=$((failures + 1))
  else
    local keys_before
    keys_before=$(wc -l < "$artifact_dir/pre/target-etcd-registry-keys-before.txt" | tr -d ' ')
    if [[ "$keys_before" != "0" ]]; then
      err "target etcd had $keys_before keys before import; expected 0 for fresh target"
      failures=$((failures + 1))
    else
      info "target etcd was empty before import (PASS)"
    fi
  fi

  # 6. Check post-import etcd state exists
  if [[ ! -f "$artifact_dir/post/etcd-registry-keys-after.txt" ]]; then
    err "Missing required file: post/etcd-registry-keys-after.txt"
    failures=$((failures + 1))
  else
    local keys_after
    keys_after=$(wc -l < "$artifact_dir/post/etcd-registry-keys-after.txt" | tr -d ' ')
    if [[ "$keys_after" -eq 0 ]]; then
      err "target etcd has 0 keys after import (migration failed)"
      failures=$((failures + 1))
    else
      info "target etcd has $keys_after keys after import (PASS)"
    fi
  fi

  # 7. Check compare-status.json exists and shows SUCCESS
  if [[ ! -f "$artifact_dir/migration/compare-status.json" ]]; then
    err "Missing required file: migration/compare-status.json"
    failures=$((failures + 1))
  elif ! jq empty "$artifact_dir/migration/compare-status.json" 2>/dev/null; then
    err "migration/compare-status.json is not valid JSON"
    failures=$((failures + 1))
  else
    local status
    status="$(json_field "$artifact_dir/migration/compare-status.json" "status")"
    if [[ "$status" == "__MISSING__" ]]; then
      err "compare-status.json missing .status field"
      failures=$((failures + 1))
    elif [[ "$status" != "SUCCESS" ]]; then
      err ".status must be SUCCESS, got '$status'"
      failures=$((failures + 1))
    else
      info "compare status: SUCCESS (PASS)"
    fi
  fi

  # =====================================================================
  # Kubernetes post-cutover proof
  # =====================================================================

  info "=== Verifying Kubernetes Post-Cutover Proof ==="

  # 8. Check cutover-status.json exists
  if [[ ! -f "$artifact_dir/cutover-status.json" ]]; then
    err "Missing required file: cutover-status.json"
    failures=$((failures + 1))
  elif ! jq empty "$artifact_dir/cutover-status.json" 2>/dev/null; then
    err "cutover-status.json is not valid JSON"
    failures=$((failures + 1))
  else
    # 9. Check namespace visible
    local ns_visible
    ns_visible="$(json_field "$artifact_dir/cutover-status.json" "namespace_visible")"
    if [[ "$ns_visible" == "__MISSING__" ]]; then
      err "cutover-status.json missing .namespace_visible field"
      failures=$((failures + 1))
    elif [[ "$ns_visible" != "true" ]]; then
      err ".namespace_visible must be true, got '$ns_visible'"
      failures=$((failures + 1))
    else
      info "namespace migrator-lab visible (PASS)"
    fi

    # 10. Check configmap visible
    local cm_visible
    cm_visible="$(json_field "$artifact_dir/cutover-status.json" "configmap_visible")"
    if [[ "$cm_visible" != "true" ]]; then
      err ".configmap_visible must be true, got '$cm_visible'"
      failures=$((failures + 1))
    else
      info "configmap cm-alpha visible (PASS)"
    fi

    # 11. Check serviceaccount visible
    local sa_visible
    sa_visible="$(json_field "$artifact_dir/cutover-status.json" "serviceaccount_visible")"
    if [[ "$sa_visible" != "true" ]]; then
      err ".serviceaccount_visible must be true, got '$sa_visible'"
      failures=$((failures + 1))
    else
      info "serviceaccount sa-alpha visible (PASS)"
    fi

    # 12. Check deployment visible
    local deploy_visible
    deploy_visible="$(json_field "$artifact_dir/cutover-status.json" "deployment_visible")"
    if [[ "$deploy_visible" != "true" ]]; then
      err ".deployment_visible must be true, got '$deploy_visible'"
      failures=$((failures + 1))
    else
      info "deployment deploy-alpha visible (PASS)"
    fi
  fi

  # =====================================================================
  # Secret safety
  # =====================================================================

  info "=== Verifying Secret Safety ==="

  local secret_files=(
    "$artifact_dir/pre/secret-metadata.txt"
    "$artifact_dir/post/secret-metadata.txt"
  )

  for secret_file in "${secret_files[@]}"; do
    if [[ -f "$secret_file" ]]; then
      # Check for raw Secret .data values
      if grep -E -- '\.data[[:space:]:]' "$secret_file" 2>/dev/null; then
        err "Forbidden .data field found in $secret_file"
        failures=$((failures + 1))
      fi

      # Check for kubeconfig client-certificate-data/client-key-data
      if grep -E -- 'client-certificate-data:' "$secret_file" 2>/dev/null; then
        err "Forbidden client-certificate-data found in $secret_file"
        failures=$((failures + 1))
      fi

      if grep -E -- 'client-key-data:' "$secret_file" 2>/dev/null; then
        err "Forbidden client-key-data found in $secret_file"
        failures=$((failures + 1))
      fi

      # Check for private key blocks
      if grep -E -- "-----BEGIN.*PRIVATE KEY-----" "$secret_file" 2>/dev/null; then
        err "Private key detected in $secret_file"
        failures=$((failures + 1))
      fi
    fi
  done

  # =====================================================================
  # Migration prefix verification
  # =====================================================================

  if [[ -f "$artifact_dir/migration-prefix.txt" ]]; then
    local prefix
    prefix="$(cat "$artifact_dir/migration-prefix.txt")"
    if [[ "$prefix" != "/registry/" ]]; then
      err "migration-prefix.txt must be /registry/, got '$prefix'"
      failures=$((failures + 1))
    fi
  fi

  # =====================================================================
  # Summary
  # =====================================================================

  if [[ $failures -eq 0 ]]; then
    info "Artifact verification PASSED for: $artifact_dir"
    return 0
  else
    err "Artifact verification FAILED: $failures error(s) detected"
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
  echo "=== K3s PostgreSQL/Kine to etcd Artifact Verifier Self-Test ==="
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
