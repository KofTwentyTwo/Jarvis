#!/usr/bin/env bash
# Track-D D-6 — skeleton for fetching the prebuilt vec0.dylib from
# https://github.com/asg017/sqlite-vec/releases/latest, verifying the
# SHA256, and dropping it into App/Resources/vec0.dylib so the bundled
# libsqlite3 (D-5) can `sqlite3_load_extension()` it at runtime.
#
# THIS IS A SKELETON. It will exit 1 with a clear message until the
# user fills in the TODO markers below. The intent is to capture the
# steps so the user can pick this up cleanly without re-deriving the
# fetch + verify + sign sequence.
#
# Output: App/Resources/vec0.dylib (codesigned)
#
# Usage (after TODOs are filled):
#   bash scripts/fetch-sqlite-vec.sh

set -euo pipefail

# TODO: pin sqlite-vec release version. Latest as of writing: v0.1.6
# (check https://github.com/asg017/sqlite-vec/releases). Pinning a tag
# rather than tracking "latest" is intentional — the SHA256 below must
# match this exact tag.
SQLITE_VEC_VERSION=""  # e.g., v0.1.6

# TODO: pin the SHA256 of the macOS arm64 .dylib for that release. Find
# it from the release's checksums file or by running shasum on a fresh
# download. Without a pinned hash this script silently trusts whatever
# GitHub serves.
SQLITE_VEC_SHA256=""

# TODO: codesign identity. "-" = ad-hoc; for distribution use the
# Developer ID Application cert.
CODESIGN_IDENTITY="-"

DEST="App/Resources/vec0.dylib"

if [[ -z "$SQLITE_VEC_VERSION" || -z "$SQLITE_VEC_SHA256" ]]; then
  echo "[fetch-sqlite-vec] TODO: fill in SQLITE_VEC_VERSION + SQLITE_VEC_SHA256 at the top of this script."
  echo "[fetch-sqlite-vec] Releases: https://github.com/asg017/sqlite-vec/releases"
  exit 1
fi

# --- skeleton outline (commented; uncomment when TODOs filled) -------------
#
# # Asset naming: sqlite-vec-${VERSION}-loadable-macos-aarch64.tar.gz
# # contains vec0.dylib at the root. Adjust if upstream renames.
# ASSET_NAME="sqlite-vec-${SQLITE_VEC_VERSION#v}-loadable-macos-aarch64.tar.gz"
# URL="https://github.com/asg017/sqlite-vec/releases/download/${SQLITE_VEC_VERSION}/${ASSET_NAME}"
#
# WORK_DIR="$(mktemp -d)"
# trap 'rm -rf "$WORK_DIR"' EXIT
#
# curl -fsSL -o "$WORK_DIR/$ASSET_NAME" "$URL"
# tar -xzf "$WORK_DIR/$ASSET_NAME" -C "$WORK_DIR"
#
# echo "$SQLITE_VEC_SHA256  $WORK_DIR/vec0.dylib" | shasum -a 256 -c -
#
# mkdir -p "$(dirname "$DEST")"
# cp "$WORK_DIR/vec0.dylib" "$DEST"
#
# codesign --force --sign "$CODESIGN_IDENTITY" --options runtime --timestamp=none "$DEST"
#
# echo "[fetch-sqlite-vec] OK: $DEST"
# ---------------------------------------------------------------------------

echo "[fetch-sqlite-vec] TODO: implement fetch steps (uncomment the outline above and confirm the asset name for your tag)."
exit 1
