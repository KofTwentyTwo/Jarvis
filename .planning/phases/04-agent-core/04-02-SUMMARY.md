---
phase: 04-agent-core
plan: 02
subsystem: agent-core
tags: [llm-provider, ollama, ndjson, sse, tool-calling, agent-04, agent-07]
requirements-completed: [AGENT-04, AGENT-07]
dependency-graph:
  requires:
    - "04-01-LLMProvider protocol shape (LLMProvider, LLMEvent, ToolUseRequest, ToolChoice, ModelID)"
  provides:
    - "OllamaProvider actor — second LLMProvider conformance"
    - "NDJSONDecoder + OpenAICompatDecoder — Ollama wire-format state machines"
    - "OllamaRequestBody.encodeNative + .encodeOpenAICompat"
  affects:
    - "Plan 04-04 orchestrator can now select between AnthropicProvider and OllamaProvider via ProviderSelection"
tech-stack:
  added: []
  patterns:
    - "Hand-rolled URLSession streaming (no Ollama SDK dependency)"
    - "Per-decoder state machine, zero shared code with AnthropicProvider's SSEDecoder"
    - "tool_calls-on-sight invariant — never gate on terminator (AGENT-04)"
    - "drop-tools-array on .none — AGENT-07 cap-recovery wire-level invariant"
    - "Byte-replay fixture corpus mirroring Plan 04-01's SSE fixture pattern"
key-files:
  created:
    - packages/AgentCore/Sources/OllamaProvider/OllamaProvider.swift
    - packages/AgentCore/Sources/OllamaProvider/NDJSONDecoder.swift
    - packages/AgentCore/Sources/OllamaProvider/OpenAICompatDecoder.swift
    - packages/AgentCore/Sources/OllamaProvider/OllamaRequestBody.swift
    - packages/AgentCore/Tests/OllamaProviderTests/NDJSONDecoderTests.swift
    - packages/AgentCore/Tests/OllamaProviderTests/OpenAICompatDecoderTests.swift
    - packages/AgentCore/Tests/OllamaProviderTests/OllamaRequestBodyTests.swift
    - packages/AgentCore/Tests/OllamaProviderTests/FixtureReplayTests.swift
    - packages/AgentCore/Tests/OllamaProviderTests/Fixtures/happy-text.txt
    - packages/AgentCore/Tests/OllamaProviderTests/Fixtures/text-then-tool-call.txt
    - packages/AgentCore/Tests/OllamaProviderTests/Fixtures/parallel-tool-calls.txt
    - packages/AgentCore/Tests/OllamaProviderTests/Fixtures/mid-stream-eof.txt
    - packages/AgentCore/Tests/OllamaProviderTests/Fixtures/openai-compat-happy.txt
    - packages/AgentCore/Tests/OllamaProviderTests/Fixtures/openai-compat-tool-call.txt
  modified:
    - packages/AgentCore/Package.swift  # added resources: [.process("Fixtures")] to OllamaProviderTests
  deleted:
    - packages/AgentCore/Sources/OllamaProvider/Placeholder.swift  # replaced by real sources
    - packages/AgentCore/Tests/OllamaProviderTests/Placeholder.swift  # replaced by real tests
decisions:
  - "NDJSONDecoder emits .toolUseRequested on sight of tool_calls — never gates on done:true (AGENT-04 transport gotcha)"
  - "Ollama emits no tool_use ids on /api/chat; decoder synthesizes a fresh UUID per call. Orchestrator (Plan 04-04) maps back to tool_result by position"
  - "ToolChoice.none on the native path drops the tools array entirely from the request (AGENT-07 cap-recovery invariant)"
  - "ToolChoice.tool(name:) appends a best-effort system hint — Ollama has no first-class tool-choice.force"
  - "OpenAI-compat path is behind useOpenAICompat feature flag (default false). Keeps tools array even on .none and uses the OpenAI tool_choice string/object shape"
  - "Decoder state machines are siloed — zero shared code between NDJSONDecoder, OpenAICompatDecoder, and AnthropicProvider's SSEDecoder. Coupling lives only at LLMEvent shape"
  - "ModelID surface for Ollama is exclusively qwen2.5-coder:32b (RESEARCH-DELTAS D3) — no qwen3/qwen3.5/gemma4/llama4 constants in code"
  - "No partialToolUseAtDisconnect on the NDJSON path — each line is atomic JSON, so mid-stream EOF cannot leave a tool-args buffer half-built (Anthropic-only concept)"
