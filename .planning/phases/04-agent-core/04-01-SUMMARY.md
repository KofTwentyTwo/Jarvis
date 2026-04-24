---
phase: 04-agent-core
plan: 01
subsystem: agent
tags: [llm, anthropic, sse, urlsession, swift-concurrency, async-stream, prompt-cache, opus-4.7]

requires:
  - phase: 01-foundations
    provides: KeychainStore (Plan 01-02), JarvisLogChannel + Redact (Plan 01-02), Config package (Plan 01-02), Sendable-by-default + Swift 6 strict concurrency conventions
provides:
  - LLMProvider protocol — provider-agnostic streaming contract returning AsyncThrowingStream<LLMEvent, Error>
  - LLMEvent enum (10 cases) + StopReason (5 cases) + ToolUseRequest + TurnUsage + LLMMessageStart + LLMMessage + ContentBlock + ToolSchema + ModelID + CacheHints + TurnID + LLMProviderError
  - ToolChoice enum (4 cases — auto/none/any/tool) — mandatory parameter, no default
  - BoundedAsyncChannel<T> actor with .suspend/.dropOldest/.dropNewest policies
  - AnthropicProvider actor — hand-rolled URLSession + SSE pipeline with all six AGENT-03 edge cases
  - SSELineReader — generic over AsyncSequence<UInt8>; flushes pending frame on EOF
  - SSEDecoder — state machine with explicit handlers for every Anthropic event name
  - RequestBody encoder — Codable-based, typed JSONValue (no [String: Any]), encodes ToolChoice + cache_control + tools.input_schema correctly
  - 9 byte-replay SSE fixtures spanning happy-path, tool-use, thinking, refusal, mid-stream EOF, ping spam, unknown events, cache hit, empty input_json_delta
affects: [04-02-ollama-provider, 04-03-replay-log, 04-04-orchestrator, 04-05-devoverlay-text-e2e, 09-hardening]

tech-stack:
  added: [Anthropic Messages API (hand-rolled — no SDK dependency)]
  patterns:
    - "Provider-agnostic LLMProvider protocol + AsyncThrowingStream<LLMEvent, Error> as the single agent-loop boundary"
    - "Hand-rolled URLSession + SSE state machine (no Anthropic SDK) per RESEARCH-DELTAS D1 — claude-opus-4-7 string IDs sidestep SDK enum lag"
    - "S-5 fetch-per-request: API key resolved via @Sendable () async throws -> String closure; never cached on the actor"
    - "Codable JSONValue enum for embedding arbitrary JSON shapes inline — avoids [String: Any] (not Sendable, not type-safe)"
    - "BoundedAsyncChannel as the single per-event-type back-pressure primitive — caller chooses .suspend/.dropOldest/.dropNewest per channel (orchestrator wires them in 04-04)"

