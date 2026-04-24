#!/usr/bin/env bash
#
# smoke-test-hud.sh — Plan 03-05 Task 3.
#
# Post-build smoke test: locate the freshly built Jarvis.app in DerivedData
# and verify the R3F bundle is present with correct shape. This covers the
# end-to-end "pre-build script → rsync → blue-folder → codesign → inside
# the .app" path that `xcodebuild test` can't exercise on Xcode 26 (the
# RunningBoard error 5 / launchd-spawn-failed blocker documented in
# `.planning/debug/xctest-launch-runningboard-error-5.md`).
#
# Run AFTER `xcodebuild build -configuration Debug`. Exits non-zero on any
# shape violation with a specific error message.
#
# Usage:
#   scripts/smoke-test-hud.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# Locate the built app. Prefer Debug; fall back to Release if Debug is absent.
BUILT_APP=$(find "$HOME/Library/Developer/Xcode/DerivedData" \
    -type d -name 'Jarvis.app' -path '*/Debug/*' 2>/dev/null \
    | head -1)
if [ -z "$BUILT_APP" ]; then
    BUILT_APP=$(find "$HOME/Library/Developer/Xcode/DerivedData" \
        -type d -name 'Jarvis.app' -path '*/Release/*' 2>/dev/null \
        | head -1)
fi
if [ -z "$BUILT_APP" ]; then
    echo "ERROR: no built Jarvis.app found in DerivedData." >&2
    echo "       Run: xcodebuild build -project Jarvis.xcodeproj -scheme Jarvis \\" >&2
    echo "              -destination 'platform=macOS,arch=arm64' -configuration Debug" >&2
    exit 1
fi

echo "[smoke] built app: $BUILT_APP"

WEBVIEW="$BUILT_APP/Contents/Resources/webview"
INDEX_HTML="$WEBVIEW/index.html"
ASSETS_DIR="$WEBVIEW/assets"

# 1. webview/ subdirectory exists.
if [ ! -d "$WEBVIEW" ]; then
    echo "ERROR: $WEBVIEW is missing — blue-folder reference broken?" >&2
    exit 1
fi

# 2. index.html is in the bundle.
if [ ! -f "$INDEX_HTML" ]; then
    echo "ERROR: $INDEX_HTML is missing — did build-webview.sh rsync fail?" >&2
    exit 1
fi

# 3. assets/ subdirectory exists with at least one .js chunk.
if [ ! -d "$ASSETS_DIR" ]; then
    echo "ERROR: $ASSETS_DIR is missing — Vite build output not rsynced." >&2
    exit 1
fi
JS_COUNT=$(find "$ASSETS_DIR" -name '*.js' -type f 2>/dev/null | wc -l | tr -d ' ')
if [ "$JS_COUNT" -lt 1 ]; then
    echo "ERROR: no *.js chunks in $ASSETS_DIR" >&2
    exit 1
fi

# 4. index.html references ./assets/ (relative) and NOT /assets/ (absolute).
if ! grep -q '\./assets/' "$INDEX_HTML"; then
    echo "ERROR: $INDEX_HTML does not reference ./assets/ — Vite base setting wrong?" >&2
    exit 1
fi
if grep -q 'src="/assets/' "$INDEX_HTML"; then
    echo "ERROR: $INDEX_HTML references absolute /assets/ src — WKWebView file:// will 404." >&2
    exit 1
fi
if grep -q 'href="/assets/' "$INDEX_HTML"; then
    echo "ERROR: $INDEX_HTML references absolute /assets/ href — WKWebView file:// will 404." >&2
    exit 1
fi

# 5. bus-harness.html preserved (02-04 parity script requires both copies).
if [ ! -f "$WEBVIEW/bus-harness.html" ]; then
    echo "ERROR: bus-harness.html missing from bundle — build-webview.sh rsync --delete'd it?" >&2
    exit 1
fi

echo "[smoke] PASS: bundle shape OK"
echo "       index.html:      $(wc -c < "$INDEX_HTML") bytes"
echo "       assets/*.js:     $JS_COUNT chunk(s)"
echo "       bus-harness.html: preserved"
