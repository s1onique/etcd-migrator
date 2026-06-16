#!/usr/bin/env bash
# verify_k3s_etcd_cold_import_artifact.sh — Deterministic verifier for k3s etcd cold-import lab artifacts
#
# Validates a lab artifact directory and fails closed when the artifact set is
# missing, malformed, unsafe, or does not prove source/target parity for the
# migration scope.
#
# Usage:
#   scripts/verify_k3s_etcd_cold_import_artifact.sh <artifact-dir>
#   scripts/verify_k3s_etcd_cold_import_artifact.sh --self-test
#
# Exit 0 only when the artifact directory proves a successful safe lab run.
# Exit non-zero with clear diagnostics for missing/malformed/unsafe artifacts.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES_DIR="$SCRIPT_DIR/../fixtures/k3s_etcd_cold_import_artifact"

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
# jq '.field // empty' treats false as absent, so we use has() + conditional
# ----------------------------------------------------------------------

json_field() {
  local file="$1"
  local field="$2"
  jq -r --arg field "$field" 'if has($field) then .[$field] else "__MISSING__" end' "$file"
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

  # 1. check compare-status.json exists
  if [[ ! -f "$artifact_dir/compare-status.json" ]]; then
    err "Missing required file: compare-status.json"
    failures=$((failures + 1))
  elif ! jq empty "$artifact_dir/compare-status.json" 2>/dev/null; then
    err "compare-status.json is not valid JSON"
    failures=$((failures + 1))
  else
    # 3. check migration_prefix == "/registry/"
    local prefix
    prefix="$(jq -r '.migration_prefix // empty' "$artifact_dir/compare-status.json")"
    if [[ -z "$prefix" ]]; then
      err "compare-status.json missing .migration_prefix field"
      failures=$((failures + 1))
    elif [[ "$prefix" != "/registry/" ]]; then
      err ".migration_prefix must be '/registry/', got '$prefix'"
      failures=$((failures + 1))
    fi

    # 4. check keysets_match == true
    local keysets_match
    keysets_match="$(json_field "$artifact_dir/compare-status.json" "keysets_match")"
    if [[ "$keysets_match" == "__MISSING__" ]]; then
      err "compare-status.json missing .keysets_match field"
      failures=$((failures + 1))
    elif [[ "$keysets_match" != "true" ]]; then
      err ".keysets_match must be true, got '$keysets_match'"
      failures=$((failures + 1))
    fi

    # 5. check kv_match == true
    local kv_match
    kv_match="$(json_field "$artifact_dir/compare-status.json" "kv_match")"
    if [[ "$kv_match" == "__MISSING__" ]]; then
      err "compare-status.json missing .kv_match field"
      failures=$((failures + 1))
    elif [[ "$kv_match" != "true" ]]; then
      err ".kv_match must be true, got '$kv_match'"
      failures=$((failures + 1))
    fi
  fi

  # 6. check migration-prefix.txt exists and equals /registry/
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

  # 8-10. check source/target KV hashes exist and match
  if [[ ! -f "$artifact_dir/source-kv-sha256.txt" ]]; then
    err "Missing required file: source-kv-sha256.txt"
    failures=$((failures + 1))
  fi

  if [[ ! -f "$artifact_dir/target-kv-sha256.txt" ]]; then
    err "Missing required file: target-kv-sha256.txt"
    failures=$((failures + 1))
  fi

  if [[ -f "$artifact_dir/source-kv-sha256.txt" ]] && [[ -f "$artifact_dir/target-kv-sha256.txt" ]]; then
    # Parse first field only (handle "hash  filename" format from sha256sum)
    local src_hash tgt_hash
    src_hash="$(cut -d' ' -f1 "$artifact_dir/source-kv-sha256.txt")"
    tgt_hash="$(cut -d' ' -f1 "$artifact_dir/target-kv-sha256.txt")"
    if [[ -z "$src_hash" ]]; then
      err "source-kv-sha256.txt has empty hash"
      failures=$((failures + 1))
    elif [[ -z "$tgt_hash" ]]; then
      err "target-kv-sha256.txt has empty hash"
      failures=$((failures + 1))
    elif ! [[ "$src_hash" =~ ^[0-9a-fA-F]{64}$ ]]; then
      err "source-kv-sha256.txt has invalid hash format (expected 64 hex chars)"
      failures=$((failures + 1))
    elif ! [[ "$tgt_hash" =~ ^[0-9a-fA-F]{64}$ ]]; then
      err "target-kv-sha256.txt has invalid hash format (expected 64 hex chars)"
      failures=$((failures + 1))
    elif [[ "$src_hash" != "$tgt_hash" ]]; then
      err "KV hash mismatch: source=$src_hash, target=$tgt_hash"
      failures=$((failures + 1))
    fi
  fi

  # 11. check k3s-snapshot-status.json exists and is valid JSON
  if [[ ! -f "$artifact_dir/k3s-snapshot-status.json" ]]; then
    err "Missing required file: k3s-snapshot-status.json"
    failures=$((failures + 1))
  elif ! jq empty "$artifact_dir/k3s-snapshot-status.json" 2>/dev/null; then
    err "k3s-snapshot-status.json is not valid JSON"
    failures=$((failures + 1))
  fi

  # 12. check target-endpoint-status-after.json exists and is valid JSON
  if [[ ! -f "$artifact_dir/target-endpoint-status-after.json" ]]; then
    err "Missing required file: target-endpoint-status-after.json"
    failures=$((failures + 1))
  elif ! jq empty "$artifact_dir/target-endpoint-status-after.json" 2>/dev/null; then
    err "target-endpoint-status-after.json is not valid JSON"
    failures=$((failures + 1))
  fi

  # 13. check key-counts.txt exists and contains source/target key counts
  if [[ ! -f "$artifact_dir/key-counts.txt" ]]; then
    err "Missing required file: key-counts.txt"
    failures=$((failures + 1))
  elif ! grep -q 'source.keys' "$artifact_dir/key-counts.txt"; then
    err "key-counts.txt missing source.keys count"
    failures=$((failures + 1))
  elif ! grep -q 'target.keys' "$artifact_dir/key-counts.txt"; then
    err "key-counts.txt missing target.keys count"
    failures=$((failures + 1))
  else
    # Parse and compare numeric counts
    local src_count tgt_count
    src_count="$(grep 'source.keys' "$artifact_dir/key-counts.txt" | awk '{print $1}')"
    tgt_count="$(grep 'target.keys' "$artifact_dir/key-counts.txt" | awk '{print $1}')"
    if ! [[ "$src_count" =~ ^[0-9]+$ ]] || ! [[ "$tgt_count" =~ ^[0-9]+$ ]]; then
      err "key-counts.txt has non-numeric source/target counts"
      failures=$((failures + 1))
    elif [[ "$src_count" -ne "$tgt_count" ]]; then
      err "key-counts.txt source and target counts differ: source=$src_count, target=$tgt_count"
      failures=$((failures + 1))
    fi
  fi

  # 14. check key-diff.txt exists and is empty
  if [[ ! -f "$artifact_dir/key-diff.txt" ]]; then
    err "Missing required file: key-diff.txt"
    failures=$((failures + 1))
  elif [[ -s "$artifact_dir/key-diff.txt" ]]; then
    err "key-diff.txt is not empty (keyset mismatch detected)"
    failures=$((failures + 1))
  fi

  # 15. check source-non-migrated-keys.txt exists
  if [[ ! -f "$artifact_dir/source-non-migrated-keys.txt" ]]; then
    err "Missing required file: source-non-migrated-keys.txt"
    failures=$((failures + 1))
  fi

  # 16. check safe artifact directory does not contain raw snapshots
  # Allowed safe files: k3s-snapshot-status.json, k3s-snapshot.sha256
  local raw_snapshot_files
  raw_snapshot_files=$(find "$artifact_dir" -maxdepth 1 -type f \( -name '*.db' -o -name '*snapshot*' \) 2>/dev/null || true)
  if [[ -n "$raw_snapshot_files" ]]; then
    # Filter out safe files
    local unsafe_files=""
    for f in $raw_snapshot_files; do
      local basename="$(basename "$f")"
      if [[ "$basename" != "k3s-snapshot-status.json" ]] && [[ "$basename" != "k3s-snapshot.sha256" ]]; then
        unsafe_files="$unsafe_files $f"
      fi
    done
    if [[ -n "$unsafe_files" ]]; then
      err "Unsafe raw snapshot files present (not allowed in safe artifacts):$unsafe_files"
      failures=$((failures + 1))
    fi
  fi

  # 17. check safe artifact directory does not contain raw migrator dumps
  local raw_dump_files
  raw_dump_files=$(find "$artifact_dir" -maxdepth 1 -type f \( -name '*dump*' -o -name '*.jsonl' \) 2>/dev/null || true)
  if [[ -n "$raw_dump_files" ]]; then
    err "Unsafe raw dump files present (not allowed in safe artifacts):$raw_dump_files"
    failures=$((failures + 1))
  fi

  # 18. check safe artifact directory does not contain raw KV TSV work files
  local raw_kv_files
  raw_kv_files=$(find "$artifact_dir" -maxdepth 1 -type f \( -name 'source.kv.tsv' -o -name 'target.kv.tsv' -o -name '*.kv.tsv' -o -name '*kv*.tsv' \) 2>/dev/null || true)
  if [[ -n "$raw_kv_files" ]]; then
    err "Unsafe raw KV export files present (not allowed in safe artifacts):$raw_kv_files"
    failures=$((failures + 1))
  fi

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
  echo "=== etcd-migrator Artifact Verifier Self-Test ==="
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