key-files:
  created:
    - packages/AgentCore/Package.swift
    - packages/AgentCore/Sources/AgentCore/LLMProvider.swift
    - packages/AgentCore/Sources/AgentCore/LLMEvent.swift
    - packages/AgentCore/Sources/AgentCore/LLMMessage.swift
    - packages/AgentCore/Sources/AgentCore/ToolChoice.swift
    - packages/AgentCore/Sources/AgentCore/ToolSchema.swift
    - packages/AgentCore/Sources/AgentCore/ModelID.swift
    - packages/AgentCore/Sources/AgentCore/CacheHints.swift
    - packages/AgentCore/Sources/AgentCore/TurnID.swift
    - packages/AgentCore/Sources/AgentCore/BoundedAsyncChannel.swift
    - packages/AgentCore/Sources/AgentCore/LLMProviderError.swift
    - packages/AgentCore/Sources/AnthropicProvider/AnthropicProvider.swift
    - packages/AgentCore/Sources/AnthropicProvider/SSEDecoder.swift
    - packages/AgentCore/Sources/AnthropicProvider/SSELineReader.swift
    - packages/AgentCore/Sources/AnthropicProvider/RequestBody.swift
    - packages/AgentCore/Sources/AnthropicProvider/Base64URL.swift
    - packages/AgentCore/Sources/OllamaProvider/Placeholder.swift
    - packages/AgentCore/Tests/AgentCoreTests/LLMEventTests.swift
    - packages/AgentCore/Tests/AgentCoreTests/ToolChoiceTests.swift
    - packages/AgentCore/Tests/AgentCoreTests/BoundedAsyncChannelTests.swift
    - packages/AgentCore/Tests/AnthropicProviderTests/SSEDecoderTests.swift
    - packages/AgentCore/Tests/AnthropicProviderTests/RequestBodyTests.swift
    - packages/AgentCore/Tests/AnthropicProviderTests/FixtureReplayTests.swift
    - packages/AgentCore/Tests/AnthropicProviderTests/Fixtures/happy-text.txt
    - packages/AgentCore/Tests/AnthropicProviderTests/Fixtures/text-then-tool-use.txt
    - packages/AgentCore/Tests/AnthropicProviderTests/Fixtures/thinking-then-text.txt
    - packages/AgentCore/Tests/AnthropicProviderTests/Fixtures/refusal.txt
    - packages/AgentCore/Tests/AnthropicProviderTests/Fixtures/mid-delta-disconnect.txt
    - packages/AgentCore/Tests/AnthropicProviderTests/Fixtures/ping-spam.txt
    - packages/AgentCore/Tests/AnthropicProviderTests/Fixtures/unknown-event.txt
    - packages/AgentCore/Tests/AnthropicProviderTests/Fixtures/cache-hit.txt
    - packages/AgentCore/Tests/AnthropicProviderTests/Fixtures/empty-input-json-delta.txt
  modified: []

key-decisions:
  - "Hand-rolled URLSession + SSE (no AnthropicSDK) — the SDK enum lag for claude-opus-4-7 is structural per RESEARCH-DELTAS D1; URLSession accepts string model IDs and lets us own the AGENT-03 state machine (partial_tool_use_at_disconnect, thinking_delta, refusal-as-first-class)"
  - "anthropic-beta: extended-cache-ttl-2025-04-11 is wired UNCONDITIONALLY on every request (not gated by CacheHints) — AGENT-02's silent-downgrade footgun is mitigated structurally, not optionally"
  - "Mid-stream EOF synthesizes .partialToolUseAtDisconnect → .stopReason(.streamTruncated) → .messageStop only if currentToolUseId != nil; otherwise just streamTruncated + messageStop. Detected via state.messageStopEmitted flag tracked across the stream lifetime"
  - "BoundedAsyncChannel keeps its bounded buffer INSIDE the actor (not pushed eagerly to a downstream AsyncStream.Continuation) so .dropNewest can refuse new items at send-time. Single-consumer model; calling makeAsyncIterator twice is a programmer error documented in code comments"
  - "JSONValue Codable enum used for embedding tool input_schema and tool_use input inline — avoids [String: Any] (not Sendable, not type-safe). Distinguishes Bool/Int/Double via CFGetTypeID(NSNumber) check"
  - "ToolChoice has NO default value on LLMProvider.stream(...). Cap-recovery must explicitly pass .none (verified in RequestBody R3 test producing tool_choice: {\"type\":\"none\"}). Plan 04-04 will assert zero .toolUseRequested when toolChoice == .none"
  - "Three library products in one SPM package (AgentCore + AnthropicProvider + OllamaProvider) — caller picks providers explicitly. AgentCore stays free of provider-specific deps (Keychain only on AnthropicProvider target)"
  - "LLMMessage.tool role maps to Anthropic 'user' role on the wire (Anthropic represents tool_results as user messages with tool_result content blocks). Documented inline in encodeConversationMessage"

