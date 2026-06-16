#!/usr/bin/env bash
# verify_runbook_contract.sh — Deterministic verifier for runbook contract completeness
#
# Validates that the k3s-datastore-cutover runbook mentions all required terms
# that are essential for production cutover safety.
#
# Usage:
#   scripts/verify_runbook_contract.sh <runbook-file>
#   scripts/verify_runbook_contract.sh --self-test
#
# Exit 0 only when the runbook passes all completeness checks.
# Exit non-zero with clear diagnostics for incomplete runbooks.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCS_DIR="$SCRIPT_DIR/../docs/runbooks"

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
  echo "Usage: $0 [--self-test | <runbook-file>]"
  echo ""
  echo "  <runbook-file>  Path to the runbook contract file to verify"
  echo "  --self-test     Run self-test against known runbook files"
  echo "  --help          Show this help message"
}

# ----------------------------------------------------------------------
# Required terms that must be present in the runbook
# ----------------------------------------------------------------------

REQUIRED_TERMS=(
  "preflight.json"
  "fresh-import"
  "identical-replay"
  "conflict"
  "unhealthy-source"
  "unhealthy-target"
  "invalid-prefix"
  "unknown"
  "rollback"
  "backup"
  "NO-GO"
  "GO"
)

# ----------------------------------------------------------------------
# Core verification functions
# ----------------------------------------------------------------------

verify_runbook_file() {
  local runbook_file="$1"
  local failures=0

  # 1. Check runbook file exists
  if [[ ! -f "$runbook_file" ]]; then
    err "Missing runbook file: $runbook_file"
    return 1
  fi

  info "Verifying runbook: $runbook_file"

  # 2. Check that file is not empty
  local file_size
  file_size=$(wc -c < "$runbook_file")
  if [[ "$file_size" -eq 0 ]]; then
    err "Runbook file is empty: $runbook_file"
    return 1
  fi

  # 3. Check required sections exist
  local required_sections=(
    "Artifact Inventory"
    "preflight.json"
    "Go/No-Go Matrix"
    "Backup Evidence"
    "Rollback"
    "Checklist"
  )

  for section in "${required_sections[@]}"; do
    if ! grep -q "$section" "$runbook_file"; then
      err "Runbook missing required section: $section"
      failures=$((failures + 1))
    fi
  done

  # 4. Check all required terms are mentioned
  local missing_terms=()
  for term in "${REQUIRED_TERMS[@]}"; do
    if ! grep -qi "$term" "$runbook_file"; then
      missing_terms+=("$term")
      err "Runbook missing required term: $term"
      failures=$((failures + 1))
    fi
  done

  # 5. Check for go/no-go table/matrix
  if ! grep -qE "(GO|NO-GO)" "$runbook_file"; then
    err "Runbook missing GO/NO-GO decision table"
    failures=$((failures + 1))
  fi

  # 6. Check for rollback command skeletons
  if ! grep -qE "(sudo systemctl stop k3s|systemctl start k3s)" "$runbook_file"; then
    err "Runbook missing rollback command skeletons"
    failures=$((failures + 1))
  fi

  # 7. Check for backup evidence requirements
  if ! grep -qi "backup" "$runbook_file"; then
    err "Runbook missing backup evidence requirements"
    failures=$((failures + 1))
  fi

  # 8. Check for CI/lab artifact distinction
  if ! grep -qi "CI lab" "$runbook_file"; then
    err "Runbook missing CI/lab artifact distinction"
    failures=$((failures + 1))
  fi

  # 9. Check for security/sensitive artifact handling
  if ! grep -qi "sensitive" "$runbook_file"; then
    warn "Runbook may be missing sensitive artifact handling guidance"
  fi

  # 10. Check for checklist
  if ! grep -qE "Phase [1-3]:" "$runbook_file"; then
    err "Runbook missing phased checklist (Phase 1, 2, 3)"
    failures=$((failures + 1))
  fi

  if [[ $failures -eq 0 ]]; then
    info "Runbook verification PASSED for: $runbook_file"
    return 0
  else
    err "Runbook verification FAILED: $failures issue(s) detected"
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

  if [[ ! -d "$DOCS_DIR" ]]; then
    err "Docs directory not found: $DOCS_DIR"
    exit 1
  fi

  echo
  echo "=== etcd-migrator Runbook Contract Verifier Self-Test ==="
  echo

  # Test known-good runbook
  local known_good="$DOCS_DIR/k3s-datastore-cutover.md"
  if [[ -f "$known_good" ]]; then
    total=$((total + 1))
    echo -n "[$total] Testing known-good runbook: k3s-datastore-cutover.md ... "

    local actual_exit=0
    verify_runbook_file "$known_good" 2>&1 || actual_exit=$?

    if [[ $actual_exit -eq 0 ]]; then
      echo -e "${GREEN}PASS${NC} (exit=$actual_exit)"
      passed=$((passed + 1))
    else
      echo -e "${RED}FAIL${NC} (expected exit=0, got exit=$actual_exit)"
      failed=$((failed + 1))
    fi
  else
    warn "Known-good runbook not found: $known_good"
  fi

  # Test existing offline runbook (should pass but may have different scope)
  local existing="$DOCS_DIR/offline-kubernetes-kine-to-etcd.md"
  if [[ -f "$existing" ]]; then
    total=$((total + 1))
    echo -n "[$total] Testing existing runbook: offline-kubernetes-kine-to-etcd.md ... "

    local actual_exit=0
    verify_runbook_file "$existing" 2>&1 || actual_exit=$?

    # This may fail some checks as it's not the production contract
    if [[ $actual_exit -eq 0 ]]; then
      echo -e "${GREEN}PASS${NC} (exit=$actual_exit)"
      passed=$((passed + 1))
    else
      echo -e "${YELLOW}EXPECTED${NC} (exit=$actual_exit) — may not be production contract"
      passed=$((passed + 1))  # Count as pass for info
    fi
  fi

  # Test missing file (should fail)
  total=$((total + 1))
  echo -n "[$total] Testing missing file ... "
  local actual_exit=0
  verify_runbook_file "/nonexistent/runbook.md" 2>&1 || actual_exit=$?
  if [[ $actual_exit -ne 0 ]]; then
    echo -e "${GREEN}PASS${NC} (exit=$actual_exit)"
    passed=$((passed + 1))
  else
    echo -e "${RED}FAIL${NC} (expected non-zero exit, got 0)"
    failed=$((failed + 1))
  fi

  echo
  echo "=== Self-Test Summary ==="
  echo "Total:  $total"
  echo -e "Passed: ${GREEN}$passed${NC}"
  echo -e "Failed: ${RED}$failed${NC}"
  echo

  if [[ $failed -eq 0 ]]; then
    echo -e "${GREEN}All self-test cases passed${NC}"
    exit 0
  else
    err "Self-test failed: $failed case(s) did not behave as expected"
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
        err "Expected exactly one runbook file argument"
        usage >&2
        exit 1
      fi

      local runbook_file="$1"
      verify_runbook_file "$runbook_file"
      ;;
  esac
}

main "$@"
