#!/usr/bin/env bash
# fetch-openwakeword-models.sh — Download and hash-pin openWakeWord ONNX weights.
#
# Usage:
#   bash scripts/fetch-openwakeword-models.sh
#
# What it does:
#   1. Downloads three ONNX files from the dscripka/openWakeWord v0.5.1 release.
#   2. Computes SHA-256 for each downloaded file.
#   3. Writes updated SHA-256 values to Resources/models/openwakeword/MANIFEST.json.
#
# Run this once on a fresh checkout, or after intentionally upgrading model weights.
# The ONNX files are gitignored — only MANIFEST.json is committed.
#
# DO NOT auto-redownload on hash mismatch at runtime — fail closed via
# WakeWordError.modelHashMismatch (VOICE-01 / T-06-02-01).
#
# After running, verify with:
#   swift test --package-path packages/Voice --filter VoiceTests.ModelManifestTests
#
# Note: ${VAR-default} (no colon) used intentionally — empty DEST is meaningful.
set -euo pipefail

DEST=${DEST-Resources/models/openwakeword}

URLS=(
  "https://github.com/dscripka/openWakeWord/releases/download/v0.5.1/melspectrogram.onnx"
  "https://github.com/dscripka/openWakeWord/releases/download/v0.5.1/embedding_model.onnx"
  "https://github.com/dscripka/openWakeWord/releases/download/v0.5.1/hey_jarvis_v0.1.onnx"
)

echo "Downloading openWakeWord ONNX models to ${DEST}..."
for url in "${URLS[@]}"; do
  name=$(basename "$url")
  echo "  fetching ${name}..."
  curl -fSL "$url" -o "${DEST}/${name}"
done

echo "Computing SHA-256 hashes and updating MANIFEST.json..."
python3 - <<'PYEOF'
import hashlib, json, pathlib, sys

dest = pathlib.Path("Resources/models/openwakeword")
filenames = ["melspectrogram.onnx", "embedding_model.onnx", "hey_jarvis_v0.1.onnx"]

models = []
for fn in filenames:
    path = dest / fn
    if not path.exists():
        print(f"ERROR: {path} not found after download", file=sys.stderr)
        sys.exit(1)
    sha256 = hashlib.sha256(path.read_bytes()).hexdigest()
    models.append({"filename": fn, "sha256": sha256})
    print(f"  {fn}: {sha256}")

manifest = {"version": 1, "models": models}
manifest_path = dest / "MANIFEST.json"
manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
print(f"\nMANIFEST.json updated at {manifest_path}")
PYEOF

echo ""
echo "Done. The MANIFEST.json now contains pinned SHA-256 hashes."
echo "Commit MANIFEST.json to lock the weight versions."
echo ""
echo "Verify integrity:"
echo "  swift test --package-path packages/Voice --filter VoiceTests.ModelManifestTests"