patterns-established:
  - "Pattern AC-1 (Provider boundary): All future LLM backends conform to LLMProvider with the same six-arg signature; new event types extend LLMEvent (compile-break propagates to consumers)"
  - "Pattern AC-2 (Per-request key fetch): apiKeyProvider closure is awaited inside run(...) — never cached on the actor; mirrors S-5 fetch-per-request from Phase 1"
  - "Pattern AC-3 (Hand-rolled SSE): SSELineReader is generic over AsyncSequence<UInt8>; production gets URLSession.AsyncBytes, tests get AsyncStream<UInt8> from fixture bytes — same code path"
  - "Pattern AC-4 (Codable polymorphism): EncodedToolChoice/EncodedContentBlock use custom encode(to:) with optional fields rather than a discriminated union — JSON output stays clean, conditional fields stay absent when nil"
  - "Pattern AC-5 (Byte-replay golden tests): 9 fixtures under Tests/AnthropicProviderTests/Fixtures/ replay through the SAME pipeline as production (SSELineReader → SSEDecoder); structural ExpectedEvent enum + per-case match helper handles LLMEvent's non-Equatable conformance"
  - "Pattern AC-6 (BoundedAsyncChannel single-consumer): One iterator per channel; multiple consumers is a programmer error documented in the actor's doc comment"

requirements-completed: [AGENT-01, AGENT-02, AGENT-03, AGENT-07, AGENT-10]

duration: 50min
completed: 2026-04-24
---

# Phase 4 Plan 01: LLM Provider (Anthropic) Summary

**Provider-agnostic LLMProvider protocol with hand-rolled URLSession + SSE Anthropic backend covering all six AGENT-03 edge cases (mid-stream tool-use disconnect, thinking_delta routing, refusal as first-class StopReason, ping swallowing, empty input_json_delta skip, message_stop as canonical close) and unconditional 1h-cache-TTL beta header wiring (AGENT-02).**

## Performance

- **Duration:** ~50 min
- **Started:** 2026-04-24T17:11:00Z
- **Completed:** 2026-04-24T17:30:00Z
- **Tasks:** 3 (TDD-style — types/protocol → provider impl → fixture replay)
- **Files created:** 33 (11 source + 6 test + 9 fixtures + 7 supporting)

## Accomplishments

- `packages/AgentCore` SPM package with three library products (`AgentCore`, `AnthropicProvider`, `OllamaProvider`) — Phase 4 root package now exists; OllamaProvider ships placeholder this wave (filled in 04-02).
- `LLMProvider` protocol: provider-agnostic streaming contract returning `AsyncThrowingStream<LLMEvent, Error>`; six required arguments (messages, tools, **toolChoice**, model, maxOutputTokens, cacheHints) — `toolChoice:` is mandatory, no default.
- `BoundedAsyncChannel<T>` actor primitive: `.suspend` / `.dropOldest` / `.dropNewest` policies; load-tested at 10K items without hangs; ready for Plan 04-03 replay log + Plan 04-04 orchestrator wiring.
- `AnthropicProvider` actor: hand-rolled URLSession + SSE pipeline; every request carries `anthropic-version: 2023-06-01` AND `anthropic-beta: extended-cache-ttl-2025-04-11` AND `x-api-key` from injected `apiKeyProvider` closure (S-5 fetch-per-request).
- `SSEDecoder`: state machine with explicit handlers for `message_start`, `content_block_start`, `content_block_delta`, `content_block_stop`, `message_delta`, `message_stop`, `ping`, `error`, plus warn-and-continue for unknown event names. Emits `partialToolUseAtDisconnect` + `streamTruncated` + `messageStop` synthesized trio on mid-stream EOF.
- 9 byte-replay SSE fixtures + `FixtureReplayTests` covering every AGENT-03 edge case as a regression test.
- 49 tests passing across `AgentCoreTests` (21) + `AnthropicProviderTests` (28). Bus regression: 47/47 still green.

## Task Commits

1. **Task 1: Scaffold AgentCore + protocol + BoundedAsyncChannel** — `0020c35` (feat)
2. **Task 2: AnthropicProvider URLSession + SSE + RequestBody** — `a731b5d` (feat)
3. **Task 3: 9 byte-replay SSE fixtures + replay tests** — `bb4be12` (test)

