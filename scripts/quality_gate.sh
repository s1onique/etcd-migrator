#!/usr/bin/env bash
#
# quality_gate.sh - etcd-migrator quality gate
#
# Runs the full quality gate: fmt check, vet, and tests.
# Exit non-zero if any check fails.

set -euo pipefail

echo "=== etcd-migrator Quality Gate ==="
echo

# 1. Format check
echo "[1/3] Checking formatting..."
unformatted="$(gofmt -l .)"
if [[ -n "$unformatted" ]]; then
  echo "ERROR: gofmt required on:" >&2
  echo "$unformatted" >&2
  exit 1
fi
echo "  ✓ Formatting check passed"
echo

# 2. Vet
echo "[2/3] Running go vet..."
if ! go vet ./...; then
  echo "ERROR: go vet found issues" >&2
  exit 1
fi
echo "  ✓ go vet passed"
echo

# 3. Tests
echo "[3/3] Running tests..."
if ! go test ./...; then
  echo "ERROR: tests failed" >&2
  exit 1
fi
echo "  ✓ Tests passed"
echo

echo "=== Quality Gate Passed ==="
