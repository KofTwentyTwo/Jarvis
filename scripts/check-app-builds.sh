#!/usr/bin/env bash
# G-01 (Plan 05-VERIFICATION): Compile-only gate for the App target.
#
# The Xcode 26 xctest harness is upstream-broken on ad-hoc Debug bundles
# (.planning/debug/xctest-launch-runningboard-error-5.md), so the test loop
# never compiles the App target as part of `swift test`. SPM packages compile
# fine on their own, but App-target-specific Swift 6 errors (e.g., await in a
# string-interpolation autoclosure) only surface during `xcodebuild build`.
#
# This script ensures `xcodebuild build -configuration Debug` of the App
# target is exercised on demand. Wire as a manual or CI gate; running it as
# a preBuildScript would create a circular dependency.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$REPO_ROOT"

if [ ! -d Jarvis.xcodeproj ]; then
  echo "[check-app-builds] Jarvis.xcodeproj missing; running xcodegen..."
  xcodegen generate >/dev/null
fi

# Use a CLI-private DerivedData (./build/) so that Xcode IDE running in
# parallel doesn't race against the post-codesign step. Sharing the default
# DerivedData with Xcode IDE causes Xcode's background indexer/build to
# touch Jarvis.app after our verify-entitlements --pre-codesign + codesign.sh
# postBuildScripts complete, which (a) invalidates the bundle's signature
# (`codesign --verify` reports "plist or signature have been modified") and
# (b) reverts the JarvisEntitlementsVerified marker in Info.plist to false.
# The runtime entitlement probe in AppDelegate then hard-blocks at launch
# via Logger.critical with "JarvisEntitlementsVerified missing/false".
# Isolation eliminates the race entirely; bundle launches cleanly.
echo "[check-app-builds] xcodebuild build (Debug, arm64, isolated DerivedData)..."

# Capture the full xcodebuild log to a tempfile so we can summarise errors
# on failure. `-quiet` + `tail -5` previously suppressed every signal except
# `** BUILD FAILED **`, making CI failures undebuggable without re-running
# locally. The set-pipefail + tee ensures we keep both a streamed (quiet)
# console view and the full log for grep'ing.
LOG="$(mktemp -t check-app-builds-XXXXXX.log)"
trap 'rm -f "$LOG"' EXIT

set +e
xcodebuild build \
  -project Jarvis.xcodeproj \
  -scheme Jarvis \
  -destination 'platform=macOS,arch=arm64' \
  -configuration Debug \
  -derivedDataPath "$REPO_ROOT/build" \
  > "$LOG" 2>&1
status=$?
set -e

if [ "$status" -eq 0 ]; then
  tail -5 "$LOG"
  echo "[check-app-builds] PASS — App target compiles cleanly"
  exit 0
fi

# Failure path: surface every `error:` line plus a generous tail for context.
echo "[check-app-builds] FAIL — xcodebuild exited $status. Error lines:" >&2
grep -E "error:|fatal error:|: error " "$LOG" >&2 || true
echo >&2
echo "[check-app-builds] Last 80 lines of xcodebuild output:" >&2
tail -80 "$LOG" >&2
exit 1
