#!/usr/bin/env bash
# promote-replay-session.sh — D-09 operator helper.
#
# Copies a recorded session SQLite into Corpora/replay-golden/ + records
# temperature / model / replaySchemaVersion meta into a sidecar JSON so
# DriftClassifier knows whether `nondeterministicUnderSampling` exclusions
# apply to this archetype on replay.
#
# Usage:
#   scripts/promote-replay-session.sh <session.sqlite> <archetype-name>
#
# Where <archetype-name> is one of (D-08 curated set):
#   short-turn, long-multitool-turn, cap-recovery,
#   confirm-approved, confirm-denied, voice-barge-in,
#   stream-truncation-retry, vision-frame-attach
#
# The source SQLite must contain a `meta` table with rows for
# `temperature`, `model`, and `schema_version` (P4 ReplayLog writes these).
# Missing keys default to "0.0" / "unknown" / "1" respectively.
#
# Variable indirection per S-6:
#   REPO=...        override repo root detection
#   DEST_DIR=...    override Corpora/replay-golden/ path
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${REPO:=$(cd "$SCRIPT_DIR/.." && pwd)}"
: "${DEST_DIR:=$REPO/packages/Harness/Corpora/replay-golden}"

SRC="${1:?source SQLite path required (arg 1)}"
NAME="${2:?archetype name required (arg 2)}"
DEST_SQLITE="${DEST_DIR}/${NAME}.sqlite"
DEST_META="${DEST_DIR}/${NAME}.meta.json"

[[ -f "$SRC" ]] || { echo "promote-replay-session: source SQLite not found: $SRC" >&2; exit 1; }
mkdir -p "$DEST_DIR"

# Read meta from source's `meta` table. Parameter-free SELECT — no SQL
# injection surface (T-08-22 mitigation).
TEMPERATURE=$(sqlite3 "$SRC" "SELECT value FROM meta WHERE key='temperature' LIMIT 1;" 2>/dev/null || true)
MODEL=$(sqlite3 "$SRC" "SELECT value FROM meta WHERE key='model' LIMIT 1;" 2>/dev/null || true)
SCHEMA=$(sqlite3 "$SRC" "SELECT value FROM meta WHERE key='schema_version' LIMIT 1;" 2>/dev/null || true)
RECORDED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

[[ -z "$TEMPERATURE" ]] && TEMPERATURE="0.0"
[[ -z "$MODEL" ]] && MODEL="unknown"
[[ -z "$SCHEMA" ]] && SCHEMA="1"

# JSON-escape the model string (it can carry colons and slashes).
MODEL_ESCAPED=$(printf '%s' "$MODEL" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')

cp -p "$SRC" "$DEST_SQLITE"

cat > "$DEST_META" <<JSON_EOF
{
  "archetype": "${NAME}",
  "temperature": ${TEMPERATURE},
  "model": "${MODEL_ESCAPED}",
  "replaySchemaVersion": ${SCHEMA},
  "recordedAt": "${RECORDED_AT}",
  "source": "${SRC}"
}
JSON_EOF

echo "Promoted: $DEST_SQLITE"
echo "Meta:     $DEST_META"