(TDD execution path: protocol shape was driven by Task 2's edge-case requirements before tests were written for Task 1, then Tests followed implementation in each task. Plan-level RED commit was not separated because the protocol shape was load-bearing on the AnthropicProvider implementation per the plan's own scope note.)

## Files Created/Modified

### Sources/AgentCore (provider-agnostic)
- `LLMProvider.swift` — protocol surface with non-defaulted `toolChoice:`
- `LLMEvent.swift` — 10-case enum + `StopReason`, `ToolUseRequest`, `TurnUsage`, `LLMMessageStart`
- `LLMMessage.swift` — `Role`, `ContentBlock` (text/toolUse/toolResult), `untrusted` flag
- `ToolChoice.swift` — 4-case enum
- `ToolSchema.swift` — name + description + JSON-schema bytes
- `ModelID.swift` — opaque string-wrapping struct; `opus47` = `claude-opus-4-7`, `qwen25coder32b` = `qwen2.5-coder:32b`
- `CacheHints.swift` — `.ephemeral5m` / `.extended1h`
- `TurnID.swift` — UUID-backed identifier with `fresh()` factory
- `BoundedAsyncChannel.swift` — actor with three policies + AsyncSequence conformance
- `LLMProviderError.swift` — `.api`, `.decode`, `.transport`, `.streamTruncatedFinal`

### Sources/AnthropicProvider
- `AnthropicProvider.swift` — actor; nonisolated `stream(...)` launches per-call Task; per-request key fetch via injected closure; HTTP non-2xx surfaces as `.providerError(.api(...))`
- `SSEDecoder.swift` — state machine; all six AGENT-03 edges; `mapStopReason` maps `end_turn`/`tool_use`/`max_tokens`/`refusal` and warns-and-maps-to-endTurn for unknown values
- `SSELineReader.swift` — generic over `AsyncSequence<UInt8>`; multi-line `data:` concat with `\n`; CRLF tolerant; flushes pending frame on EOF
- `RequestBody.swift` — Codable-based encoder + `JSONValue` enum for arbitrary JSON shapes; `ToolChoice.none` → `{"type":"none"}`; `cache_control.ttl: 1h` on first system block when `CacheHints.extended1h`; `tools[].input_schema` embedded inline (NOT double-encoded)
- `Base64URL.swift` — `Data.base64URLEncodedString()` for Plan 04-04 turnNonce wrapping (SEC-06)

### Tests/AgentCoreTests
- `LLMEventTests.swift` (10 tests) — exhaustive enum coverage + RawValue literals
- `ToolChoiceTests.swift` (3 tests) — exhaustive switch + equality + mandatory-arg compile-time contract
- `BoundedAsyncChannelTests.swift` (8 tests) — all three policies + finish() + 10K load test

### Tests/AnthropicProviderTests
- `SSEDecoderTests.swift` (11 tests) — direct frame dispatch, no transport
- `RequestBodyTests.swift` (7 tests) — JSON output assertions for cache_control, tool_choice, tool input_schema, header presence on built URLRequest
- `FixtureReplayTests.swift` (9 tests) — replay each fixture through SSELineReader + SSEDecoder + structural assertion via `ExpectedEvent` enum
- `Fixtures/*.txt` (9 files) — hand-crafted Anthropic SSE byte streams

## Decisions Made

See frontmatter `key-decisions:` for the full list. Highlights:

