---
phase: 04-agent-core
plan: 04
subsystem: agent
tags: [agent, orchestrator, security, sec-06, agent-06, agent-07, agent-08, agent-09]
requires: [04-01, 04-02, 04-03]
provides:
  - AgentOrchestrator actor (turn-lifecycle entrypoint)
  - OrchestratorEvent (bus-bound event surface)
  - SubmitOutcome (.ran / .superseded / .rejected)
  - TurnInput (text / voice / memoryExtraction)
  - TurnNonce (SecRandomCopyBytes(16) base64url)
  - UntrustedWrapper (tag-strip + nonce envelope)
  - ToolResultPacker (8 KB cap; full-blob preservation)
  - ToolDispatcher protocol (P5 wires real MCP)
  - TurnState (idle / thinking / reconfiguring / ...)
  - RetryState (1-shot stream_truncated retry)
affects:
  - packages/AgentCore/Package.swift (new product + target)
  - packages/AgentCore/Sources/AnthropicProvider/Base64URL.swift (moved → AgentCore, public)
tech-stack:
  added:
    - Swift actor `AgentOrchestrator` (the turn-lifecycle state machine)
    - Test-only `MockLLMProvider` (scriptable LLMProvider conformance)
  patterns:
    - Actor-reentrancy guard (cancel + `await task.value` before reassignment)
    - Provider injection via `@Sendable` factory closure (testability)
    - Per-turn nonce never crosses the bus boundary (SEC-06)
    - 8 KB cap on model-facing tool_result; full bytes to ReplayLog
    - 1-shot bounded retry on stream_truncated (no exponential backoff)
    - Cap-recovery: tool-budget exhaustion → toolChoice .none re-invoke
key-files:
  created:
    - packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift
    - packages/AgentCore/Sources/AgentOrchestrator/OrchestratorEvent.swift
    - packages/AgentCore/Sources/AgentOrchestrator/SubmitOutcome.swift
    - packages/AgentCore/Sources/AgentOrchestrator/TurnInput.swift
    - packages/AgentCore/Sources/AgentOrchestrator/PerTurnSnapshot+Agent.swift
    - packages/AgentCore/Sources/AgentOrchestrator/UntrustedWrapper.swift (in AgentCore)
    - packages/AgentCore/Sources/AgentOrchestrator/TurnNonce.swift (in AgentCore)
    - packages/AgentCore/Sources/AgentOrchestrator/ToolResultPacker.swift (in AgentCore)
    - packages/AgentCore/Sources/AgentOrchestrator/ToolDispatcher.swift
    - packages/AgentCore/Sources/AgentOrchestrator/TurnState.swift
    - packages/AgentCore/Sources/AgentOrchestrator/RetryState.swift
    - packages/AgentCore/Sources/AgentCore/TurnNonce.swift
    - packages/AgentCore/Sources/AgentCore/UntrustedWrapper.swift
    - packages/AgentCore/Sources/AgentCore/ToolResultPacker.swift
    - packages/AgentCore/Tests/AgentCoreTests/{TurnNonce,UntrustedWrapper,ToolResultPacker}Tests.swift
    - packages/AgentCore/Tests/AgentOrchestratorTests/MockLLMProvider.swift
    - packages/AgentCore/Tests/AgentOrchestratorTests/Helpers.swift
    - packages/AgentCore/Tests/AgentOrchestratorTests/Orchestrator{Submit,Cancel,Retry,CapRecovery}Tests.swift
  modified:
    - packages/AgentCore/Package.swift (added Replay dep + AgentOrchestrator target/test target)
    - packages/AgentCore/Sources/AgentCore/Base64URL.swift (moved from AnthropicProvider; promoted to public)
