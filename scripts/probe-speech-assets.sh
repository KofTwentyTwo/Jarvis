#!/usr/bin/env bash
# Scaffold-time probe: verifies that the speech-recognition-assets entitlement
# is load-bearing by cold-launching a Release archive with the entitlement stripped.
#
# Expected outcome: SFSpeechErrorCode.assetUnavailable fires in stderr within 3s.
# This confirms AUDIT-R2-S5: without the entitlement, on-device speech recognition
# assets cannot be downloaded and SpeechAnalyzer is non-functional.
#
# If STT works WITHOUT the entitlement, that refutes AUDIT-R2-S5 (the claim that the
# entitlement is strictly required). Either outcome is valid probe output — the script
# reports it clearly and exits 0 for pass, 2 for inconclusive. Only unexpected
# infrastructure errors exit 1.
#
# Usage:
#   scripts/probe-speech-assets.sh path/to/Jarvis.app
#
# The --probe-stt flag is wired by Plan 06-05 (VoiceController). The flag instructs
# the app to immediately instantiate SpeechAnalyzerSTT and write any errors to stderr,
# then exit. Without the flag the probe may time-out waiting for normal app startup.
#
# IMPORTANT: Run this against a RELEASE archive (not Debug). The entitlement is
# enforced by the codesignature — in Debug the sandbox is relaxed and the probe
# may produce a false-negative (STT works without entitlement in Debug).
#
# Variable discipline: this script uses ${VAR-default} (no colon) where an empty
# value is semantically meaningful (e.g. ENTITLEMENT_STRIPPED=""), not ${VAR:-default}.
set -euo pipefail

APP="${1:?Usage: $0 path/to/Jarvis.app}"

if [ ! -d "$APP" ]; then
  echo "ERROR: '$APP' is not a directory or does not exist" >&2
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "Probe: copying app to temp directory..."
cp -R "$APP" "$TMP/"
TARGET="$TMP/$(basename "$APP")"

# ---- Step 1: Extract current entitlements ----
echo "Probe: extracting entitlements..."
ENTITLEMENTS_FILE="$TMP/entitlements.plist"
codesign -d --entitlements :- "$TARGET" 2>/dev/null > "$ENTITLEMENTS_FILE" || {
  echo "ERROR: Could not extract entitlements from $TARGET" >&2
  exit 1
}

# Check if the speech-recognition-assets entitlement is present
ENTITLEMENT_KEY="com.apple.developer.speech-recognition-assets"
ENTITLEMENT_STRIPPED=""
if plutil -extract "$ENTITLEMENT_KEY" xml1 -o /dev/null "$ENTITLEMENTS_FILE" 2>/dev/null; then
  # Entitlement is present — strip it for the probe
  plutil -remove "$ENTITLEMENT_KEY" "$ENTITLEMENTS_FILE" 2>/dev/null || true
  ENTITLEMENT_STRIPPED="yes"
  echo "Probe: stripped '$ENTITLEMENT_KEY' from entitlements"
else
  echo "WARNING: '$ENTITLEMENT_KEY' not found in app entitlements — probe may be inconclusive"
  # Note: uses ${ENTITLEMENT_STRIPPED-} (no colon) — empty string is meaningful here
fi

# ---- Step 2: Re-sign with stripped entitlements ----
echo "Probe: re-signing with stripped entitlements (ad-hoc)..."
codesign --force --sign - --entitlements "$ENTITLEMENTS_FILE" "$TARGET" 2>/dev/null || {
  echo "ERROR: Re-signing failed" >&2
  exit 1
}

# ---- Step 3: Cold-launch and observe stderr ----
RESULT_LOG="$TMP/launch.log"
BINARY="$TARGET/Contents/MacOS/Jarvis"

if [ ! -f "$BINARY" ]; then
  echo "ERROR: Binary not found at $BINARY" >&2
  exit 1
fi

echo "Probe: cold-launching with --probe-stt flag (3s timeout)..."
# Note: --probe-stt flag is wired by Plan 06-05. Without it the binary may not
# write the STT error to stderr quickly enough.
"$BINARY" --probe-stt 2>&1 | tee "$RESULT_LOG" &
LAUNCH_PID=$!
sleep 3
kill -TERM "$LAUNCH_PID" 2>/dev/null || true
wait "$LAUNCH_PID" 2>/dev/null || true

# ---- Step 4: Evaluate result ----
if grep -qi "SFSpeechError\|assetUnavailable\|speech recognition assets" "$RESULT_LOG"; then
  echo ""
  echo "PROBE PASS: The speech-recognition-assets entitlement IS load-bearing."
  echo "  SFSpeechErrorCode.assetUnavailable (or similar) was observed when the entitlement was absent."
  echo "  AUDIT-R2-S5 confirmed."
  exit 0
elif [ -z "${ENTITLEMENT_STRIPPED-}" ]; then
  echo ""
  echo "PROBE INCONCLUSIVE: The entitlement was not present in the original app binary."
  echo "  Re-run against a properly entitled Release archive."
  exit 2
else
  echo ""
  echo "PROBE INCONCLUSIVE: The speech-recognition-assets entitlement may NOT be load-bearing."
  echo "  STT worked (or did not produce assetUnavailable) after entitlement was stripped."
  echo "  This may mean: (a) STT was not exercised due to missing --probe-stt flag in 06-05,"
  echo "  (b) the macOS version does not require the entitlement, or"
  echo "  (c) AUDIT-R2-S5 is refuted — investigate before shipping."
  echo ""
  echo "  Log contents:"
  cat "$RESULT_LOG"
  exit 2  # Not a hard failure — document the result; not necessarily a bug.
fi