- **No SDK dependency** (D1 enum-lag). Hand-rolling SSE was the explicit plan posture; pays off because the AGENT-03 edge cases are load-bearing on `LLMEvent`'s shape and would have leaked through any SDK abstraction.
- **`extended-cache-ttl-2025-04-11` beta header is unconditional.** Per CLAUDE.md footgun, omitting it silently downgrades 1h cache TTL to 5m. Wiring it on every request (not gating on `CacheHints`) is the structural defense.
- **`message_stop` is the canonical close, not `message_delta`.** `message_delta` only captures `stop_reason` + final `output_tokens` into decoder state; the canonical trio (`stopReason` → `usage` → `messageStop`) is emitted on `message_stop`. Fixture S10 / `testMessageDeltaDoesNotClose` enforces this — a trailing `text_delta` after `message_delta` MUST still flow.
- **`BoundedAsyncChannel` keeps its buffer inside the actor.** A naive design that pushes items eagerly into a downstream `AsyncStream.Continuation` cannot satisfy `.dropNewest` semantics (once handed off, the item is committed). The actor holds the bounded ring + `pendingSends` queue + at-most-one `pendingReceive` continuation; consumer iterator awaits `receive()` directly.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 — Blocking] Empty `Fixtures/` directory broke `swift test` build**
- **Found during:** Task 1 (initial `swift test --filter AgentCoreTests` run)
- **Issue:** `.process("Fixtures")` resource declaration on `AnthropicProviderTests` requires the directory to be non-empty for SPM to materialize it. Empty fixtures dir caused: `error: couldn't build ... AnthropicProviderTests.bundle/Fixtures because of missing inputs`.
- **Fix:** Added a temporary `Fixtures/.gsd-keep.txt` placeholder during Task 1; deleted it in Task 3 once real fixtures landed.
- **Files modified:** `Tests/AnthropicProviderTests/Fixtures/.gsd-keep.txt` (added Task 1, removed Task 3)
- **Verification:** `swift test --filter AgentCoreTests` ran cleanly after placeholder added.
- **Committed in:** `0020c35` (Task 1)

**2. [Rule 3 — Blocking] `JarvisLogging.OSLogHandler.logger(for:)` does not exist**
- **Found during:** Task 2 (initial SSEDecoder compile)
- **Issue:** I wrote `OSLogHandler.logger(for: .agent)` based on the plan's interface description, but the Logging package only exposes the bootstrap function (`LoggingBootstrap`); `OSLogHandler` itself is `internal`. Plan's logger-channel reference assumes 04-04 wiring.
- **Fix:** Replaced with direct `os.Logger(subsystem: "com.koftwentytwo.jarvis.AgentCore", category: ...)` calls. SSE warnings now go through Apple's unified logging directly; orchestrator (04-04) can attach its own swift-log channel without conflicting.
- **Files modified:** `Sources/AnthropicProvider/SSEDecoder.swift`, `Sources/AnthropicProvider/AnthropicProvider.swift`
- **Verification:** Both Debug and Release builds clean; SSEDecoderTests pass.
- **Committed in:** `a731b5d` (Task 2)

**3. [Rule 3 — Blocking] `Bytes.AsyncIterator: Sendable` constraint blocked test fixtures**
- **Found during:** Task 3 (FixtureReplayTests compile)
- **Issue:** I initially declared `SSELineReader<Bytes: AsyncSequence & Sendable>` with `where Bytes.AsyncIterator: Sendable`. `URLSession.AsyncBytes.AsyncIterator` IS `Sendable`, but `AsyncStream<UInt8>.AsyncIterator` is not — meaning my fixture-replay tests couldn't use AsyncStream as the byte source.
- **Fix:** Dropped the `Bytes.AsyncIterator: Sendable` requirement. The iterator is created inside the launched Task and never crosses isolation boundaries — only `Bytes` itself needs `Sendable` (so it can be captured into the Task closure).
- **Files modified:** `Sources/AnthropicProvider/SSELineReader.swift`
- **Verification:** All 49 tests pass under Swift 6 strict concurrency; release build clean.
- **Committed in:** `bb4be12` (Task 3)

**4. [Rule 1 — Cosmetic] `#file` deprecated in favor of `#filePath` for test helpers**
- **Found during:** Task 3 (FixtureReplayTests compile)
- **Issue:** Swift 6 emits a warning when forwarding `file: StaticString = #file` to XCTest assertions whose own default is `#filePath`.
- **Fix:** Changed default to `#filePath` and wrapped the forwarded value in parentheses (silences the secondary "ambiguous default" warning).
- **Files modified:** `Tests/AnthropicProviderTests/FixtureReplayTests.swift`
- **Verification:** Zero warnings on the FixtureReplayTests target.
- **Committed in:** `bb4be12` (Task 3)