decisions:
  - Decision: split orchestrator into a new SPM target `AgentOrchestrator` (rather than `Sources/AgentCore/`)
    rationale: Replay → AgentCore is a pre-existing dependency (TurnID); the plan's
      literal layout would have created an SPM cycle. Carving a new target eliminated
      the cycle while keeping the orchestrator inside the same package. Documented as
      a Rule 3 deviation.
  - Decision: cancelAndSubmit uses `priorTask.cancel(); _ = await priorTask.value` BEFORE assigning new currentTurn
    rationale: AGENT-06 actor-reentrancy invariant. Without `await task.value`, a late
      `.messageStop` from the cancelled stream could resume on the actor and clobber
      `currentTurn`. Test OC3 specifically exercises and asserts this guard.
  - Decision: 8 KB cap configured at the constant `ToolResultPacker.modelFacingCapBytes`
    rationale: Opus 4.7 tokenizer ~1.35× ratio vs Opus 3.x; 8 KB ≈ 12 K tokens — three
      tool calls per turn fit inside ~36 K tokens. Conservative; revisit empirically
      via DevOverlay cache-ratio signal in P5+.
  - Decision: 1-shot retry on stream_truncated (no rolling window, no exponential backoff)
    rationale: AGENT-09 spec. RetryState.budget = 1 makes the bound impossible to
      misread; tests OR1/OR2 verify exactly one retry then terminal.
  - Decision: cap-recovery passes `toolChoice: .none` AND empties the tools array
    rationale: AGENT-07. Both signals are required because Anthropic and Ollama
      serialize differently — Anthropic emits `{type:"none"}`; Ollama drops the
      `tools` field entirely. The orchestrator does both; per-provider
      RequestBody encoders honor each correctly (Plan 04-01 + Plan 04-02 tests).
  - Decision: `events: BoundedAsyncChannel` is `nonisolated`
    rationale: Callers must `for await event in orch.events` without entering the
      actor's isolation domain. The channel is itself an actor — safe to expose.
  - Decision: turnNonce is persisted via ReplayLog.startTurn(turnNonce:) but never
    appears in any OrchestratorEvent case
    rationale: SEC-06. Grep gate enforces zero `turnNonce` mentions in
      OrchestratorEvent.swift; nonce stays inside the orchestrator and the on-disk
      replay row only.
metrics:
  duration_minutes: 22
  completed: 2026-04-24
  task_count: 3
  test_count_added: 22
  total_test_count_after: 114  # 81 base + 13 (Task 1) + 11 (Task 2) + 9 (Task 3)
  loc_added: 1851
  files_changed: 22
---

# Phase 4 Plan 04: Agent Orchestrator Summary

The turn-lifecycle actor that wires Plan 04-01's `LLMProvider` protocol,
Plan 04-02's Ollama+Anthropic implementations, and Plan 04-03's `ReplayLog`
into a single submit/cancel/retry/cap-recovery state machine. Closes
AGENT-06 (submit / cancelAndSubmit / SubmitOutcome), AGENT-07 (cap-recovery
via tool_choice .none), AGENT-08 (8 KB tool-result cap with full-blob
preservation in replay log), AGENT-09 (1-shot stream_truncated retry), and
SEC-06 (turn-nonce injection defense).

## What landed

- `AgentOrchestrator` actor with `submit(_:)` and `cancelAndSubmit(_:)` as
  the only turn-lifecycle entry points.
- `SubmitOutcome` enum with the three documented cases: `.ran(turnId:)`,
  `.superseded(priorId:reason:)`, `.rejected(reason:)`.
- The actor-reentrancy guard: `priorTask.cancel(); _ = await priorTask.value`
  before reassigning `currentTurn`. Test OC3 specifically exercises this path
  with a controllable `MockLLMProvider` and asserts that after
  `cancelAndSubmit` returns, `currentTurn` never points at the cancelled turn.
- Per-turn `TurnNonce` (16 random bytes via `SecRandomCopyBytes`,
  base64url-encoded ≈ 22 chars) — passed to `ReplayLog.startTurn(turnNonce:)`
  and to `UntrustedWrapper(nonce:)` but never to any `OrchestratorEvent` case.
- `UntrustedWrapper.wrap(_:)` strips tag-like substrings (regex
  `</?UNTRUSTED_CONTENT[^>]*>`) BEFORE wrapping with paired
  `<UNTRUSTED_CONTENT id="<nonce>">…</UNTRUSTED_CONTENT id="<nonce>">` tags.
  Case-sensitivity is intentional and documented inline.
- `ToolResultPacker.pack(_:)` returns a `Packed` struct with the model-facing
  string capped at 8 KB (with truncation marker) plus the full bytes
  preserved for `ReplayEvent.toolResultFull(toolUseId:bytes:)`. The
  orchestrator wires both: capped text → wrapped → appended to messages;
  full bytes → ReplayLog channel.
- `ReplayLog` lifecycle: `startTurn(turnNonce:)` at turn entry,
  `record(.textDelta / .thinkingDelta / .toolCallRequested /
  .toolResultFull / .usage / .stopReason / .error)` per event, and
  `endTurn(_:stopReason:)` on every termination path (happy, retry-final,
  error, cancellation).
- AGENT-09 retry: bounded at 1; second `.streamTruncated` is terminal
  `.streamTruncatedFinal`. Retry opens a NEW turn id with `retryOf =
  originalTurnId`, re-reads `PerTurnSnapshot` (config can change
  mid-retry), and resets the tool-call budget.
- AGENT-07 cap-recovery: on `toolCallBudget == 0`, the next provider call
  passes `toolChoice: .none` AND `tools: []`. Test
  `OrchestratorCapRecoveryTests.test_capRecovery_OC2` asserts the recovery
  call's `toolChoice` equals `.none` — the AGENT-07 critical assertion.

## Architectural deviation (Rule 3 — blocking dep cycle)

