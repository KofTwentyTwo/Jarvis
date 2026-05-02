#!/usr/bin/env bash
# Phase 9 / Plan 4 / D-09: NullVoiceAdapters.swift is DELETED and all three
# Null* adapter declarations have been replaced with real production adapters
# under App/Voice/{VoiceOrchestratorAdapter,VoiceTTSAdapter,VoiceBusEmitterAdapter}.swift.
#
# This script is a structural drift catcher — if a future change resurrects
# any of the Null adapter types in production code, the build fails before
# the binary is signed.
set -euo pipefail

ROOT="${1:-$(pwd)}"

if [ -f "$ROOT/App/Voice/NullVoiceAdapters.swift" ]; then
  echo "FAIL: App/Voice/NullVoiceAdapters.swift still exists (Plan 9-04 deletes it)"
  exit 1
fi

# Look for production references to the Null* adapter types. Excludes test
# scaffolding and comment-only lines (the production adapter files reference
# the Null types in their doc-comment migration history; those are allowed).
remaining=$(grep -rn --include="*.swift" \
  -E "Null(Orchestrator|TTS|BusEmitter)Adapter" \
  "$ROOT/packages" "$ROOT/App" 2>/dev/null \
  | grep -v "/Tests/" \
  | grep -v "/.build/" \
  | grep -vE ':[[:space:]]*//' \
  | grep -vE ':[[:space:]]*\*' \
  | grep -vE 'replaces[[:space:]]+`?Null' \
  || true)

if [ -n "$remaining" ]; then
  echo "FAIL: NullVoiceAdapter references remain in production:"
  echo "$remaining"
  exit 1
fi

echo "PASS: NullVoiceAdapters fully replaced"
exit 0
