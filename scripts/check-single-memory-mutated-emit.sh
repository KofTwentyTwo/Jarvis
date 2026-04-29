#!/usr/bin/env bash
# MEM-06 single-emission-site invariant guard.
#
# `ReplayEvent.memoryMutation(...)` (which serializes to the `memory.mutated`
# DevOverlay row) may only be CONSTRUCTED inside MemoryStore.applyOp.
# Multiple emit sites would (a) duplicate DevOverlay rows and (b) invalidate
# the planner-stated invariant in 07-02's must_haves.
#
# Allowlist (production):
#   - packages/Memory/Sources/Memory/MemoryStore.swift   (sole emit site, in applyOp)
#   - packages/Replay/Sources/Replay/ReplayEvent.swift   (case decl + encoded() switch arm)
#   - packages/Replay/Sources/Replay/Schema.swift        (case in encoded() switch)
#
# Tests are excluded entirely (`/Tests/`). Comment-only lines (after the
# file:lineno: prefix is stripped) are tolerated so docstrings explaining
# the rule do not trip the gate.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Strip the `file:lineno:` prefix and inspect the line content. A comment is
# a line whose first non-whitespace characters are `//` or `*` or `/*`.
HITS=$(grep -rn 'memory\.mutated\|\.memoryMutation(' packages/ App/ --include='*.swift' 2>/dev/null \
    | grep -v '/Tests/' \
    | grep -v 'packages/Memory/Sources/Memory/MemoryStore.swift:' \
    | grep -v 'packages/Replay/Sources/Replay/ReplayEvent.swift:' \
    | grep -v 'packages/Replay/Sources/Replay/Schema.swift:' \
    | sed -E 's|^[^:]+:[0-9]+:||' \
    | grep -vE '^[[:space:]]*(//|\*|/\*)' \
    | grep -E 'memory\.mutated|\.memoryMutation\(' || true)

if [[ -n "$HITS" ]]; then
    echo "MEM-06 violation: memory.mutated / .memoryMutation constructed outside MemoryStore.applyOp:" >&2
    echo "$HITS" >&2
    exit 1
fi
exit 0
