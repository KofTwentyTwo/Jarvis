#!/usr/bin/env bash
# Phase 9 invariant (D-05, D-08): exactly ONE production call site iterates
# AgentOrchestrator.events with `for await`. That call site is
# OrchestratorEventBroadcaster's drain Task. Any second consumer breaks
# D-05's "single drainer" guarantee.
#
# WARNING-2 fix: the whitelist is scoped to OrchestratorEventBroadcaster.swift
# only. AppDelegate's `OrchestratorEventBroadcaster(upstream: orchestrator.events)`
# is a constructor argument, not a `for await` iteration, and is allowed by the
# precise pattern below. Any future `for await … in (orchestrator|agentOrchestrator|orch).events`
# outside the broadcaster file fails the gate.
set -euo pipefail

ROOT="${1:-$(pwd)}"
cd "$ROOT"

# Look only for `for [try] await … in (orchestrator|agentOrchestrator|orch).events` —
# the precise iteration pattern. Constructor argument references are NOT flagged.
matches=$(grep -rn --include="*.swift" \
  -E "for[[:space:]]+(try[[:space:]]+)?await[[:space:]]+\\w+[[:space:]]+in[[:space:]]+(orchestrator|agentOrchestrator|orch)\\.events" \
  packages/ App/ 2>/dev/null \
  | grep -v "/Tests/" \
  | grep -v "/.build/" \
  | grep -v "OrchestratorEventBroadcaster.swift" \
  | grep -vE ':[[:space:]]*//' \
  | grep -vE ':[[:space:]]*\*' || true)

count=$(printf '%s' "$matches" | grep -cE 'for[[:space:]]+(try[[:space:]]+)?await' || true)

if [ "$count" -gt 0 ]; then
  echo "FAIL: orchestrator.events iterated outside OrchestratorEventBroadcaster.swift:"
  printf '%s\n' "$matches"
  exit 1
fi

echo "PASS: orchestrator.events single-consumer invariant holds (zero \`for await … in …events\` outside broadcaster)"
exit 0
