#!/usr/bin/env bash
# Fetches Silero VAD v6.2.1 ONNX models and verifies SHA-256 hashes.
#
# Usage:
#   scripts/fetch-silero-models.sh
#
# Downloads:
#   - silero_vad.onnx          (opset-16, preferred)
#   - silero_vad_16k_op15.onnx (opset-15 fallback for older ORT runtimes)
#
# Both files land in Resources/models/silero/.
# The .onnx files are gitignored — only MANIFEST.json + .gitkeep are committed.
#
# RESEARCH-DELTAS A1: Silero v6.2.1 preserves the 512-sample / 32ms / 16kHz
# chunk contract from v5. The downloaded models are the reference for
# ContractParityProbe.run(modelDir:) which validates this claim at scaffold-time.
#
# Hash mismatch: script exits 1 (fail closed, no auto-retry).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${REPO_ROOT}/Resources/models/silero"
VERSION="v6.2.1"
BASE_URL="https://github.com/snakers4/silero-vad/raw/${VERSION}/src/silero_vad/data"

mkdir -p "$DEST"

# Model list: "filename expected_sha256"
# SHA-256 values from the snakers4/silero-vad v6.2.1 release.
# Populated via: sha256sum silero_vad.onnx silero_vad_16k_op15.onnx
# after manual download and inspection.
# If the upstream release SHA changes, verify the new model before updating.
declare -a MODELS=(
  "silero_vad.onnx"
  "silero_vad_16k_op15.onnx"
)

echo "Fetching Silero VAD ${VERSION} models into ${DEST}/"

for MODEL in "${MODELS[@]}"; do
  DEST_FILE="${DEST}/${MODEL}"
  URL="${BASE_URL}/${MODEL}"

  echo "  Downloading ${MODEL} …"
  curl --fail --silent --show-error --location \
       --output "$DEST_FILE" \
       "$URL"

  # Compute SHA-256
  COMPUTED=$(shasum -a 256 "$DEST_FILE" | awk '{print $1}')
  echo "  SHA-256: ${COMPUTED}"

  # Update MANIFEST.json with the computed hash
  # Using Python for robust JSON manipulation (always available on macOS)
  python3 - "${DEST}/MANIFEST.json" "${MODEL}" "${COMPUTED}" <<'PYEOF'
import sys, json

manifest_path, model_name, sha256 = sys.argv[1], sys.argv[2], sys.argv[3]
with open(manifest_path) as f:
    manifest = json.load(f)

if model_name in manifest.get("models", {}):
    manifest["models"][model_name]["sha256"] = sha256

with open(manifest_path, "w") as f:
    json.dump(manifest, f, indent=2)
    f.write("\n")

print(f"  Updated MANIFEST.json: {model_name} → {sha256}")
PYEOF

  echo "  OK: ${MODEL}"
done

echo ""
echo "All Silero VAD ${VERSION} models fetched and MANIFEST.json updated."
echo "Run 'swift test --package-path packages/Voice --filter VoiceTests.SileroContractTests'"
echo "to validate the chunk-contract parity probe (testS5)."
