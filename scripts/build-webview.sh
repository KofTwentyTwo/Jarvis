#!/usr/bin/env bash
#
# build-webview.sh — Xcode pre-build phase (Plan 03-05).
#
# Produces webview/packages/hud/dist/ and rsyncs the output into
# App/Resources/webview/ so the R3F bundle is covered by the app bundle
# codesign pass.
#
# Order invariant (see project.yml preBuildScripts + postBuildScripts):
#   preBuildScripts:
#     1. check-bus-harness-parity.sh
#     2. check-bus-protocol-version.sh
#     3. check-no-evaluate-javascript.sh
#     4. check-single-writer-hudstate.sh
#     5. build-webview.sh (this script)   ← produces Resources/webview/assets/*.js
#   postBuildScripts:
#     6. verify-entitlements.sh --pre-codesign
#     7. codesign.sh                       ← signs Jarvis.app INCLUDING
#                                            Contents/Resources/webview/
#     8. verify-entitlements.sh --post-codesign
#     9. verify-codesign-settings.sh
#
# Caching: this script pnpm-installs only when the lockfile sha changed
# (content-hash sentinel). On clean repos the first run is slow (~30s);
# subsequent incremental Xcode builds are ~3-5s through the pnpm cache.
#
# The rsync explicitly EXCLUDES `bus-harness.html` and the webview's own
# `.gitignore` so we never trample 02-03's committed bus-harness.html (which
# the `check-bus-harness-parity.sh` pre-build phase requires to exist + stay
# byte-identical with `webview/bus-harness.html`).
#
# Usage:
#   scripts/build-webview.sh              # invoked by Xcode pre-build
#   bash scripts/build-webview.sh         # manual from repo root

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# Xcode IDE GUI doesn't inherit the user's shell PATH (only `xcodebuild` from
# a terminal does). Homebrew + corepack-managed pnpm live outside the default
# /usr/bin:/bin minimal env Xcode uses for build phases. Prepend the common
# locations so this script works identically from CLI and from Xcode IDE.
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/.nvm/versions/node:${PATH:-/usr/bin:/bin}"

if ! command -v pnpm >/dev/null 2>&1; then
    echo "[build-webview] FATAL: pnpm not found on PATH ($PATH)" >&2
    echo "[build-webview]   Install: brew install pnpm  OR  npm i -g pnpm" >&2
    exit 1
fi

cd "$REPO_ROOT/webview"

# Content-hash sentinel: only pnpm install when pnpm-lock.yaml changed.
LOCKFILE_SHA=$(shasum -a 256 pnpm-lock.yaml | cut -d' ' -f1)
STAMP_FILE="node_modules/.jarvis-lock-sha256"

if [ ! -d node_modules ] || [ ! -f "$STAMP_FILE" ] \
        || [ "$(cat "$STAMP_FILE" 2>/dev/null)" != "$LOCKFILE_SHA" ]; then
    echo "[build-webview] pnpm install (lockfile changed or fresh tree)..."
    pnpm install --frozen-lockfile
    echo "$LOCKFILE_SHA" > "$STAMP_FILE"
else
    echo "[build-webview] pnpm install skipped (lockfile unchanged)"
fi

echo "[build-webview] building @jarvis/bus..."
pnpm --filter @jarvis/bus build

echo "[build-webview] building @jarvis/hud..."
pnpm --filter @jarvis/hud build

DEST="$REPO_ROOT/App/Resources/webview"
mkdir -p "$DEST"

echo "[build-webview] rsync dist/ -> $DEST"
# --exclude bus-harness.html: keep 02-03's committed copy intact (parity
#   script enforces byte-equality between webview/bus-harness.html and
#   App/Resources/webview/bus-harness.html).
# --exclude .gitignore: preserve the App/Resources/webview/.gitignore that
#   lets index.html stay source-committed while assets/ regenerates.
# We do NOT pass --delete: other vendored assets coexist in this dir.
rsync -a \
      --exclude=bus-harness.html \
      --exclude=.gitignore \
      "$REPO_ROOT/webview/packages/hud/dist/" \
      "$DEST/"

echo "[build-webview] done — $DEST populated"
