#!/usr/bin/env bash
# Phase 7 / Plan 07-04 — VISION-03 reverse architectural guard.
#
# Fails the build if any file under packages/Voice/Sources OR
# packages/AgentCore/Sources/AgentOrchestrator references the
# PresenceSignalBus symbol. Legitimate consumers are ONLY:
#   - ContextBuilder (under packages/AgentCore/Sources/AgentCore — D-10)
#   - HudStateCoordinator (under App/HUD — D-10 subtle ring indicator)
# AppDelegate.installVision() may also reference it as an injection seam,
# but that is wired in Plan 07-06 — this gate runs even before that
# wiring exists.
set -euo pipefail

cd "$(dirname "$0")/.."

SEARCH_PATHS=(
    "packages/Voice/Sources"
    "packages/AgentCore/Sources/AgentOrchestrator"
)

EXISTING=()
for p in "${SEARCH_PATHS[@]}"; do
    [[ -d "$p" ]] && EXISTING+=("$p")
done

if [[ ${#EXISTING[@]} -eq 0 ]]; then
    exit 0
fi

# Strip comment-only lines (^[[:space:]]*//) before grepping so an honest
# doc comment about the rule does not trigger the gate.
HITS=$(find "${EXISTING[@]}" -name '*.swift' -print0 \
    | { xargs -0 grep -lE 'PresenceSignalBus' 2>/dev/null || true; } \
    | while read -r f; do
        if grep -vE '^[[:space:]]*//' "$f" | grep -qE 'PresenceSignalBus'; then
            echo "$f"
        fi
      done)

if [[ -n "$HITS" ]]; then
    echo "VISION-03 violation: PresenceSignalBus must not be referenced from packages/Voice/Sources or packages/AgentCore/Sources/AgentOrchestrator." >&2
    echo "Files with non-comment references:" >&2
    echo "$HITS" >&2
    exit 1
fi

exit 0
