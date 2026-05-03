#!/usr/bin/env bash
# copy-voice-models.sh — bundle ONNX model files into the .app at build time.
#
# Track B-1 (2026-05-03 voice audit fix). The voice subsystem expects
# models at `Contents/Resources/Models/{openWakeWord,silero}/*.onnx`
# inside the built .app bundle. This script copies them from the
# repo-root `Resources/models/{openwakeword,silero}/` canonical layout,
# applying the case fix (`openwakeword` → `openWakeWord`) along the way.
#
# Hard-fails on:
#   - MANIFEST.json containing literal `PLACEHOLDER_…` sha256 (someone
#     forgot to run `scripts/fetch-silero-models.sh` /
#     `scripts/fetch-openwakeword-models.sh`).
#   - any required model file missing on disk.
#
# Soft-degrades (warns, continues) on:
#   - source models dir absent entirely (OK in CI / unit-test workflows
#     that don't need voice).
#
# Environment: runs as a postBuildScript inside xcodebuild. SRCROOT,
# TARGET_BUILD_DIR, WRAPPER_NAME are provided by Xcode.
set -euo pipefail

REPO_ROOT="${SRCROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SRC_BASE="${REPO_ROOT}/Resources/models"
DEST_BASE="${TARGET_BUILD_DIR:?}/${WRAPPER_NAME:?}/Contents/Resources/Models"

if [ ! -d "$SRC_BASE" ]; then
    echo "warning: voice models source dir '$SRC_BASE' missing — skipping copy"
    exit 0
fi

mkdir -p "$DEST_BASE"

# Mapping: canonical-on-disk → runtime-bundle-path. Add a row when a new
# subsystem ships ONNX models.
#
# Format: "src_subdir:dest_subdir:manifest_required"
declare -a SUBSYSTEMS=(
    "openwakeword:openWakeWord:1"
    "silero:silero:1"
)

assert_manifest_populated() {
    local manifest="$1"
    local subsystem="$2"
    if [ ! -f "$manifest" ]; then
        echo "error: $subsystem MANIFEST.json missing at $manifest" >&2
        exit 1
    fi
    if grep -q "PLACEHOLDER_" "$manifest"; then
        echo "error: $subsystem MANIFEST.json contains PLACEHOLDER hashes — run scripts/fetch-${subsystem}-models.sh first" >&2
        echo "       (placeholder lines:)" >&2
        grep "PLACEHOLDER_" "$manifest" >&2
        exit 1
    fi
}

for ROW in "${SUBSYSTEMS[@]}"; do
    IFS=':' read -r SRC_SUB DEST_SUB REQ <<< "$ROW"
    SRC_DIR="${SRC_BASE}/${SRC_SUB}"
    DEST_DIR="${DEST_BASE}/${DEST_SUB}"

    if [ ! -d "$SRC_DIR" ]; then
        if [ "$REQ" = "1" ]; then
            echo "error: required voice model dir '$SRC_DIR' missing" >&2
            exit 1
        fi
        continue
    fi

    assert_manifest_populated "${SRC_DIR}/MANIFEST.json" "$SRC_SUB"

    mkdir -p "$DEST_DIR"
    # rsync over cp -R: preserves timestamps so unchanged files don't
    # invalidate the cache; --delete keeps the bundle clean of stale
    # copies after a model removal.
    rsync -a --delete \
        --exclude '.gitkeep' \
        --exclude '.gitignore' \
        "${SRC_DIR}/" "${DEST_DIR}/"
done

echo "[copy-voice-models] OK — copied to ${DEST_BASE}"
