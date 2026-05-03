#!/usr/bin/env bash
# test-copy-voice-models.sh — shell-level tests for copy-voice-models.sh.
# Closes the bug class from the 2026-05-03 voice audit: the runtime
# expects ONNX files at `Contents/Resources/Models/{openWakeWord,silero}/`
# but the build had no copy phase, AND nothing gated on MANIFEST.json
# placeholders.
#
# Usage: scripts/test-copy-voice-models.sh
#
# Exits 0 on all-green. Each test sets up a fixture under /tmp/cvm-test-XXX,
# invokes copy-voice-models.sh with overridden SRCROOT/TARGET_BUILD_DIR,
# and asserts the expected outcome.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/copy-voice-models.sh"
PASS=0
FAIL=0

ok()   { PASS=$((PASS+1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

mktemp_dir() { mktemp -d -t cvm-test.XXXXXXXX; }

# Build a minimal fixture replicating Resources/models layout.
#   $1 = fixture root
#   $2 = openwakeword manifest content (or "real" for the canonical real one)
#   $3 = silero manifest content (or "real")
seed_fixture() {
    local fixture="$1"
    local owm="$2"
    local sm="$3"
    mkdir -p "$fixture/Resources/models/openwakeword"
    mkdir -p "$fixture/Resources/models/silero"
    if [ "$owm" = "real" ]; then
        cp "${REPO_ROOT}/Resources/models/openwakeword/MANIFEST.json" \
           "$fixture/Resources/models/openwakeword/MANIFEST.json"
    else
        printf '%s' "$owm" > "$fixture/Resources/models/openwakeword/MANIFEST.json"
    fi
    if [ "$sm" = "real" ]; then
        cp "${REPO_ROOT}/Resources/models/silero/MANIFEST.json" \
           "$fixture/Resources/models/silero/MANIFEST.json"
    else
        printf '%s' "$sm" > "$fixture/Resources/models/silero/MANIFEST.json"
    fi
    # Minimal ONNX placeholder files (content unimportant for these tests).
    : > "$fixture/Resources/models/openwakeword/dummy.onnx"
    : > "$fixture/Resources/models/silero/dummy.onnx"
}

run_script() {
    local fixture="$1"
    local target_dir="$2"
    SRCROOT="$fixture" TARGET_BUILD_DIR="$target_dir" WRAPPER_NAME=Test.app \
        bash "$SCRIPT"
}

echo "Test 1: real MANIFESTs → script succeeds + bundle layout correct"
T1=$(mktemp_dir); BD1=$(mktemp_dir)
seed_fixture "$T1" "real" "real"
if run_script "$T1" "$BD1" >/dev/null 2>&1; then
    if [ -d "$BD1/Test.app/Contents/Resources/Models/openWakeWord" ] \
       && [ -d "$BD1/Test.app/Contents/Resources/Models/silero" ]; then
        ok "real-real → bundle path layout correct (capital M, openWakeWord)"
    else
        fail "real-real script ran but bundle layout missing"
    fi
else
    fail "real-real script exited non-zero unexpectedly"
fi

echo "Test 2: silero PLACEHOLDER_ → script fails with helpful message"
T2=$(mktemp_dir); BD2=$(mktemp_dir)
seed_fixture "$T2" "real" '{"models":{"silero_vad.onnx":{"sha256":"PLACEHOLDER_run_fetch"}}}'
if run_script "$T2" "$BD2" >/tmp/cvm-t2.log 2>&1; then
    fail "PLACEHOLDER manifest should hard-fail; instead exit=0"
else
    if grep -q "PLACEHOLDER" /tmp/cvm-t2.log; then
        ok "silero PLACEHOLDER → exit non-zero with PLACEHOLDER hint"
    else
        fail "non-zero exit but no PLACEHOLDER mention in stderr"
    fi
fi

echo "Test 3: openwakeword PLACEHOLDER_ → script fails"
T3=$(mktemp_dir); BD3=$(mktemp_dir)
seed_fixture "$T3" '{"models":[{"sha256":"PLACEHOLDER_x"}]}' "real"
if run_script "$T3" "$BD3" >/dev/null 2>&1; then
    fail "openwakeword PLACEHOLDER should hard-fail"
else
    ok "openwakeword PLACEHOLDER → exit non-zero"
fi

echo "Test 4: missing MANIFEST.json → script fails"
T4=$(mktemp_dir); BD4=$(mktemp_dir)
mkdir -p "$T4/Resources/models/openwakeword"
mkdir -p "$T4/Resources/models/silero"
# Note: no MANIFEST.json files
if run_script "$T4" "$BD4" >/dev/null 2>&1; then
    fail "missing MANIFEST should hard-fail"
else
    ok "missing MANIFEST → exit non-zero"
fi

echo "Test 5: missing source dir entirely → script soft-degrades (warn, exit 0)"
T5=$(mktemp_dir); BD5=$(mktemp_dir)
# T5 has no Resources/models at all
if run_script "$T5" "$BD5" >/tmp/cvm-t5.log 2>&1; then
    if grep -q "warning:" /tmp/cvm-t5.log; then
        ok "missing source dir → soft-degrades with warning"
    else
        fail "exit 0 but no warning emitted"
    fi
else
    fail "missing source dir should exit 0 (CI / lite workflows)"
fi

echo "Test 6: real run with capital-M expectation matches AppDelegate"
# AppDelegate.swift:653 builds the lookup path:
#   bundleURL.appendingPathComponent("Contents/Resources/Models", ...)
#   .appendingPathComponent("openWakeWord", ...)
# Verify the test 1 bundle layout matches that string literally.
EXPECTED="$BD1/Test.app/Contents/Resources/Models/openWakeWord/MANIFEST.json"
if [ -f "$EXPECTED" ]; then
    ok "bundle path 'Contents/Resources/Models/openWakeWord/' matches AppDelegate expectation"
else
    fail "expected file at $EXPECTED not found"
fi

# Cleanup.
rm -rf "$T1" "$BD1" "$T2" "$BD2" "$T3" "$BD3" "$T4" "$BD4" "$T5" "$BD5" /tmp/cvm-t2.log /tmp/cvm-t5.log

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
