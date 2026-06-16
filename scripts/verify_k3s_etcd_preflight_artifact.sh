#!/usr/bin/env bash
# verify_k3s_etcd_preflight_artifact.sh — Deterministic verifier for preflight report artifacts
#
# Validates preflight report JSON files and fails closed when the report is
# missing required fields, has invalid values, or contains secret-like content.
#
# Usage:
#   scripts/verify_k3s_etcd_preflight_artifact.sh <report-file>
#   scripts/verify_k3s_etcd_preflight_artifact.sh --self-test
#
# Exit 0 only when the report passes all validation checks.
# Exit non-zero with clear diagnostics for invalid/unsafe reports.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES_DIR="$SCRIPT_DIR/../fixtures/k3s_etcd_preflight_artifact"

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

# ----------------------------------------------------------------------
# JSON field helper — handles boolean false correctly (unlike // empty)
# ----------------------------------------------------------------------

json_field() {
  local file="$1"
  local field="$2"
  jq -r --arg field "$field" 'if has($field) then .[$field] else "__MISSING__" end' "$file"
}

usage() {
  echo "Usage: $0 [--self-test | <report-file>]"
  echo ""
  echo "  <report-file>  Path to the preflight report JSON file to verify"
  echo "  --self-test    Run self-test against fixture directories"
  echo "  --help         Show this help message"
}

# ----------------------------------------------------------------------
# Secret detection patterns
# ----------------------------------------------------------------------

# Patterns that indicate secret-like content that should never appear in reports
SECRET_PATTERNS=(
  '"password"'
  '"token"'
  '"secret"'
  '"credential"'
  '"private_key"'
  '"private-key"'
  '"api_key"'
  '"api-key"'
  '"bearer"'
  '"authorization"'
  'BEGIN RSA PRIVATE KEY'
  'BEGIN PRIVATE KEY'
  'BEGIN EC PRIVATE KEY'
)

# ----------------------------------------------------------------------
# Core verification functions
# ----------------------------------------------------------------------

