#!/usr/bin/env bash
# shipping-gate.sh — Phase 8 OBS-04 shipping gate.
#
# Invokes `jarvis-eval all` over the harness's eight pillars + the per-phase
# checklist manifests. Default mode: fixture-only (no Anthropic egress, no
# live Ollama daemon required). Pass `--live` to include the live-Anthropic
# + live-Ollama pillars; live mode requires `JARVIS_LIVE_EVAL=1` in the
# environment per D-04 dual-gate.
#
# Usage:
#   scripts/shipping-gate.sh                                    # fixture-only (default)
#   JARVIS_LIVE_EVAL=1 scripts/shipping-gate.sh --live          # full matrix incl. live
#
# Variable indirection per S-6 — a smoke-test harness can substitute:
#   REPO=...            override repo root detection
#   HARNESS_PATH=...    override packages/Harness path
#   JARVIS_EVAL_BIN=... pre-built jarvis-eval binary (skip rebuild)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${REPO:=$(cd "$SCRIPT_DIR/.." && pwd)}"
: "${HARNESS_PATH:=$REPO/packages/Harness}"

LIVE_FLAG=""
if [[ "${1:-}" == "--live" ]]; then
    LIVE_FLAG="--live"
    if [[ "${JARVIS_LIVE_EVAL:-}" != "1" ]]; then
        echo "shipping-gate: --live requires JARVIS_LIVE_EVAL=1 in environment (D-04 dual-gate)." >&2
        exit 2
    fi
fi

# Reuse pre-built binary if pointed at one; otherwise build from source.
# We build in debug configuration because MCPCrashRunner (pillar f) uses
# `#if DEBUG`-gated test seams on MCPClient/MCPServerHandle (per 08-03); a
# release build of jarvis-eval would fail to compile with those accessors
# absent. The shipping gate is for the developer's machine, not a release
# distribution — debug is the right configuration.
if [[ -n "${JARVIS_EVAL_BIN:-}" ]]; then
    EVAL_BIN="$JARVIS_EVAL_BIN"
else
    cd "$HARNESS_PATH"
    swift build --product jarvis-eval
    EVAL_BIN="$HARNESS_PATH/.build/debug/jarvis-eval"
fi

cd "$REPO"
"$EVAL_BIN" all $LIVE_FLAG