metrics:
  duration: ~22 min
  tests-added: 33
  tests-total-package: 81
  files-created: 14
  files-modified: 1
  files-deleted: 2
  loc-production: 847
  loc-tests: 652
  completed: 2026-04-24
---

# Phase 4 Plan 02: Ollama Provider Summary

Hand-rolled `OllamaProvider` actor — the second `LLMProvider` conformance — covering both `/api/chat` NDJSON (default, with the AGENT-04 transport-gotcha invariant) and `/v1/chat/completions` SSE (behind the `useOpenAICompat` feature flag). Verifies AGENT-07 at the JSON-byte level: `ToolChoice.none` omits the `tools` array entirely on the native path so cap-recovery turns cannot loop.

## Outcome

- 81 / 81 tests pass in the AgentCore package (49 from Plan 04-01 + 33 net-new from this plan).
- Release build clean: `swift build -c release` exits 0.
- Phase 2 Bus regression: 47 / 47 still green.
- Zero new warnings introduced (the `Fixtures: File not found` warning during the in-progress build resolved as soon as the directory was populated in Task 3).
- All grep gates pass: `qwen3` count = 0 in OllamaProvider sources/tests; `done:`-gating-on-`tool_calls` count = 0 in NDJSONDecoder; `tool_calls` references ≥ 2; `OllamaProvider: LLMProvider` conformance present; `useOpenAICompat`, `application/x-ndjson`, `text/event-stream` all wired.

## What was built

### Task 1 — NDJSONDecoder + OllamaRequestBody (`feat 2323a6b`)

`NDJSONDecoder` parses Ollama's line-delimited JSON. The load-bearing invariant is the AGENT-04 tool-calls-on-sight rule: as soon as a chunk carries `message.tool_calls`, the decoder emits `.toolUseBuffering` + `.toolUseRequested` immediately. The terminator (`done:true`) chunk is decoupled from tool-use emission entirely. This mirrors the Ollama transport gotcha documented in CLAUDE.md: `tool_calls` arrives on the chunk *preceding* `done:true`, not with it.

Each tool call gets a fresh UUID id (Ollama emits no ids on `/api/chat`). Orchestrator (Plan 04-04) maps back to `tool_result` by position when the user-side message is constructed.

`done_reason` mapping: `"stop"` → `.endTurn` (or `.toolUse` if calls were seen mid-stream), `"length"` → `.maxTokens`, `"tool_calls"` → `.toolUse`, missing → derive from `sawToolCalls`.

`OllamaRequestBody.encodeNative` enforces the AGENT-07 invariant: `ToolChoice.none` produces a body with NO `tools` key at all — verified by parsing the output back to `[String: Any]` and asserting `dict["tools"] == nil`. `.tool(name:)` appends a synthetic `"Please use the X tool."` system message at the end of the conversation as a best-effort hint (Ollama has no first-class `tool_choice.force`).

19 tests for this task: 10 NDJSONDecoder + 9 OllamaRequestBody.

### Task 2 — OllamaProvider + OpenAICompatDecoder (`feat cbc5efc`)

`OllamaProvider` actor branches on `useOpenAICompat`:
- `false` (default): POST to `/api/chat` with `Accept: application/x-ndjson`, drive `NDJSONDecoder` via `URLSession.AsyncBytes.lines`.
- `true`: POST to `/v1/chat/completions` with `Accept: text/event-stream`, drive `OpenAICompatDecoder`.