verify_report_file() {
  local report_file="$1"
  local failures=0

  # 1. check report file exists
  if [[ ! -f "$report_file" ]]; then
    err "Missing report file: $report_file"
    return 1
  fi

  # 2. check valid JSON
  if ! jq empty "$report_file" 2>/dev/null; then
    err "Report file is not valid JSON: $report_file"
    failures=$((failures + 1))
    return 1
  fi

  # 3. check required top-level fields exist
  local required_fields=(
    "go_no_go"
    "classification"
    "source_endpoint"
    "target_endpoint"
    "prefix"
    "conflict_policy"
    "source_prefix_key_count"
    "target_prefix_key_count"
    "tool_version"
    "timestamp"
  )

  for field in "${required_fields[@]}"; do
    local value
    value="$(json_field "$report_file" "$field")"
    if [[ "$value" == "__MISSING__" ]]; then
      err "Report missing required field: $field"
      failures=$((failures + 1))
    fi
  done

  if [[ $failures -gt 0 ]]; then
    return 1
  fi

  # 4. check go_no_go is boolean
  local go_no_go
  go_no_go="$(json_field "$report_file" "go_no_go")"
  if [[ "$go_no_go" != "true" ]] && [[ "$go_no_go" != "false" ]]; then
    err "go_no_go must be boolean (true/false), got: $go_no_go"
    failures=$((failures + 1))
  fi

  # 5. check classification is valid
  local classification
  classification="$(json_field "$report_file" "classification")"
  local valid_classifications=(
    "fresh-import"
    "identical-replay"
    "conflict"
    "empty-source"
    "unhealthy-source"
    "unhealthy-target"
    "invalid-prefix"
    "unknown"
  )

  local valid=false
  for valid_class in "${valid_classifications[@]}"; do
    if [[ "$classification" == "$valid_class" ]]; then
      valid=true
      break
    fi
  done
  if [[ "$valid" == "false" ]]; then
    err "classification must be one of: ${valid_classifications[*]}, got: $classification"
    failures=$((failures + 1))
  fi

  # 6. check source_endpoint has required fields
  local src_healthy
  src_healthy="$(jq -r '.source_endpoint.healthy // empty' "$report_file")"
  if [[ -z "$src_healthy" ]]; then
    err "source_endpoint.healthy is required"
    failures=$((failures + 1))
  fi

  local src_endpoints
  src_endpoints="$(jq -r '.source_endpoint.endpoints // empty' "$report_file")"
  if [[ -z "$src_endpoints" ]] || [[ "$src_endpoints" == "null" ]]; then
    err "source_endpoint.endpoints is required"
    failures=$((failures + 1))
  fi

  # 7. check target_endpoint has required fields
  local tgt_healthy
  tgt_healthy="$(jq -r '.target_endpoint.healthy // empty' "$report_file")"
  if [[ -z "$tgt_healthy" ]]; then
    err "target_endpoint.healthy is required"
    failures=$((failures + 1))
  fi

  local tgt_endpoints
  tgt_endpoints="$(jq -r '.target_endpoint.endpoints // empty' "$report_file")"
  if [[ -z "$tgt_endpoints" ]] || [[ "$tgt_endpoints" == "null" ]]; then
    err "target_endpoint.endpoints is required"
    failures=$((failures + 1))
  fi

  # 8. check prefix is not empty
  local prefix
  prefix="$(json_field "$report_file" "prefix")"
  if [[ -z "$prefix" ]]; then
    err "prefix cannot be empty"
    failures=$((failures + 1))
  fi

  # 9. check conflict_policy is valid
  local conflict_policy
  conflict_policy="$(json_field "$report_file" "conflict_policy")"
  if [[ "$conflict_policy" != "fail-if-present" ]] && [[ "$conflict_policy" != "allow-identical-replay" ]]; then
    err "conflict_policy must be 'fail-if-present' or 'allow-identical-replay', got: $conflict_policy"
    failures=$((failures + 1))
  fi

  # 10. check key counts are non-negative integers
  local src_count tgt_count
  src_count="$(json_field "$report_file" "source_prefix_key_count")"
  tgt_count="$(json_field "$report_file" "target_prefix_key_count")"

  if ! [[ "$src_count" =~ ^[0-9]+$ ]]; then
    err "source_prefix_key_count must be non-negative integer, got: $src_count"
    failures=$((failures + 1))
  fi
  if ! [[ "$tgt_count" =~ ^[0-9]+$ ]]; then
    err "target_prefix_key_count must be non-negative integer, got: $tgt_count"
    failures=$((failures + 1))
  fi

  # 11. check tool_version is not empty
  local tool_version
  tool_version="$(json_field "$report_file" "tool_version")"
  if [[ -z "$tool_version" ]]; then
    err "tool_version cannot be empty"
    failures=$((failures + 1))
  fi

  # 12. check timestamp is valid ISO 8601
  local timestamp
  timestamp="$(json_field "$report_file" "timestamp")"
  if ! date -j -f "%Y-%m-%dT%H:%M:%SZ" "$timestamp" +%s >/dev/null 2>&1; then
    # Try alternative format with timezone
    if ! date -j -f "%Y-%m-%dT%H:%M:%S%z" "$timestamp" +%s >/dev/null 2>&1; then
      warn "timestamp may not be valid ISO 8601: $timestamp"
    fi
  fi

  # 13. check for secret-like content in the report
  local report_content
  report_content="$(cat "$report_file")"
  for pattern in "${SECRET_PATTERNS[@]}"; do
    if [[ "$report_content" == *"$pattern"* ]]; then
      err "Report contains secret-like pattern: $pattern"
      failures=$((failures + 1))
    fi
  done

  # 14. check for unexpected top-level fields that might contain secrets
  local top_level_fields
  top_level_fields="$(jq -r 'keys[]' "$report_file" 2>/dev/null || true)"
  local known_fields=(
    "go_no_go"
    "classification"
    "source_endpoint"
    "target_endpoint"
    "prefix"
    "conflict_policy"
    "source_prefix_key_count"
    "target_prefix_key_count"
    "warnings"
    "errors"
    "tool_version"
    "timestamp"
  )

  for field in $top_level_fields; do
    local known=false
    for known_field in "${known_fields[@]}"; do
      if [[ "$field" == "$known_field" ]]; then
        known=true
        break
      fi
    done
    if [[ "$known" == "false" ]]; then
      warn "Report has unexpected field that might contain secrets: $field"
      failures=$((failures + 1))
    fi
  done

  # 15. check warnings and errors are arrays
  local warnings_type errors_type
  warnings_type="$(jq -r '.warnings | type' "$report_file" 2>/dev/null || echo "null")"
  errors_type="$(jq -r '.errors | type' "$report_file" 2>/dev/null || echo "null")"

  if [[ "$warnings_type" != "array" ]] && [[ "$warnings_type" != "null" ]]; then
    err "warnings must be an array, got: $warnings_type"
    failures=$((failures + 1))
  fi
  if [[ "$errors_type" != "array" ]] && [[ "$errors_type" != "null" ]]; then
    err "errors must be an array, got: $errors_type"
    failures=$((failures + 1))
  fi

  if [[ $failures -eq 0 ]]; then
    info "Report verification PASSED for: $report_file"
    return 0
  else
    err "Report verification FAILED: $failures error(s) detected"
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
  echo "=== etcd-migrator Preflight Artifact Verifier Self-Test ==="
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
    if [[ "$fixture_name" == "good-"* ]] || [[ "$fixture_name" == "valid-"* ]]; then
      expected_exit=0
    fi

    # Run verification
    local actual_exit=0
    verify_report_file "$fixture_dir/preflight-report.json" 2>&1 || actual_exit=$?

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
        err "Expected exactly one report file argument"
        usage >&2
        exit 1
      fi

      local report_file="$1"
      if [[ ! -f "$report_file" ]]; then
        err "Report file does not exist: $report_file"
        exit 1
      fi

      verify_report_file "$report_file"
      ;;
  esac
}

main "$@"
