#!/usr/bin/env bash
# Track-D D-5 — skeleton for building a custom libsqlite3.dylib with
# SQLITE_ENABLE_LOAD_EXTENSION=1 so vec0.dylib can be loaded at runtime.
#
# WHY: macOS ships libsqlite3 with extension loading disabled. Memory's
# vec0 search path needs SQLite to call sqlite3_load_extension(); the
# system library will refuse. Build a vendored libsqlite3.dylib once,
# codesign it with the team identity, and bundle under
# App/Resources/sqlite/ so MemoryStore's connection initializer can
# point SQLITE_LIBRARY_PATH at it.
#
# THIS IS A SKELETON. It will exit 1 with a clear message until the
# user fills in the TODO markers below. The intent is to capture the
# steps so the user can pick this up cleanly without re-deriving the
# build commands.
#
# Output: ./build/sqlite/libsqlite3.dylib (codesigned, ad-hoc by default)
#
# Usage (after TODOs are filled):
#   bash scripts/build-sqlite-with-extensions.sh

set -euo pipefail

# TODO: pin SQLite version. Last known-good is 3.45.x; check
# https://www.sqlite.org/download.html for the current amalgamation URL.
SQLITE_VERSION=""              # e.g., 3450200
SQLITE_AMALGAMATION_URL=""     # e.g., https://www.sqlite.org/2024/sqlite-amalgamation-3450200.zip
SQLITE_AMALGAMATION_SHA256=""  # pin the SHA256 of the zip

# TODO: codesign identity. "-" = ad-hoc; for distribution use the
# Developer ID Application cert. Per CLAUDE.md "codesign inside-out;
# never --deep".
CODESIGN_IDENTITY="-"

if [[ -z "$SQLITE_VERSION" || -z "$SQLITE_AMALGAMATION_URL" || -z "$SQLITE_AMALGAMATION_SHA256" ]]; then
  echo "[build-sqlite] TODO: fill in SQLITE_VERSION + SQLITE_AMALGAMATION_URL + SQLITE_AMALGAMATION_SHA256 at the top of this script."
  echo "[build-sqlite] See https://www.sqlite.org/download.html for the latest amalgamation."
  exit 1
fi

# --- skeleton outline (commented; uncomment when TODOs filled) -------------
#
# WORK_DIR="build/sqlite"
# mkdir -p "$WORK_DIR"
# pushd "$WORK_DIR" >/dev/null
#
# curl -fsSL -o sqlite-amalgamation.zip "$SQLITE_AMALGAMATION_URL"
# echo "$SQLITE_AMALGAMATION_SHA256  sqlite-amalgamation.zip" | shasum -a 256 -c -
# unzip -q -o sqlite-amalgamation.zip
# cd "sqlite-amalgamation-$SQLITE_VERSION"
#
# clang -O2 -dynamiclib \
#   -DSQLITE_ENABLE_LOAD_EXTENSION=1 \
#   -DSQLITE_ENABLE_FTS5=1 \
#   -DSQLITE_ENABLE_RTREE=1 \
#   -DSQLITE_THREADSAFE=2 \
#   -arch arm64 \
#   -install_name @rpath/libsqlite3.dylib \
#   -o ../libsqlite3.dylib \
#   sqlite3.c
#
# popd >/dev/null
# codesign --force --sign "$CODESIGN_IDENTITY" --options runtime --timestamp=none \
#   "$WORK_DIR/libsqlite3.dylib"
#
# echo "[build-sqlite] OK: $WORK_DIR/libsqlite3.dylib"
# ---------------------------------------------------------------------------

echo "[build-sqlite] TODO: implement build steps (uncomment the outline above and tune flags as needed)."
exit 1
