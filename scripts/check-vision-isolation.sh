#!/usr/bin/env bash
# Phase 7 / Plan 07-04 — VISION-03 architectural guard.
#
# Fails the build if any file under packages/Vision/Sources/ contains
# `import Voice` or `import AgentOrchestrator`. This enforces the
# packages/Vision SPM target's dependency-graph isolation at the textual
# level — even if a future SPM refactor accidentally adds the dep,
# this script catches the import statement.
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ ! -d packages/Vision/Sources ]]; then
    exit 0
fi

HITS=$(find packages/Vision/Sources -name '*.swift' -print0 \
    | xargs -0 grep -nHE '^[[:space:]]*import[[:space:]]+(Voice|AgentOrchestrator)([[:space:]]|$)' \
    2>/dev/null || true)

if [[ -n "$HITS" ]]; then
    echo "VISION-03 violation: packages/Vision/Sources must not import Voice or AgentOrchestrator." >&2
    echo "Hits:" >&2
    echo "$HITS" >&2
    exit 1
fi

exit 0