`OpenAICompatDecoder` is a distinct state machine. Tool calls arrive atomically (`choices[0].delta.tool_calls` is a complete object, not split across deltas like Anthropic). `arguments` may be a JSON-encoded string (OpenAI convention) or an object (Ollama's compat layer); the decoder accepts both. Terminator is the literal `data: [DONE]` sentinel; mid-stream EOF emits `.stopReason(.streamTruncated)`.

Non-2xx responses surface `LLMProviderError.api(statusCode:body:)` with a 64 KiB-capped body buffer to bound information disclosure (T-04-02-02).

8 tests for OpenAICompatDecoder + 1 conformance compile check.

### Task 3 — Byte-replay fixture corpus (`test 77d78bb`)

Six on-disk fixtures driving `FixtureReplayTests`:
- `happy-text.txt` (NDJSON, 4 chunks, plain text)
- `text-then-tool-call.txt` — **AGENT-04 fixture-level regression guard**: `tool_calls` lives on a `done:false` chunk, terminator is on the next chunk. Asserts `toolUseRequested` index < `stopReason` index after replaying disk bytes. Defence in depth alongside `NDJSONDecoderTests.testToolCallsOnNonTerminatorChunk_AGENT04` — a developer who "fixed" the inline test by editing string literals would still trip this fixture.
- `parallel-tool-calls.txt` — two `tool_calls` in one chunk
- `mid-stream-eof.txt` — no terminator (truncated)
- `openai-compat-happy.txt` — SSE with `[DONE]`
- `openai-compat-tool-call.txt` — SSE with atomic tool_call + stringified arguments

6 fixture-replay tests, all green.

## Deviations from Plan

None — plan executed as written. Two minor mechanical notes:

1. The `Fixtures` directory had to exist (containing at least a `.gitkeep`) for SwiftPM to satisfy the `resources: [.process("Fixtures")]` declaration during Task 1. Added `.gitkeep` in the Task 1 commit and removed it in the Task 3 commit once the real fixtures landed. This is purely a SwiftPM build-system artifact; not a plan deviation.
2. Plan text mentioned hoisting `ExpectedEvent` to a shared test helper. Inlined a slightly different reduced enum in `FixtureReplayTests.swift` because the per-test assertions differ (e.g., the AGENT-04 fixture test asserts an index ordering, not a flat shape match). The plan explicitly allowed inline duplication for ~10-line enums.

## Authentication gates

None — Ollama is loopback-only and has no auth.

## Known stubs

None in this plan's surface area. Forward-looking notes for downstream plans:
- The orchestrator's tool dispatcher loop is Plan 04-04's concern; this plan delivers wire-format conformance only.
- The `ProviderSelection` toggle that fans out between `AnthropicProvider` and `OllamaProvider` lives in Plan 04-04.
- `OllamaConfig` (Phase 1) already validates `baseURL.host ∈ {127.0.0.1, localhost, ::1}` per AGENT-05; this provider trusts the URL through.

## Phase 4 Wave 3 readiness

With both `AnthropicProvider` (Plan 04-01) and `OllamaProvider` (Plan 04-02) green:
- The `LLMProvider` protocol is exercised by two real implementations — orchestrator can be written purely against the protocol.
- AGENT-04 (Ollama tool_calls correctness) and AGENT-07 (mandatory tool_choice on every turn, with `.none` cap-recovery semantics) are both pinned at the wire level on both providers.
- Plan 04-03 (Replay log) ran in parallel; assuming it lands cleanly, Plan 04-04 (orchestrator) has all its inputs.

## Self-Check: PASSED

Files created (all 14):
- packages/AgentCore/Sources/OllamaProvider/OllamaProvider.swift — FOUND
- packages/AgentCore/Sources/OllamaProvider/NDJSONDecoder.swift — FOUND
- packages/AgentCore/Sources/OllamaProvider/OpenAICompatDecoder.swift — FOUND
- packages/AgentCore/Sources/OllamaProvider/OllamaRequestBody.swift — FOUND
- packages/AgentCore/Tests/OllamaProviderTests/NDJSONDecoderTests.swift — FOUND
- packages/AgentCore/Tests/OllamaProviderTests/OpenAICompatDecoderTests.swift — FOUND
- packages/AgentCore/Tests/OllamaProviderTests/OllamaRequestBodyTests.swift — FOUND
- packages/AgentCore/Tests/OllamaProviderTests/FixtureReplayTests.swift — FOUND
- packages/AgentCore/Tests/OllamaProviderTests/Fixtures/happy-text.txt — FOUND
- packages/AgentCore/Tests/OllamaProviderTests/Fixtures/text-then-tool-call.txt — FOUND
- packages/AgentCore/Tests/OllamaProviderTests/Fixtures/parallel-tool-calls.txt — FOUND
- packages/AgentCore/Tests/OllamaProviderTests/Fixtures/mid-stream-eof.txt — FOUND
- packages/AgentCore/Tests/OllamaProviderTests/Fixtures/openai-compat-happy.txt — FOUND
- packages/AgentCore/Tests/OllamaProviderTests/Fixtures/openai-compat-tool-call.txt — FOUND

Commits:
- 2323a6b — FOUND
- cbc5efc — FOUND
- 77d78bb — FOUND
