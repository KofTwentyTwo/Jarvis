#!/usr/bin/env bash
# MEM-02 invariant guard.
#
# EMBEDDING_DIM = 768 is defined exactly once at MemoryConstants.embeddingDim.
# Any other literal 768 in the Memory module is a shadow that drifts on a
# model swap and silently returns garbage from vector queries (RESEARCH P2).
#
# Strips comment-only lines (after the file:lineno: prefix is stripped)
# before counting so prose mentioning 768 in docstrings does not fail the
# gate. The companion EmbeddingDimSymbolTests covers the parallel symbol
# case with a stricter "EMBEDDING_DIM = 768" definition pattern; this gate
# covers the bare-literal-shadow case.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

HITS=$(grep -rnE '\b768\b' packages/Memory/Sources/Memory/ --include='*.swift' 2>/dev/null \
    | grep -v 'Constants.swift:' \
    | sed -E 's|^[^:]+:[0-9]+:||' \
    | grep -vE '^[[:space:]]*(//|\*|/\*)' \
    | grep -E '\b768\b' || true)

if [[ -n "$HITS" ]]; then
    echo "MEM-02 violation: literal 768 outside MemoryConstants.embeddingDim:" >&2
    echo "$HITS" >&2
    exit 1
fi
exit 0