The plan's `files_modified` placed every orchestrator file under
`packages/AgentCore/Sources/AgentCore/`. That layout is unbuildable: the
`Replay` package already depends on `AgentCore` (it imports `TurnID`), so
adding `Replay` to `AgentCore`'s dependencies (which the orchestrator
requires) would create an SPM cycle — and SPM rejects cycles at resolve
time.

**Resolution:** carved a new SPM target `AgentOrchestrator` inside the
`packages/AgentCore/` package, depending on both `AgentCore` and `Replay`.
The orchestrator-specific files now live under
`Sources/AgentOrchestrator/` and tests under
`Tests/AgentOrchestratorTests/`. The plan's intent (orchestrator ships with
the AgentCore package, depends on the LLMProvider protocol surface, no
extra repo) is preserved. Documented in `Package.swift` comment block.

## Auth gates and deviations

None. Pure offline TDD work — no API calls, no Keychain reads, no DB other
than per-test temporary `replay.db` files. All tests use `MockLLMProvider`
+ `StubToolDispatcher` + `TempReplayHome`.

## Self-Check: PASSED

Files exist:
- packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift  FOUND
- packages/AgentCore/Sources/AgentOrchestrator/OrchestratorEvent.swift  FOUND
- packages/AgentCore/Sources/AgentOrchestrator/SubmitOutcome.swift  FOUND
- packages/AgentCore/Sources/AgentCore/TurnNonce.swift  FOUND
- packages/AgentCore/Sources/AgentCore/UntrustedWrapper.swift  FOUND
- packages/AgentCore/Sources/AgentCore/ToolResultPacker.swift  FOUND
- packages/AgentCore/Sources/AgentCore/Base64URL.swift  FOUND
- packages/AgentCore/Tests/AgentCoreTests/TurnNonceTests.swift  FOUND
- packages/AgentCore/Tests/AgentCoreTests/UntrustedWrapperTests.swift  FOUND
- packages/AgentCore/Tests/AgentCoreTests/ToolResultPackerTests.swift  FOUND
- packages/AgentCore/Tests/AgentOrchestratorTests/MockLLMProvider.swift  FOUND
- packages/AgentCore/Tests/AgentOrchestratorTests/OrchestratorSubmitTests.swift  FOUND
- packages/AgentCore/Tests/AgentOrchestratorTests/OrchestratorCancelTests.swift  FOUND
- packages/AgentCore/Tests/AgentOrchestratorTests/OrchestratorRetryTests.swift  FOUND
- packages/AgentCore/Tests/AgentOrchestratorTests/OrchestratorCapRecoveryTests.swift  FOUND

Commits:
- 9c0de9f (Task 1, SEC-06 + AGENT-08 primitives)  FOUND
- 219532f (Task 2, AGENT-06 actor + submit/cancel)  FOUND
- 6c93c57 (Task 3, AGENT-07 + AGENT-09 test matrix)  FOUND

Verification gates:
- `swift test` (AgentCore): 114/114 green
- `swift test` (Replay): 25/25 green
- `swift test` (Bus): 47/47 green
- `swift build -c release` (AgentCore): clean
- SEC-06 grep gate (`turnNonce` in OrchestratorEvent.swift): 0 matches
- SEC-06 grep gate (`nonce` non-comment in OrchestratorEvent.swift): 0 matches
- AGENT-09 grep gate (`streamTruncatedFinal` in AgentOrchestrator.swift): 4 matches
- AGENT-06 grep gate (`await priorTask.value` in AgentOrchestrator.swift): 1 match
- AGENT-07 acceptance (cap-recovery toolChoice == .none): asserted by
  `OrchestratorCapRecoveryTests.test_capRecovery_OC2_recoveryCallToolChoiceIsNone`

## Known Stubs

`ToolDispatcher` is a protocol — concrete MCP-backed implementation lands
in Phase 5. P4 tests use `StubToolDispatcher` (closure-backed). The
orchestrator does not care which conforming type it receives; it only
relies on the `dispatch(toolUse:) async throws -> Data` contract.

`ConfirmationID` is a stub `RawRepresentable` wrapper. Real semantics
(timeout, scope, replay) are introduced in Plan 05 when MCP confirmations
are wired.

## Phase 4 Wave 4 readiness (Plan 04-05 inputs)

- `OrchestratorEvent` shape is stable. Plan 04-05's DevOverlay drains
  `orchestrator.events` and renders state transitions, token deltas, and
  toolCardUpdate cards.
- `ReplayLog` is stable. Plan 04-05's "last 5 tool calls" panel reads from
  the on-disk DB via the same query patterns Plan 04-03 unit-tested.
- The actor-reentrancy guard is implemented and tested. Plan 04-05's
  AppDelegate can wire `cancelAndSubmit` to the global hotkey safely.
