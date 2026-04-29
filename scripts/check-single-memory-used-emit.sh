#!/usr/bin/env bash
# D-05 single-emission-site invariant guard for memory.used.
#
# ReplayEvent.memoryRetrieval(...) (the memory.used DevOverlay row) may
# only be CONSTRUCTED inside MemoryStore.recordRetrieval — the path that
# 07-03 wired behind hybridSearch.
#
# Allowlist (production):
#   - packages/Memory/Sources/Memory/MemoryStore.swift   (sole emit site)
#   - packages/Replay/Sources/Replay/ReplayEvent.swift   (case decl + encoded switch arm)
#   - packages/Replay/Sources/Replay/Schema.swift        (case in encoded switch)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

HITS=$(grep -rn 'memory\.used\|\.memoryRetrieval(' packages/ App/ --include='*.swift' 2>/dev/null \
    | grep -v '/Tests/' \
    | grep -v 'packages/Memory/Sources/Memory/MemoryStore.swift:' \
    | grep -v 'packages/Replay/Sources/Replay/ReplayEvent.swift:' \
    | grep -v 'packages/Replay/Sources/Replay/Schema.swift:' \
    | sed -E 's|^[^:]+:[0-9]+:||' \
    | grep -vE '^[[:space:]]*(//|\*|/\*)' \
    | grep -E 'memory\.used|\.memoryRetrieval\(' || true)

if [[ -n "$HITS" ]]; then
    echo "D-05 violation: memory.used / .memoryRetrieval constructed outside MemoryStore.recordRetrieval:" >&2
    echo "$HITS" >&2
    exit 1
fi
exit 0