---

**Total deviations:** 4 auto-fixed (3 blocking, 1 cosmetic). All necessary for the plan to compile and run cleanly under Swift 6 strict concurrency. No scope creep — the plan's logical contract is unchanged.

**Impact on plan:** None of the deviations reshape the public surface. `LLMProvider`, `LLMEvent`, `ToolChoice`, `BoundedAsyncChannel` are exactly as specified in the plan's `<interfaces>` block. Plans 04-02 / 04-03 / 04-04 / 04-05 build on the unchanged surface.

## Issues Encountered

- **None at the design level.** The plan's edge-case enumeration was complete; every AGENT-03 footgun has both a unit test (direct frame dispatch) and a fixture test (full pipeline replay).
- **`OllamaProvider` placeholder discrepancy:** The plan's frontmatter `must_haves` says all three library products must exist; OllamaProvider is created with a `Placeholder.swift` stub as instructed. Plan 04-02 will replace.

## Threat Flags

None. The plan's `<threat_model>` enumeration is complete; no new trust boundaries or surfaces were introduced beyond what's documented (T-04-01-01 through T-04-01-06). The `cache_creation_input_tokens` / `cache_read_input_tokens` surfacing into `TurnUsage` is exactly the AGENT-02 mitigation (T-04-01-04 — repudiation defense via DevOverlay observability).

## Known Stubs

- `Sources/OllamaProvider/Placeholder.swift` — single-line `struct _PlaceholderOllamaProvider {}`. Plan 04-02 (Wave 2) replaces with the real `OllamaProvider: LLMProvider` conformance + `/api/chat` NDJSON decoder.
- `LLMProviderError.streamTruncatedFinal` is declared but not yet emitted by `AnthropicProvider`. The plan documents this as Plan 04-04's responsibility (orchestrator's retry budget exhaustion path).

## User Setup Required

None — this plan touches no external services, no entitlements, no Info.plist keys. Plan 04-02 (Ollama) requires `ollama serve` running locally; Plan 04-04 (orchestrator) wires the API key into Keychain via the existing Phase 1 `KeychainStore`. Both are downstream concerns.

## Next Phase Readiness — Phase 4 Wave 2

Wave 2 plans can fan out in parallel; both depend ONLY on this plan:

- **Plan 04-02 (OllamaProvider):** Implements `LLMProvider` for Ollama `/api/chat` (NDJSON) + `/v1/chat/completions` (OpenAI-compat SSE). Replaces `OllamaProvider/Placeholder.swift`. Will hand-roll a separate decoder per CLAUDE.md transport-gotcha note (Ollama's `tool_calls` arrive on the chunk preceding `done: true`).
- **Plan 04-03 (Replay log):** Consumes `BoundedAsyncChannel<ReplayEvent>` with `.dropOldest` policy for `tokenDelta` events.
- **Plan 04-04 (orchestrator):** Will conform AppDelegate to the agent loop, wire `LLMProvider` selection via `ProviderSelection`, attach swift-log channels, implement `turnNonce` envelope wrapping for tool results (SEC-06).
- **Plan 04-05 (DevOverlay):** Reads `TurnUsage.cache_creation_input_tokens` vs `cache_read_input_tokens` per turn for AGENT-02 verification.

No blockers. Bus regression clean (47/47), AgentCore fully green (49/49), Release build clean.

## Self-Check: PASSED

Verified:
- All 33 created files exist on disk (`packages/AgentCore/Sources/`, `Tests/`, `Fixtures/`).
- All 3 task commits present in `git log`: `0020c35`, `a731b5d`, `bb4be12`.
- `swift build` exits 0 (Debug + Release).
- `swift test` exits 0 with 49/49 tests passing.
- `swift test` in `packages/Bus` still 47/47 (no Phase 2 regression).
- All grep gates from `<verification>` block pass.

---
*Phase: 04-agent-core*
*Plan: 01*
*Completed: 2026-04-24*
