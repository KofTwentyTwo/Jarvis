#!/usr/bin/env bash
#
# test-check-no-evaluate-javascript.sh — fault-injection smoke test.
#
# Drives scripts/check-no-evaluate-javascript.sh against a fixture directory
# containing a deliberately-bad bad.swift (uses evaluateJavaScript) and a
# control good.swift (uses callAsyncJavaScript). Asserts:
#   * the checker exits non-zero
#   * the failure names bad.swift
#   * good.swift is NOT flagged
#
# Hazard: the production checker skips any path matching `*/test-fixtures/*`,
# so running it with REPO pointing at scripts/test-fixtures would no-op the
# test (the bad.swift is inside a test-fixtures path component). Workaround:
# copy the fixture dir to a temp location whose path does not contain the
# string `test-fixtures`, then invoke the checker against that.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKER="$SCRIPT_DIR/check-no-evaluate-javascript.sh"
FIX_DIR="$SCRIPT_DIR/test-fixtures/bus-evaluate-js"

[[ -x "$CHECKER" ]] || { echo "FAIL: checker not executable: $CHECKER" >&2; exit 1; }
[[ -d "$FIX_DIR" ]] || { echo "FAIL: fixture dir missing: $FIX_DIR" >&2; exit 1; }

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
cp -R "$FIX_DIR" "$workdir/bus-evaluate-js"

tmp="$workdir/out.log"
if env REPO="$workdir" SEARCH_ROOTS="bus-evaluate-js" \
    "$CHECKER" >"$tmp" 2>&1; then
    echo "FAIL: check-no-evaluate-javascript.sh accepted a bad fixture" >&2
    cat "$tmp" >&2
    exit 1
fi

if ! grep -q "bad.swift" "$tmp"; then
    echo "FAIL: error should mention bad.swift" >&2
    cat "$tmp" >&2
    exit 1
fi

if grep -q "good.swift" "$tmp"; then
    echo "FAIL: good.swift was falsely flagged" >&2
    cat "$tmp" >&2
    exit 1
fi

echo "check-no-evaluate-javascript.sh correctly rejected bad fixture"
