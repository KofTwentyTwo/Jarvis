#!/bin/bash
# test-verify-entitlements.sh — fault-injection self-test harness for verify-entitlements.sh.
#
# Feeds three fixture plists (good / broken / forbidden) to the --verify-fixture mode
# and asserts the exit codes match expectations. This is the mechanical defense against
# a silently-broken verify-entitlements.sh: if someone inverts a grep sense or drops
# a required key from the MAIN_REQUIRED list, one of these cases catches it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES_DIR="$SCRIPT_DIR/test-fixtures"
VERIFIER="$SCRIPT_DIR/verify-entitlements.sh"

PASS=0
FAIL=0

run_case() {
  local name="$1"
  local fixture="$2"
  local expect_code="$3"
  local actual=0
  "$VERIFIER" --verify-fixture "$fixture" >/dev/null 2>&1 || actual=$?
  if [ "$actual" -eq "$expect_code" ]; then
    echo "  PASS: $name (exit=$actual as expected)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $name (expected exit=$expect_code, got exit=$actual)" >&2
    FAIL=$((FAIL + 1))
  fi
}

# Plan 05-03: harness for the per-helper rule branches. Drives
# `--verify-helper-fixture` so the fault-injection corpus exercises every arm
# of `check_helper_entitlements_xml` without needing a real signed bundle.
run_helper_case() {
  local name="$1"
  local fixture="$2"
  local helper_name="$3"
  local expect_code="$4"
  local actual=0
  "$VERIFIER" --verify-helper-fixture "$fixture" "$helper_name" >/dev/null 2>&1 || actual=$?
  if [ "$actual" -eq "$expect_code" ]; then
    echo "  PASS: $name (exit=$actual as expected)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $name (expected exit=$expect_code, got exit=$actual)" >&2
    FAIL=$((FAIL + 1))
  fi
}

echo "test-verify-entitlements.sh — fault-injection self-test"
echo

# Main-app fixtures (P1-05).
# Case 1: good fixture → exit 0
run_case "good-entitlements → exit 0" "$FIXTURES_DIR/good-entitlements.plist" 0

# Case 2: broken fixture (missing allow-jit) → exit non-zero
run_case "broken-entitlements → exit !0" "$FIXTURES_DIR/broken-entitlements.plist" 1

# Case 3: forbidden fixture (carries automation.apple-events) → exit non-zero
run_case "forbidden-entitlements → exit !0" "$FIXTURES_DIR/forbidden-entitlements.plist" 1

# Plan 05-03 helper fixtures.
# Case 4: applescript helper carrying apple-events as required → exit 0
run_helper_case "helper-applescript-good (mcp-applescript) → exit 0" \
  "$FIXTURES_DIR/helper-applescript-good.entitlements" \
  "mcp-applescript" 0

# Case 5: applescript helper MISSING apple-events → exit !0 (T-05-03-02)
run_helper_case "helper-applescript-missing (mcp-applescript) → exit !0" \
  "$FIXTURES_DIR/helper-applescript-missing.entitlements" \
  "mcp-applescript" 1

# Case 6: cross-helper drift — mcp-time carrying apple-events → exit !0 (T-05-03-01)
run_helper_case "helper-time-with-apple-events (mcp-time) → exit !0" \
  "$FIXTURES_DIR/helper-time-with-apple-events.entitlements" \
  "mcp-time" 1

echo
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
