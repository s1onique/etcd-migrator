#!/usr/bin/env bash
# verify_k3s_etcd_cold_import_replay_artifact.sh — Deterministic verifier for k3s etcd cold-import replay lab artifacts
#
# Validates a replay lab artifact directory and fails closed when the artifact set is
# missing, malformed, unsafe, or does not prove the replay/idempotence contract.
#
# Accepted contracts:
#   - idempotent_success: second load succeeds, target unchanged
#   - safe_fail_no_mutation: second load fails nonzero, target unchanged
#
# Usage:
#   scripts/verify_k3s_etcd_cold_import_replay_artifact.sh <artifact-dir>
#   scripts/verify_k3s_etcd_cold_import_replay_artifact.sh --self-test
#
# Exit 0 only when the artifact directory proves a successful safe replay run.
# Exit non-zero with clear diagnostics for missing/malformed/unsafe artifacts.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES_DIR="$SCRIPT_DIR/../fixtures/k3s_etcd_cold_import_replay_artifact"

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

  # 1. check replay-status.json exists
  if [[ ! -f "$artifact_dir/replay-status.json" ]]; then
    err "Missing required file: replay-status.json"
    failures=$((failures + 1))
  elif ! jq empty "$artifact_dir/replay-status.json" 2>/dev/null; then
    err "replay-status.json is not valid JSON"
    failures=$((failures + 1))
  else
    # 2. check migration_prefix == "/registry/"
    local prefix
    prefix="$(jq -r '.migration_prefix // empty' "$artifact_dir/replay-status.json")"
    if [[ -z "$prefix" ]]; then
      err "replay-status.json missing .migration_prefix field"
      failures=$((failures + 1))
    elif [[ "$prefix" != "/registry/" ]]; then
      err ".migration_prefix must be '/registry/', got '$prefix'"
      failures=$((failures + 1))
    fi

    # 3. check conflict_policy field exists
    local conflict_policy
    conflict_policy="$(jq -r '.conflict_policy // empty' "$artifact_dir/replay-status.json")"
    if [[ -z "$conflict_policy" ]]; then
      err "replay-status.json missing .conflict_policy field"
      failures=$((failures + 1))
    elif [[ "$conflict_policy" != "fail-if-present" ]] && [[ "$conflict_policy" != "allow-identical-replay" ]]; then
      err ".conflict_policy must be 'fail-if-present' or 'allow-identical-replay', got '$conflict_policy'"
      failures=$((failures + 1))
    fi

    # 4. check conflict-policy.txt exists and matches
    if [[ ! -f "$artifact_dir/conflict-policy.txt" ]]; then
      err "Missing required file: conflict-policy.txt"
      failures=$((failures + 1))
    else
      local conflict_policy_file
      conflict_policy_file="$(cat "$artifact_dir/conflict-policy.txt")"
      if [[ "$conflict_policy_file" != "$conflict_policy" ]]; then
        err "conflict-policy.txt ('$conflict_policy_file') does not match .conflict_policy ('$conflict_policy')"
        failures=$((failures + 1))
      fi
    fi

    # 5. check first_load_exit_code == 0
    local first_exit
    first_exit="$(jq -r '.first_load_exit_code // empty' "$artifact_dir/replay-status.json")"
    if [[ -z "$first_exit" ]]; then
      err "replay-status.json missing .first_load_exit_code field"
      failures=$((failures + 1))
    elif [[ "$first_exit" != "0" ]]; then
      err ".first_load_exit_code must be 0, got '$first_exit'"
      failures=$((failures + 1))
    fi

    # 6. check first_load_keysets_match == true
    local first_keysets
    first_keysets="$(json_field "$artifact_dir/replay-status.json" "first_load_keysets_match")"
    if [[ "$first_keysets" == "__MISSING__" ]]; then
      err "replay-status.json missing .first_load_keysets_match field"
      failures=$((failures + 1))
    elif [[ "$first_keysets" != "true" ]]; then
      err ".first_load_keysets_match must be true, got '$first_keysets'"
      failures=$((failures + 1))
    fi

    # 7. check first_load_kv_match == true
    local first_kv
    first_kv="$(json_field "$artifact_dir/replay-status.json" "first_load_kv_match")"
    if [[ "$first_kv" == "__MISSING__" ]]; then
      err "replay-status.json missing .first_load_kv_match field"
      failures=$((failures + 1))
    elif [[ "$first_kv" != "true" ]]; then
      err ".first_load_kv_match must be true, got '$first_kv'"
      failures=$((failures + 1))
    fi

    # 8. check second_load_keysets_match == true
    local second_keysets
    second_keysets="$(json_field "$artifact_dir/replay-status.json" "second_load_keysets_match")"
    if [[ "$second_keysets" == "__MISSING__" ]]; then
      err "replay-status.json missing .second_load_keysets_match field"
      failures=$((failures + 1))
    elif [[ "$second_keysets" != "true" ]]; then
      err ".second_load_keysets_match must be true, got '$second_keysets'"
      failures=$((failures + 1))
    fi

    # 9. check second_load_kv_match == true
    local second_kv
    second_kv="$(json_field "$artifact_dir/replay-status.json" "second_load_kv_match")"
    if [[ "$second_kv" == "__MISSING__" ]]; then
      err "replay-status.json missing .second_load_kv_match field"
      failures=$((failures + 1))
    elif [[ "$second_kv" != "true" ]]; then
      err ".second_load_kv_match must be true, got '$second_kv'"
      failures=$((failures + 1))
    fi

    # 10. check target_hash_unchanged_after_second_load == true
    local target_unchanged
    target_unchanged="$(json_field "$artifact_dir/replay-status.json" "target_hash_unchanged_after_second_load")"
    if [[ "$target_unchanged" == "__MISSING__" ]]; then
      err "replay-status.json missing .target_hash_unchanged_after_second_load field"
      failures=$((failures + 1))
    elif [[ "$target_unchanged" != "true" ]]; then
      err ".target_hash_unchanged_after_second_load must be true, got '$target_unchanged'"
      failures=$((failures + 1))
    fi

    # 11. check contract_satisfied == true
    local contract_satisfied
    contract_satisfied="$(json_field "$artifact_dir/replay-status.json" "contract_satisfied")"
    if [[ "$contract_satisfied" == "__MISSING__" ]]; then
      err "replay-status.json missing .contract_satisfied field"
      failures=$((failures + 1))
    elif [[ "$contract_satisfied" != "true" ]]; then
      err ".contract_satisfied must be true, got '$contract_satisfied'"
      failures=$((failures + 1))
    fi

    # 12. check replay_outcome is one of valid outcomes
    local replay_outcome
    replay_outcome="$(jq -r '.replay_outcome // empty' "$artifact_dir/replay-status.json")"
    if [[ -z "$replay_outcome" ]]; then
      err "replay-status.json missing .replay_outcome field"
      failures=$((failures + 1))
    elif [[ "$replay_outcome" != "idempotent_success" ]] && [[ "$replay_outcome" != "safe_fail_no_mutation" ]]; then
      err ".replay_outcome must be 'idempotent_success' or 'safe_fail_no_mutation', got '$replay_outcome'"
      failures=$((failures + 1))
    fi

    # 13. check second_load_exit_code field exists
    local second_exit
    second_exit="$(jq -r '.second_load_exit_code // empty' "$artifact_dir/replay-status.json")"
    if [[ -z "$second_exit" ]]; then
      err "replay-status.json missing .second_load_exit_code field"
      failures=$((failures + 1))
    fi

    # 14. check conflict_policy-specific outcome consistency
    if [[ "$conflict_policy" == "fail-if-present" ]]; then
      # With fail-if-present, second load must fail nonzero
      if [[ -n "$second_exit" ]] && [[ "$second_exit" == "0" ]]; then
        err "For conflict-policy=fail-if-present, .second_load_exit_code must be nonzero, got '$second_exit'"
        failures=$((failures + 1))
      fi
      # replay_outcome should be safe_fail_no_mutation
      if [[ "$replay_outcome" != "safe_fail_no_mutation" ]]; then
        err "For conflict-policy=fail-if-present, .replay_outcome must be 'safe_fail_no_mutation', got '$replay_outcome'"
        failures=$((failures + 1))
      fi
    elif [[ "$conflict_policy" == "allow-identical-replay" ]]; then
      # With allow-identical-replay, second load must succeed
      if [[ -n "$second_exit" ]] && [[ "$second_exit" != "0" ]]; then
        err "For conflict-policy=allow-identical-replay, .second_load_exit_code must be 0, got '$second_exit'"
        failures=$((failures + 1))
      fi
      # replay_outcome should be idempotent_success
      if [[ "$replay_outcome" != "idempotent_success" ]]; then
        err "For conflict-policy=allow-identical-replay, .replay_outcome must be 'idempotent_success', got '$replay_outcome'"
        failures=$((failures + 1))
      fi
    fi
  fi

  # 15. check migration-prefix.txt exists and equals /registry/
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

  # 16. check compare JSON files exist and are valid
  for compare_file in "compare-after-first-load.json" "compare-after-second-load.json"; do
    if [[ ! -f "$artifact_dir/$compare_file" ]]; then
      err "Missing required file: $compare_file"
      failures=$((failures + 1))
    elif ! jq empty "$artifact_dir/$compare_file" 2>/dev/null; then
      err "$compare_file is not valid JSON"
      failures=$((failures + 1))
    fi
  done

  # 17. check endpoint status JSON files exist and are valid
  for status_file in "target-endpoint-status-after-first-load.json" "target-endpoint-status-after-second-load.json"; do
    if [[ ! -f "$artifact_dir/$status_file" ]]; then
      err "Missing required file: $status_file"
      failures=$((failures + 1))
    elif ! jq empty "$artifact_dir/$status_file" 2>/dev/null; then
      err "$status_file is not valid JSON"
      failures=$((failures + 1))
    fi
  done

  # 18. check hash files exist and contain valid 64-char hex
  local src_first_hash tgt_first_hash src_second_hash tgt_second_hash
  src_first_hash="$(cut -d' ' -f1 "$artifact_dir/source-kv-after-first-load-sha256.txt" 2>/dev/null || echo "")"
  tgt_first_hash="$(cut -d' ' -f1 "$artifact_dir/target-kv-after-first-load-sha256.txt" 2>/dev/null || echo "")"
  src_second_hash="$(cut -d' ' -f1 "$artifact_dir/source-kv-after-second-load-sha256.txt" 2>/dev/null || echo "")"
  tgt_second_hash="$(cut -d' ' -f1 "$artifact_dir/target-kv-after-second-load-sha256.txt" 2>/dev/null || echo "")"

  local hash_files=(
    "source-kv-after-first-load-sha256.txt"
    "target-kv-after-first-load-sha256.txt"
    "source-kv-after-second-load-sha256.txt"
    "target-kv-after-second-load-sha256.txt"
  )

  for hash_file in "${hash_files[@]}"; do
    if [[ ! -f "$artifact_dir/$hash_file" ]]; then
      err "Missing required file: $hash_file"
      failures=$((failures + 1))
    elif ! [[ "$(cut -d' ' -f1 "$artifact_dir/$hash_file")" =~ ^[0-9a-fA-F]{64}$ ]]; then
      err "$hash_file has invalid hash format (expected 64 hex chars)"
      failures=$((failures + 1))
    fi
  done

  # Check hash invariants
  if [[ -n "$src_first_hash" ]] && [[ -n "$tgt_first_hash" ]] && [[ "$src_first_hash" != "$tgt_first_hash" ]]; then
    err "Source and target KV hashes after first load do not match"
    failures=$((failures + 1))
  fi

  if [[ -n "$src_second_hash" ]] && [[ -n "$tgt_second_hash" ]] && [[ "$src_second_hash" != "$tgt_second_hash" ]]; then
    err "Source and target KV hashes after second load do not match"
    failures=$((failures + 1))
  fi

  if [[ -n "$tgt_first_hash" ]] && [[ -n "$tgt_second_hash" ]] && [[ "$tgt_first_hash" != "$tgt_second_hash" ]]; then
    err "Target KV hash changed after second load (target_unchanged should be true)"
    failures=$((failures + 1))
  fi

  # 19. check key-count files exist and contain numeric counts
  for counts_file in "key-counts-after-first-load.txt" "key-counts-after-second-load.txt"; do
    if [[ ! -f "$artifact_dir/$counts_file" ]]; then
      err "Missing required file: $counts_file"
      failures=$((failures + 1))
    elif ! grep -q 'source' "$artifact_dir/$counts_file"; then
      err "$counts_file missing source count"
      failures=$((failures + 1))
    elif ! grep -q 'target' "$artifact_dir/$counts_file"; then
      err "$counts_file missing target count"
      failures=$((failures + 1))
    else
      local src_count tgt_count
      src_count="$(grep 'source' "$artifact_dir/$counts_file" | awk '{print $1}')"
      tgt_count="$(grep 'target' "$artifact_dir/$counts_file" | awk '{print $1}')"
      if ! [[ "$src_count" =~ ^[0-9]+$ ]] || ! [[ "$tgt_count" =~ ^[0-9]+$ ]]; then
        err "$counts_file has non-numeric counts"
        failures=$((failures + 1))
      fi
    fi
  done

  # 20. check key-diff files exist and are empty
  for diff_file in "key-diff-after-first-load.txt" "key-diff-after-second-load.txt"; do
    if [[ ! -f "$artifact_dir/$diff_file" ]]; then
      err "Missing required file: $diff_file"
      failures=$((failures + 1))
    elif [[ -s "$artifact_dir/$diff_file" ]]; then
      err "$diff_file is not empty (keyset mismatch detected)"
      failures=$((failures + 1))
    fi
  done

  # 21. check second-load-exit-code.txt exists and matches replay-status.json
  if [[ ! -f "$artifact_dir/second-load-exit-code.txt" ]]; then
    err "Missing required file: second-load-exit-code.txt"
    failures=$((failures + 1))
  else
    local second_exit_file
    second_exit_file="$(cat "$artifact_dir/second-load-exit-code.txt")"
    local second_exit_json
    second_exit_json="$(jq -r '.second_load_exit_code // empty' "$artifact_dir/replay-status.json" 2>/dev/null || echo "")"
    if [[ -n "$second_exit_json" ]] && [[ "$second_exit_file" != "$second_exit_json" ]]; then
      err "second-load-exit-code.txt ($second_exit_file) does not match replay-status.json ($second_exit_json)"
      failures=$((failures + 1))
    fi
  fi

  # 22. check second-load stdout/stderr exist
  if [[ ! -f "$artifact_dir/second-load-stdout.txt" ]]; then
    err "Missing required file: second-load-stdout.txt"
    failures=$((failures + 1))
  fi

  if [[ ! -f "$artifact_dir/second-load-stderr.txt" ]]; then
    err "Missing required file: second-load-stderr.txt"
    failures=$((failures + 1))
  fi

  # 23. check safe artifact directory does not contain raw snapshots
  # Allowed safe files: k3s-snapshot-status.json, k3s-snapshot.sha256
  local raw_snapshot_files
  raw_snapshot_files=$(find "$artifact_dir" -maxdepth 1 -type f \( -name '*.db' -o -name '*snapshot*' \) 2>/dev/null || true)
  if [[ -n "$raw_snapshot_files" ]]; then
    local unsafe_files=""
    for f in $raw_snapshot_files; do
      local basename
      basename="$(basename "$f")"
      if [[ "$basename" != "k3s-snapshot-status.json" ]] && [[ "$basename" != "k3s-snapshot.sha256" ]]; then
        unsafe_files="$unsafe_files $f"
      fi
    done
    if [[ -n "$unsafe_files" ]]; then
      err "Unsafe raw snapshot files present (not allowed in safe artifacts):$unsafe_files"
      failures=$((failures + 1))
    fi
  fi

  # 24. check safe artifact directory does not contain raw migrator dumps
  local raw_dump_files
  raw_dump_files=$(find "$artifact_dir" -maxdepth 1 -type f \( -name '*dump*' -o -name '*.jsonl' \) 2>/dev/null || true)
  if [[ -n "$raw_dump_files" ]]; then
    err "Unsafe raw dump files present (not allowed in safe artifacts):$raw_dump_files"
    failures=$((failures + 1))
  fi

  # 25. check safe artifact directory does not contain raw KV TSV work files
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
  echo "=== etcd-migrator Replay Artifact Verifier Self-Test ==="
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
    case "$fixture_name" in
      good-idempotent|good-safe-fail)
        expected_exit=0
        ;;
      bad-*)
        expected_exit=1
        ;;
      *)
        # Unknown fixture type, expect failure
        expected_exit=1
        ;;
    esac

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
