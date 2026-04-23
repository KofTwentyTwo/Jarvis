#!/usr/bin/env bash
#
# test-check-bus-protocol-version.sh — fault-injection smoke test.
#
# Drives scripts/check-bus-protocol-version.sh against a mismatch fixture
# (Swift at v2.0.0, TS at v1.9.0) and asserts the checker exits non-zero
# with an error message mentioning BOTH versions. If a future refactor
# inverts a grep sense or hard-codes a version string, this test catches it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIX_DIR="$SCRIPT_DIR/test-fixtures/bus-mismatch"
CHECKER="$SCRIPT_DIR/check-bus-protocol-version.sh"

[[ -x "$CHECKER" ]] || { echo "FAIL: checker not executable: $CHECKER" >&2; exit 1; }
[[ -d "$FIX_DIR" ]] || { echo "FAIL: fixture dir missing: $FIX_DIR" >&2; exit 1; }

tmp="/tmp/bus-check-test.$$"
trap 'rm -f "$tmp"' EXIT

# Point the checker at the fault-injected fixture files.
if env \
    REPO="$FIX_DIR" \
    SWIFT_FILE="$FIX_DIR/swift/Protocol.swift" \
    TS_FILE="$FIX_DIR/ts/protocol.ts" \
    SWIFT_FIXTURES="$FIX_DIR/swift-fixtures" \
    TS_FIXTURES="$FIX_DIR/ts-fixtures" \
    "$CHECKER" >"$tmp" 2>&1; then
    echo "FAIL: check-bus-protocol-version.sh accepted a mismatch fixture" >&2
    cat "$tmp" >&2
    exit 1
fi

# Error message must mention BOTH versions so the developer knows where to look.
if ! grep -q "2.0.0" "$tmp"; then
    echo "FAIL: error message missing expected Swift version (2.0.0)" >&2
    cat "$tmp" >&2
    exit 1
fi
if ! grep -q "1.9.0" "$tmp"; then
    echo "FAIL: error message missing expected TS version (1.9.0)" >&2
    cat "$tmp" >&2
    exit 1
fi

echo "check-bus-protocol-version.sh correctly rejected mismatch fixture"
