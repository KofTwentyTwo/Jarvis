#!/usr/bin/env bash
#
# check-bus-protocol-version.sh — Xcode pre-build phase.
#
# Asserts the Swift and TS BUS_PROTOCOL_VERSION constants match, and that
# the Swift fixture directory (`packages/Bus/Tests/BusTests/Fixtures/`) is
# byte-identical to the TS fixture directory (`webview/packages/bus/fixtures/`).
#
# Load-bearing for SEC-09 — the build is the final drift catcher for
# Swift/TS wire-format parity.
#
# Usage:
#   scripts/check-bus-protocol-version.sh                           # production
#   SWIFT_FILE=... TS_FILE=... SWIFT_FIXTURES=... TS_FIXTURES=... \
#     scripts/check-bus-protocol-version.sh                         # test-harness mode
#
# Every env var is optional and falls back to the real repo layout. Setting
# them lets the smoke-test harness point the checker at a fault-injected
# fixture directory without touching the real tree.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${REPO:=$(cd "$SCRIPT_DIR/.." && pwd)}"

: "${SWIFT_FILE:=$REPO/packages/Bus/Sources/Bus/Protocol.swift}"
: "${TS_FILE:=$REPO/webview/packages/bus/src/protocol.ts}"
: "${SWIFT_FIXTURES:=$REPO/packages/Bus/Tests/BusTests/Fixtures}"
: "${TS_FIXTURES:=$REPO/webview/packages/bus/fixtures}"

err() {
    echo "FAIL: $*" >&2
    exit 1
}

[[ -f "$SWIFT_FILE" ]] || err "Swift protocol file not found: $SWIFT_FILE"
[[ -f "$TS_FILE" ]] || err "TS protocol file not found: $TS_FILE"

# Extract Swift constant:
#   public let BUS_PROTOCOL_VERSION: String = "x.y.z"
SWIFT_VER=$(grep -E '^[[:space:]]*public[[:space:]]+let[[:space:]]+BUS_PROTOCOL_VERSION[[:space:]]*:[[:space:]]*String[[:space:]]*=' "$SWIFT_FILE" \
    | sed -E 's/.*"([^"]+)".*/\1/' \
    | head -n 1)
[[ -n "$SWIFT_VER" ]] || err "BUS_PROTOCOL_VERSION not found or malformed in $SWIFT_FILE"

# Extract TS constant:
#   export const BUS_PROTOCOL_VERSION = "x.y.z"
TS_VER=$(grep -E '^export[[:space:]]+const[[:space:]]+BUS_PROTOCOL_VERSION[[:space:]]*=' "$TS_FILE" \
    | sed -E 's/.*"([^"]+)".*/\1/' \
    | head -n 1)
[[ -n "$TS_VER" ]] || err "BUS_PROTOCOL_VERSION not found or malformed in $TS_FILE"

if [[ "$SWIFT_VER" != "$TS_VER" ]]; then
    {
        echo "FAIL: BUS_PROTOCOL_VERSION mismatch"
        echo "  Swift ($SWIFT_FILE): $SWIFT_VER"
        echo "  TS    ($TS_FILE):    $TS_VER"
        echo "  Bump both to the same value before building. This is SEC-09's build-breaker."
    } >&2
    exit 1
fi

# Assert fixture directories are byte-identical.
if [[ -d "$SWIFT_FIXTURES" && -d "$TS_FIXTURES" ]]; then
    DIFF_OUT="/tmp/bus-fixture-diff.$$"
    if ! /usr/bin/diff -r "$SWIFT_FIXTURES" "$TS_FIXTURES" >"$DIFF_OUT" 2>&1; then
        {
            echo "FAIL: fixture directories differ"
            echo "  Swift: $SWIFT_FIXTURES"
            echo "  TS:    $TS_FIXTURES"
            echo ""
            cat "$DIFF_OUT"
        } >&2
        rm -f "$DIFF_OUT"
        exit 1
    fi
    rm -f "$DIFF_OUT"
else
    # In production mode both directories must exist.
    # In test-harness mode (env vars set), either side may be absent.
    if [[ "$REPO" == "$(cd "$SCRIPT_DIR/.." && pwd)" ]]; then
        [[ -d "$SWIFT_FIXTURES" ]] || err "fixtures missing: $SWIFT_FIXTURES"
        [[ -d "$TS_FIXTURES" ]] || err "fixtures missing: $TS_FIXTURES"
    fi
fi

# Note: full Vitest + XCTest round-trip runs via `swift test` / `pnpm test`,
# not on every build. The grep + `diff -r` covers the wire-shape risk here.
echo "bus parity OK at v$SWIFT_VER"
