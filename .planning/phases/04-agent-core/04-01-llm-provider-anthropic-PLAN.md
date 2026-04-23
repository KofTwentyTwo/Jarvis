---
phase: 04-agent-core
plan: 01
type: execute
wave: 1
depends_on: []
files_modified:
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
autonomous: true
requirements: [AGENT-01, AGENT-02, AGENT-03, AGENT-07, AGENT-10]
must_haves:
  truths:
    - "packages/AgentCore exists as a new SPM package with three internal library products (AgentCore, AnthropicProvider, OllamaProvider) — OllamaProvider ships empty in Wave 1 (filled in Plan 04-02)"
    - "LLMProvider.stream(messages:tools:toolChoice:model:maxOutputTokens:cacheHints:) is a non-defaulted protocol method returning AsyncThrowingStream<LLMEvent, Error>"
    - "ToolChoice has exactly four cases: .auto, .none, .any, .tool(name:) — all Sendable, Equatable"
    - "toolChoice parameter is MANDATORY (not defaulted); a compile-time test confirms omitting it fails to compile"
    - "ModelID.opus47 rawValue equals the literal string 'claude-opus-4-7' (per RESEARCH-DELTAS D1)"
    - "AnthropicProvider sends every request with two headers: 'anthropic-version: 2023-06-01' AND 'anthropic-beta: extended-cache-ttl-2025-04-11' (AGENT-02)"
    - "AnthropicProvider request JSON includes cache_control.ttl = '1h' on system prompt block when CacheHints.systemPromptTTL == .extended1h (AGENT-02)"
    - "SSEDecoder closes stream on 'message_stop' event — NOT on 'message_delta' (AGENT-03)"
    - "SSEDecoder swallows 'ping' events — emits zero LLMEvents for a ping-only stream (AGENT-03)"
    - "SSEDecoder emits .thinkingDelta(String) for content_block_delta where delta.type == 'thinking_delta' (AGENT-03)"
    - "SSEDecoder maps stop_reason 'refusal' to StopReason.refusal (first-class, not a warning) (AGENT-03)"
    - "SSEDecoder assembles tool args JSON across multiple input_json_delta events and emits ONE .toolUseRequested on content_block_stop with completed buffer (AGENT-03)"
    - "SSEDecoder skips empty-string input_json_delta chunks (never appends '')"
    - "SSEDecoder on mid-stream EOF mid-tool-args emits .partialToolUseAtDisconnect(request) then .stopReason(.streamTruncated) then .messageStop (AGENT-03)"
    - "Fixture replay suite covers 9 byte-stream fixtures: happy-text, text-then-tool-use, thinking-then-text, refusal, mid-delta-disconnect, ping-spam, unknown-event, cache-hit, empty-input-json-delta"
    - "RequestBody serializes .none ToolChoice as {\"type\":\"none\"} on tool_choice field (AGENT-07)"
    - "BoundedAsyncChannel<T: Sendable> actor supports three policies: .suspend, .dropOldest, .dropNewest (AGENT-10)"
    - "BoundedAsyncChannel conforms to AsyncSequence and is Sendable"
  artifacts:
    - path: "packages/AgentCore/Package.swift"
      provides: "SPM manifest for AgentCore package with three library products"
      contains: "AgentCore"
    - path: "packages/AgentCore/Sources/AgentCore/LLMProvider.swift"
      provides: "LLMProvider protocol — the provider-agnostic streaming contract"
      contains: "LLMProvider"
    - path: "packages/AgentCore/Sources/AgentCore/LLMEvent.swift"
      provides: "LLMEvent enum with all nine cases; StopReason enum; ToolUseRequest + TurnUsage"
      contains: "partialToolUseAtDisconnect"
    - path: "packages/AgentCore/Sources/AgentCore/ToolChoice.swift"
      provides: "ToolChoice enum — mandatory argument on LLMProvider.stream"
      contains: "case `none`"
    - path: "packages/AgentCore/Sources/AgentCore/BoundedAsyncChannel.swift"
      provides: "BoundedAsyncChannel actor with suspend / dropOldest / dropNewest policies (AGENT-10)"
      contains: "Policy"
    - path: "packages/AgentCore/Sources/AnthropicProvider/AnthropicProvider.swift"
      provides: "URLSession + SSE Anthropic provider; 1h cache TTL header + cache_control wiring"
      contains: "extended-cache-ttl-2025-04-11"
    - path: "packages/AgentCore/Sources/AnthropicProvider/SSEDecoder.swift"
      provides: "Hand-rolled Anthropic SSE state machine covering all six AGENT-03 edges"
      contains: "message_stop"
  key_links:
    - from: "packages/AgentCore/Sources/AnthropicProvider/AnthropicProvider.swift"
      to: "packages/AgentCore/Sources/AgentCore/LLMProvider.swift"
      via: "actor AnthropicProvider: LLMProvider conformance"
      pattern: "AnthropicProvider: LLMProvider"
    - from: "packages/AgentCore/Sources/AnthropicProvider/RequestBody.swift"
      to: "packages/AgentCore/Sources/AgentCore/ToolChoice.swift"
      via: "encodeToolChoice function; .none produces {\"type\":\"none\"}"
      pattern: "\"type\":\"none\""
    - from: "packages/AgentCore/Sources/AnthropicProvider/AnthropicProvider.swift"
      to: "packages/Keychain/Sources/Keychain/KeychainStore.swift"
      via: "@Sendable () async throws -> String closure reads x-api-key per request"
      pattern: "KeychainStore"
    - from: "packages/AgentCore/Sources/AnthropicProvider/SSEDecoder.swift"
      to: "packages/AgentCore/Sources/AgentCore/LLMEvent.swift"
      via: "dispatch(line:) → yields LLMEvent cases into AsyncThrowingStream continuation"
      pattern: "continuation\\.yield"
---

<objective>
Establish the `packages/AgentCore` SPM package — the home of the provider-agnostic streaming agent loop — by delivering (a) the `LLMProvider` protocol surface + `LLMEvent` enum + `ToolChoice` + `ModelID` + `CacheHints` + `BoundedAsyncChannel` primitive, and (b) the first concrete provider: `AnthropicProvider` (URLSession + hand-rolled SSE). This is the critical foundation for Phase 4; both the Ollama provider (Plan 04-02) and the orchestrator (Plan 04-04) conform to and consume this contract.

Purpose: The whole phase is a protocol-first build per research §1. The protocol shape **must** land before anything consumes it. AnthropicProvider is paired with the protocol in the same plan (rather than split into a Wave-0 scaffold + Wave-1 impl) because the SSE edge cases in AGENT-03 are load-bearing for the protocol shape — specifically, `.partialToolUseAtDisconnect` and `.thinkingDelta` cases exist in `LLMEvent` only because the Anthropic decoder needs them. Designing the enum in isolation from its first consumer invites shape drift.

Output: A buildable `packages/AgentCore` with three library products (`AgentCore`, `AnthropicProvider`, `OllamaProvider` — the third ships empty in this wave and is filled in Plan 04-02), every AGENT-03 SSE edge case captured as a byte-replay fixture, every header/body assertion for AGENT-02 verified via unit test, and the `toolChoice: .none` serialization for AGENT-07 asserted against the request body.

**Scope note:** This plan touches ~30 files, exceeding the 15-file threshold. Splitting would fragment tightly-coupled scaffolding — protocol shape + first consumer + fixture corpus all need to land together to catch enum-shape drift. Mitigation: Task 1 (package + core types) commits atomically; Task 2 (AnthropicProvider + decoder + request builder) commits atomically; Task 3 (fixtures + replay tests) commits atomically. Each task ends with `cd packages/AgentCore && swift test` passing.
</objective>

<execution_context>
@~/.claude/get-shit-done/workflows/execute-plan.md
@~/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@CLAUDE.md
@.planning/PROJECT.md
@.planning/ROADMAP.md
@.planning/REQUIREMENTS.md
@.planning/STATE.md
@.planning/research/RESEARCH-DELTAS.md
@.planning/phases/04-agent-core/04-RESEARCH.md
@.planning/phases/01-foundations/01-02-SUMMARY.md

<interfaces>
<!-- Contracts established by Phase 1 that this plan consumes -->

From `packages/Config/Sources/Config/ProviderSelection.swift` (Phase 1 Plan 02):
```swift
public enum ProviderSelection: String, Sendable, Codable, Equatable {
    case anthropic
    case ollama
}
```

From `packages/Keychain/Sources/Keychain/KeychainStore.swift` (Phase 1 Plan 02):
```swift
public protocol KeychainStore: Sendable {
    func set(_ value: String, for item: KeychainItem) throws
    func get(_ item: KeychainItem) throws -> String
    func delete(_ item: KeychainItem) throws
}
public struct SystemKeychainStore: KeychainStore { public init() }
public extension KeychainItem {
    static let anthropic: KeychainItem
    // service = "com.koftwentytwo.jarvis", account = "anthropic"
}
```

From `packages/Logging/Sources/JarvisLogging/JarvisLogChannel.swift` (Phase 1 Plan 02):
```swift
public enum JarvisLogChannel: String, Sendable, CaseIterable {
    case agent, tools, ui, system, bus
}
```
Plan 04-04 (orchestrator) adds `replay` and `devoverlay` cases; this plan does not log in production paths (providers emit events; orchestrator logs).

<!-- Contracts this plan ESTABLISHES that downstream plans will consume -->

LLMProvider protocol (created in Task 1 here — consumed by OllamaProvider in Plan 04-02, by AgentOrchestrator in Plan 04-04):
```swift
public protocol LLMProvider: Sendable {
    func stream(
        messages: [LLMMessage],
        tools: [ToolSchema],
        toolChoice: ToolChoice,          // MANDATORY — no default
        model: ModelID,
        maxOutputTokens: Int,
        cacheHints: CacheHints?
    ) -> AsyncThrowingStream<LLMEvent, Error>
}

public enum ToolChoice: Sendable, Equatable {
    case auto
    case none
    case any
    case tool(name: String)
}

public struct ModelID: Sendable, RawRepresentable, Equatable, Hashable {
    public let rawValue: String
    public init(rawValue: String)
    public static let opus47 = ModelID(rawValue: "claude-opus-4-7")
    public static let qwen25coder32b = ModelID(rawValue: "qwen2.5-coder:32b")
}

public struct CacheHints: Sendable, Equatable {
    public enum CacheTTL: Sendable, Equatable { case ephemeral5m, extended1h }
    public let systemPromptTTL: CacheTTL
    public init(systemPromptTTL: CacheTTL)
}

public struct LLMMessage: Sendable, Equatable {
    public enum Role: String, Sendable { case system, user, assistant, tool }
    public let role: Role
    public let content: [ContentBlock]   // text / toolUse / toolResult
    public let untrusted: Bool           // orchestrator (Plan 04-04) sets true for tool_results
}

public struct ToolSchema: Sendable, Equatable {
    public let name: String
    public let description: String
    public let inputSchema: Data    // JSON-schema blob, passed through verbatim
}

public enum LLMEvent: Sendable {
    case messageStart(LLMMessageStart)
    case textDelta(String)
    case thinkingDelta(String)
    case toolUseRequested(ToolUseRequest)
    case toolUseBuffering(toolUseId: String)
    case partialToolUseAtDisconnect(ToolUseRequest)
    case stopReason(StopReason)
    case usage(TurnUsage)
    case providerError(LLMProviderError)
    case messageStop
}

public enum StopReason: Sendable, Equatable {
    case endTurn
    case toolUse
    case maxTokens
    case refusal
    case streamTruncated
}

public struct ToolUseRequest: Sendable, Equatable {
    public let id: String
    public let name: String
    public let argsJSON: Data
}

public struct TurnUsage: Sendable, Equatable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheCreationInputTokens: Int
    public let cacheReadInputTokens: Int
}

public struct LLMMessageStart: Sendable, Equatable {
    public let messageId: String
    public let model: String
    public let usagePrefix: TurnUsage?
}

public enum LLMProviderError: Error, Sendable, Equatable {
    case api(statusCode: Int, body: String)
    case decode(reason: String)
    case transport(description: String)
    case streamTruncatedFinal        // Plan 04-04 emits this after retry budget exhausted
}
```

BoundedAsyncChannel primitive (created in Task 1 here — consumed by Plan 04-03 Replay and Plan 04-04 orchestrator):
```swift
public actor BoundedAsyncChannel<Element: Sendable>: Sendable {
    public enum Policy: Sendable { case suspend, dropOldest, dropNewest }
    public init(capacity: Int, policy: Policy)
    public func send(_ element: Element) async
    public func finish()
    public nonisolated func makeAsyncIterator() -> AsyncIterator
    // Backed by an AsyncStream<Element> continuation internally; ring buffer
    // holds the bounded window; drain task hands off into the continuation.
}
```
</interfaces>

<codebase_patterns>
- Swift 6 strict concurrency — every target uses `.swiftLanguageMode(.v6)` per Phase 1 pattern S-1.
- Sendable-by-default for public models (S-3).
- Fetch-per-request for Keychain (S-5) — `AnthropicProvider` reads the API key on EVERY request via an injected `@Sendable () async throws -> String` closure; no caching.
- `swift build` + `swift test` must pass at the package root with zero warnings that were not already present before the plan started.
- Plan 01 `default-config.json` places resources at `Sources/<Target>/Resources/`, not at package root — fixtures in this plan go at `Tests/AnthropicProviderTests/Fixtures/` (SPM test-resource convention: fixtures MUST be declared in Package.swift `.testTarget(..., resources: [.process("Fixtures")])`).
</codebase_patterns>
</context>

<tasks>

<task type="auto" tdd="true">
  <name>Task 1: Scaffold packages/AgentCore + protocol surface + BoundedAsyncChannel</name>
  <files>
    packages/AgentCore/Package.swift,
    packages/AgentCore/Sources/AgentCore/LLMProvider.swift,
    packages/AgentCore/Sources/AgentCore/LLMEvent.swift,
    packages/AgentCore/Sources/AgentCore/LLMMessage.swift,
    packages/AgentCore/Sources/AgentCore/ToolChoice.swift,
    packages/AgentCore/Sources/AgentCore/ToolSchema.swift,
    packages/AgentCore/Sources/AgentCore/ModelID.swift,
    packages/AgentCore/Sources/AgentCore/CacheHints.swift,
    packages/AgentCore/Sources/AgentCore/TurnID.swift,
    packages/AgentCore/Sources/AgentCore/BoundedAsyncChannel.swift,
    packages/AgentCore/Sources/AgentCore/LLMProviderError.swift,
    packages/AgentCore/Sources/AnthropicProvider/Placeholder.swift,
    packages/AgentCore/Sources/OllamaProvider/Placeholder.swift,
    packages/AgentCore/Tests/AgentCoreTests/LLMEventTests.swift,
    packages/AgentCore/Tests/AgentCoreTests/ToolChoiceTests.swift,
    packages/AgentCore/Tests/AgentCoreTests/BoundedAsyncChannelTests.swift
  </files>
  <behavior>
    - Test 1 (AgentCoreTests/ToolChoiceTests): ToolChoice has exactly four cases (`.auto`, `.none`, `.any`, `.tool(name:)`); exhaustive switch with no `default:` branch compiles.
    - Test 2 (AgentCoreTests/LLMEventTests): LLMEvent has exactly ten cases: `.messageStart`, `.textDelta`, `.thinkingDelta`, `.toolUseRequested`, `.toolUseBuffering`, `.partialToolUseAtDisconnect`, `.stopReason`, `.usage`, `.providerError`, `.messageStop`; exhaustive switch compiles.
    - Test 3 (AgentCoreTests/LLMEventTests): StopReason has exactly five cases: `.endTurn`, `.toolUse`, `.maxTokens`, `.refusal`, `.streamTruncated`.
    - Test 4 (AgentCoreTests/LLMEventTests): `ModelID.opus47.rawValue == "claude-opus-4-7"` and `ModelID.qwen25coder32b.rawValue == "qwen2.5-coder:32b"` (AGENT-02, D1, D3 authoritative literals).
    - Test 5 (AgentCoreTests/BoundedAsyncChannelTests): `.suspend` policy — producer blocks on `send(...)` when buffer full; test uses a capacity-1 channel, first send succeeds synchronously, second suspends until the consumer reads (assert with a `Task.yield()` + timeout).
    - Test 6 (AgentCoreTests/BoundedAsyncChannelTests): `.dropOldest` policy — when capacity is 3 and you send 5 items without consuming, iteration yields items 3,4,5 in order (oldest two were dropped).
    - Test 7 (AgentCoreTests/BoundedAsyncChannelTests): `.dropNewest` policy — same scenario, iteration yields items 1,2,3 (newest two dropped).
    - Test 8 (AgentCoreTests/BoundedAsyncChannelTests): `finish()` terminates the AsyncSequence cleanly; `for await` loop exits.
    - Test 9 (AgentCoreTests/BoundedAsyncChannelTests): Load test — 10,000-item producer + slow (1ms per item) consumer on a `.dropOldest` capacity-128 channel completes without hangs; final count received ≤ 10,000 (lossy) but ≥ 128 (capacity is load-bearing).
    - Test 10 (AgentCoreTests/ToolChoiceTests): Compile-time assertion — `LLMProvider.stream(messages:tools:toolChoice:model:maxOutputTokens:cacheHints:)` cannot be called without specifying `toolChoice:`; verify via a conformance test where omitting the argument would fail to compile (encode this as a documented "must not compile" comment + a positive test that WITH the argument it compiles — we cannot assert negative compilation in XCTest, so the comment is the contract and the test passes when the call-with-argument compiles).
  </behavior>
  <action>
Create `packages/AgentCore/Package.swift` with Swift tools version 6.0, macOS 13 platform floor, three library products (`AgentCore`, `AnthropicProvider`, `OllamaProvider`), three source targets, three test targets. `AgentCore` target has no product dependencies beyond the standard library. `AnthropicProvider` and `OllamaProvider` targets depend on `AgentCore`. In this task, `AnthropicProvider/Placeholder.swift` and `OllamaProvider/Placeholder.swift` are single-line `struct _Placeholder { }` stubs — replaced in Task 2 (AnthropicProvider) and Plan 04-02 (OllamaProvider).

Package.swift dependencies:
- `packages/Keychain` (path: `../Keychain`) — consumed by `AnthropicProvider` target.
- `packages/Logging` (path: `../Logging`) — consumed by all three targets (loggers attached in orchestrator, not here, but we make the import available).
- `packages/Config` (path: `../Config`) — consumed by `OllamaProvider` (for `OllamaConfig`) and later the orchestrator. Declare as a dep on `AgentCore` so both provider targets inherit it.

`.swiftLanguageMode(.v6)` on every target. Test targets use `.process("Fixtures")` for test resources (add empty directories to Task 2 where fixtures land).

Create the eleven source files in `Sources/AgentCore/`:

1. **`LLMProvider.swift`** — the protocol exactly as spec'd in `<interfaces>` above. Protocol is `Sendable`. `stream(...)` takes **non-defaulted** `toolChoice: ToolChoice`. Returns `AsyncThrowingStream<LLMEvent, Error>`. Documentation comment explains cancellation flows through `Task.isCancelled`.

2. **`LLMEvent.swift`** — the full enum with ten cases per `<interfaces>`. Include `StopReason`, `ToolUseRequest`, `TurnUsage`, `LLMMessageStart` as sibling types in this file. All `Sendable`; `StopReason`, `ToolUseRequest`, `TurnUsage`, `LLMMessageStart` are `Equatable`. `LLMProviderError` lives in its own file (below).

3. **`LLMMessage.swift`** — the message shape. Nested `Role` enum (raw `String` — `system`, `user`, `assistant`, `tool`). Nested `ContentBlock` enum with three cases: `.text(String)`, `.toolUse(id: String, name: String, argsJSON: Data)`, `.toolResult(toolUseId: String, content: String)`. `untrusted: Bool` flag exists on `LLMMessage` (documentation: "Orchestrator sets true for any message containing `.toolResult` content — Plan 04-04 uses this to apply `turnNonce` wrapping"). All `Sendable`, `Equatable`.

4. **`ToolChoice.swift`** — the four-case enum. `Sendable`, `Equatable`. Provide a documentation block on each case explaining the Anthropic vs Ollama serialization per research §1 (Anthropic: object with `"type"` key; Ollama: `.none` drops tools array entirely).

5. **`ToolSchema.swift`** — `name: String`, `description: String`, `inputSchema: Data` (JSON-schema blob, passed through verbatim). `Sendable`, `Equatable`.

6. **`ModelID.swift`** — struct wrapping `rawValue: String`. Two static constants: `opus47` = "claude-opus-4-7", `qwen25coder32b` = "qwen2.5-coder:32b". `Sendable`, `RawRepresentable`, `Equatable`, `Hashable`. Comment on `opus47`: "Per RESEARCH-DELTAS D1 — `claude-opus-4-7` is the real model ID; SDK enum lag is non-blocking because URLSession accepts string model IDs."

7. **`CacheHints.swift`** — struct with nested `CacheTTL` enum (`.ephemeral5m`, `.extended1h`). `Sendable`, `Equatable`. Comment on `.extended1h`: "Requires `anthropic-beta: extended-cache-ttl-2025-04-11` header — silently falls back to 5m without it."

8. **`TurnID.swift`** — `public struct TurnID: Sendable, Equatable, Hashable, RawRepresentable { public let rawValue: String; public static func fresh() -> TurnID { TurnID(rawValue: UUID().uuidString) } }`. Used by orchestrator (Plan 04-04).

9. **`BoundedAsyncChannel.swift`** — actor wrapping a ring buffer + `AsyncStream` continuation. Public `Policy` enum with `.suspend`, `.dropOldest`, `.dropNewest`. On `init(capacity:policy:)`, store policy + allocate `ring: [Element]` with reserved capacity. `send(_:)` is `async`:
   - If `buffer.count < capacity`: append, signal continuation.
   - Else branch on policy:
     - `.suspend`: await a CheckedContinuation<Void, Never> stored in a pending-sends queue; consumer drains one slot and resumes the oldest pending sender.
     - `.dropOldest`: `buffer.removeFirst()`; append.
     - `.dropNewest`: return without appending.
   - After modifying buffer, the actor yields the HEAD item into a held `AsyncStream<Element>.Continuation` (which the iterator consumes). Design: keep an internal `sinkContinuation: AsyncStream<Element>.Continuation` set in `init` via `AsyncStream.makeStream(of:)`. The ring is drained opportunistically — every `send` pushes one item from the head to the continuation if the iterator has capacity (practically: always, since AsyncStream's own buffering is what bounds us, and we just use the ring + pending-queue to enforce the explicit policy).
   - `finish()` calls `sinkContinuation.finish()`.
   - `makeAsyncIterator()` returns `AsyncStream<Element>.Iterator` (wrapped in our own `AsyncIterator` type for Sendable hygiene).
   - **Note:** research §6 specifically says "drop-oldest for tokenDelta only" — that per-element policy lives in Plan 04-03 (Replay) where the `ReplayEvent` tag is checked. This primitive only offers the three uniform policies.

10. **`LLMProviderError.swift`** — enum `LLMProviderError: Error, Sendable, Equatable` with four cases: `.api(statusCode: Int, body: String)`, `.decode(reason: String)`, `.transport(description: String)`, `.streamTruncatedFinal`.

Placeholder files in `AnthropicProvider/` and `OllamaProvider/` are single-line `struct _PlaceholderAnthropicProvider { }` / `struct _PlaceholderOllamaProvider { }` — replaced in Task 2 and Plan 04-02.

Create the three test files listed in `<files>`. Follow the `<behavior>` test list exactly. Use XCTest (pre-installed). Tests are `@MainActor` only where strictly needed for timing fixtures; prefer detached `Task { ... }` + `XCTestExpectation` for async behaviour.

Commit: `feat(04-01): scaffold AgentCore package with LLMProvider protocol + LLMEvent + BoundedAsyncChannel (AGENT-01, AGENT-07, AGENT-10)`.
  </action>
  <verify>
    <automated>cd packages/AgentCore && swift build 2>&1 | tee /tmp/build-04-01-t1.log && swift test --filter AgentCoreTests 2>&1 | tee /tmp/test-04-01-t1.log && grep -c "Test Suite 'All tests' passed" /tmp/test-04-01-t1.log</automated>
  </verify>
  <done>
    - `cd packages/AgentCore && swift build` exits 0.
    - `cd packages/AgentCore && swift test --filter AgentCoreTests` exits 0 with all 10+ tests passing.
    - `grep -c "extension LLMProvider" packages/AgentCore/Sources/AgentCore/LLMProvider.swift` is 0 (no default-argument extension exists — `toolChoice` must remain non-defaulted).
    - `grep -v '^//' packages/AgentCore/Sources/AgentCore/ToolChoice.swift | grep -c 'case'` equals 4 (exactly four cases — excludes comment lines per grep-hygiene rule).
    - `grep "claude-opus-4-7" packages/AgentCore/Sources/AgentCore/ModelID.swift` finds the literal string.
    - `grep "qwen2.5-coder:32b" packages/AgentCore/Sources/AgentCore/ModelID.swift` finds the literal string.
    - `grep -c 'extension LLMEvent' packages/AgentCore/Sources/AgentCore/LLMEvent.swift` is 0 (no default-case convenience extensions).
  </done>
</task>

<task type="auto" tdd="true">
  <name>Task 2: AnthropicProvider — URLSession transport + hand-rolled SSE decoder + request builder</name>
  <files>
    packages/AgentCore/Sources/AnthropicProvider/AnthropicProvider.swift,
    packages/AgentCore/Sources/AnthropicProvider/SSEDecoder.swift,
    packages/AgentCore/Sources/AnthropicProvider/SSELineReader.swift,
    packages/AgentCore/Sources/AnthropicProvider/RequestBody.swift,
    packages/AgentCore/Sources/AnthropicProvider/Base64URL.swift,
    packages/AgentCore/Tests/AnthropicProviderTests/SSEDecoderTests.swift,
    packages/AgentCore/Tests/AnthropicProviderTests/RequestBodyTests.swift
  </files>
  <behavior>
    - Test R1 (RequestBodyTests): Request body with `ModelID.opus47` + `CacheHints(.extended1h)` on system prompt → JSON includes `"model":"claude-opus-4-7"` AND `"cache_control":{"type":"ephemeral","ttl":"1h"}` on the first system-content block.
    - Test R2 (RequestBodyTests): Same request body without `CacheHints` → no `cache_control` key in `system[*]` blocks.
    - Test R3 (RequestBodyTests): `ToolChoice.none` serializes to `"tool_choice":{"type":"none"}`.
    - Test R4 (RequestBodyTests): `ToolChoice.auto` → `"tool_choice":{"type":"auto"}`; `ToolChoice.any` → `{"type":"any"}`; `ToolChoice.tool(name: "get_time")` → `{"type":"tool","name":"get_time"}`.
    - Test R5 (RequestBodyTests): Tools array encoded with each ToolSchema's `inputSchema` passed through as a JSON object (not re-encoded as a string).
    - Test S1 (SSEDecoderTests): `message_start` event → decoder emits `.messageStart(LLMMessageStart)` with `messageId`, `model`, `usagePrefix.inputTokens`, `usagePrefix.cacheCreationInputTokens`, `usagePrefix.cacheReadInputTokens` parsed from JSON.
    - Test S2 (SSEDecoderTests): Three-delta text sequence (`content_block_start` + 3×`content_block_delta{type:text_delta}` + `content_block_stop` + `message_delta` + `message_stop`) → emits `.textDelta("a")`, `.textDelta("b")`, `.textDelta("c")`, then `.stopReason(.endTurn)`, `.usage(...)`, `.messageStop`. **No events before `message_stop` close the stream** (AGENT-03).
    - Test S3 (SSEDecoderTests): `ping` events anywhere in the stream emit ZERO `LLMEvent`s — swallowed (AGENT-03).
    - Test S4 (SSEDecoderTests): Tool-use sequence — `content_block_start{type:tool_use,id:toolu_X,name:get_time}` + 4×`content_block_delta{type:input_json_delta,partial_json:"{\"a"}"` → `":"1"}"` etc + `content_block_stop` → emits ONE `.toolUseRequested(ToolUseRequest(id:"toolu_X",name:"get_time",argsJSON:Data("{\"a\":1}".utf8)))`. Decoder **does not** emit intermediate events while assembling (AGENT-03).
    - Test S5 (SSEDecoderTests): Empty `input_json_delta` (partial_json = `""`) in the middle of a 5-delta sequence → decoder skips it; final assembled JSON matches the non-empty deltas concatenated.
    - Test S6 (SSEDecoderTests): `thinking_delta` content_block — emits `.thinkingDelta("step 1")` per delta (AGENT-03).
    - Test S7 (SSEDecoderTests): `stop_reason: "refusal"` on `message_delta` (captured) + `message_stop` → emits `.stopReason(.refusal)` — not `.endTurn` (AGENT-03).
    - Test S8 (SSEDecoderTests): Mid-delta EOF simulation — stream truncated after 2 of 5 `input_json_delta` chunks for a tool_use block → decoder emits `.partialToolUseAtDisconnect(ToolUseRequest(id:..., name:..., argsJSON:partialBytes))`, then `.stopReason(.streamTruncated)`, then `.messageStop` (AGENT-03).
    - Test S9 (SSEDecoderTests): Unknown event name (e.g. `event: future_event`) — decoder logs a warning but does NOT throw; stream continues. Surfaces in tests via absence of throw.
    - Test S10 (SSEDecoderTests): `message_delta` with `stop_reason: "end_turn"` arriving mid-stream does NOT close the decoder; only `message_stop` does (AGENT-03). Test issues `message_delta{stop_reason:"end_turn"}` → `content_block_delta{text_delta:"trailing"}` → `message_stop`; expects `.textDelta("trailing")` was emitted between the delta and stop.
    - Test S11 (SSEDecoderTests): `stop_reason` mapping — `"end_turn"`→`.endTurn`, `"tool_use"`→`.toolUse`, `"max_tokens"`→`.maxTokens`, `"refusal"`→`.refusal`, unknown string→`.endTurn` (with a log warning, but not a throw).
  </behavior>
  <action>
Delete `packages/AgentCore/Sources/AnthropicProvider/Placeholder.swift` from Task 1.

**`SSELineReader.swift`** — Wraps `URLSession.AsyncBytes.lines` OR an injected `AsyncSequence<Data, Error>` of raw bytes for test replay. Yields complete `(event: String, data: Data)` frames. Accumulates across lines until a blank `\n\n` separator. Strips `event: ` prefix on event lines. Handles `data: ` prefix on data lines. Multi-line `data: ` (SSE spec) concatenates with `\n` between lines. Test mode: `init(bytes: AsyncStream<UInt8>)` for fixture replay from a `.txt` file whose bytes are the raw recorded SSE stream.

**`SSEDecoder.swift`** — State machine. Takes a frame (`event: String, data: Data`) and a `AsyncThrowingStream<LLMEvent, Error>.Continuation`, emits zero or more events. Internal state:
```swift
struct DecoderState {
    var currentToolUseId: String?
    var currentToolUseName: String?
    var currentToolUseBuffer: Data = Data()
    var capturedStopReason: StopReason?
    var capturedUsage: TurnUsage?
    var messageId: String?
    var model: String?
}
```
Dispatch table (exactly as in research §3):
- `event: message_start`, parse `data.message.id`, `data.message.model`, `data.message.usage.{input_tokens,cache_creation_input_tokens,cache_read_input_tokens}`. Emit `.messageStart(LLMMessageStart(messageId:..., model:..., usagePrefix: TurnUsage(...)))`.
- `event: content_block_start` with `content_block.type == "tool_use"` → capture `currentToolUseId`, `currentToolUseName`, reset `currentToolUseBuffer = Data()`. Emit `.toolUseBuffering(toolUseId: id)` (optional UI hint — this is a documented signal, not load-bearing; tests verify emission but orchestrator ignores).
- `event: content_block_start` with `type == "text"` or `type == "thinking"` → no-op; decoder will emit deltas directly.
- `event: content_block_delta` — branch on `delta.type`:
  - `"text_delta"`: emit `.textDelta(delta.text)`.
  - `"input_json_delta"`: if `delta.partial_json.isEmpty` then SKIP (do not append, do not emit). Else `currentToolUseBuffer.append(Data(delta.partial_json.utf8))`.
  - `"thinking_delta"`: emit `.thinkingDelta(delta.thinking)`.
  - unknown: log warning, no emit.
- `event: content_block_stop` — if we were buffering a tool_use, emit `.toolUseRequested(ToolUseRequest(id: currentToolUseId!, name: currentToolUseName!, argsJSON: currentToolUseBuffer))`. Reset tool-use state.
- `event: message_delta` — parse `delta.stop_reason` (capture into state), parse `usage.output_tokens` (update state). **Do NOT close.**
- `event: message_stop` — emit `.stopReason(capturedStopReason ?? .endTurn)`, emit `.usage(capturedUsage ?? zeroUsage)`, emit `.messageStop`. Return "closed" signal to the caller.
- `event: ping` — swallow.
- `event: error` — emit `.providerError(.api(statusCode: HTTP status if known else -1, body: data))`.
- Any other `event` name — log warning, no emit.

On mid-stream EOF (SSELineReader's AsyncSequence ends before `message_stop` was seen):
- If `currentToolUseId != nil`: emit `.partialToolUseAtDisconnect(ToolUseRequest(id: currentToolUseId!, name: currentToolUseName ?? "", argsJSON: currentToolUseBuffer))`.
- Emit `.stopReason(.streamTruncated)`.
- Emit `.messageStop`.

Stop-reason mapping: `"end_turn"` → `.endTurn`, `"tool_use"` → `.toolUse`, `"max_tokens"` → `.maxTokens`, `"refusal"` → `.refusal`. Anything else logs warning and maps `.endTurn`.

**`RequestBody.swift`** — Builds the JSON request body via hand-rolled `JSONEncoder` setup (avoid `[String: Any]` dictionaries — they're not Sendable and not type-safe). Use `Codable` wrapper structs with custom `encode(to:)` where polymorphism is needed (tool_choice, content blocks).

Request body shape per research §3:
```json
{
  "model": "<rawValue>",
  "max_tokens": <int>,
  "system": [
    {"type":"text","text":"<system prompt>","cache_control":{"type":"ephemeral","ttl":"1h"}}
  ],
  "messages": [...],
  "tools": [{"name":"...","description":"...","input_schema":{...}}],
  "tool_choice": {"type":"auto|none|any|tool","name":"..."}
}
```

- `encodeToolChoice(_ choice: ToolChoice) -> EncodedToolChoice` — `.auto` → `{"type":"auto"}`; `.none` → `{"type":"none"}`; `.any` → `{"type":"any"}`; `.tool(name: n)` → `{"type":"tool","name":"<n>"}`.
- `encodeCacheControl(_ hints: CacheHints?) -> EncodedCacheControl?` — nil if hints absent or `.ephemeral5m`. For `.extended1h`, emits `{"type":"ephemeral","ttl":"1h"}`.
- System prompt is synthesized from the first `.system` role message in `messages` (if present) — **extracted out of the messages array** into the top-level `system` field per Anthropic's request shape. Comment on this: "Anthropic splits system role to a top-level field; we consume `messages[0]` if role=.system, otherwise system is absent."
- Tools encoded with `input_schema` passed through as a JSON object (decode ToolSchema.inputSchema as JSON, re-encode at request-build time — NOT double-encoded as a string).
- User/assistant messages encoded with `role: "user"|"assistant"` and `content: [ContentBlock]`. `.toolUse` blocks serialize as `{"type":"tool_use","id":...,"name":...,"input":<json>}`. `.toolResult` blocks serialize as `{"type":"tool_result","tool_use_id":...,"content":"<string>"}`.

**`Base64URL.swift`** — `extension Data { func base64URLEncodedString() -> String }` — standard base64 with `+→-`, `/→_`, strip trailing `=`. Used in Plan 04-04 for `turnNonce`; lands here so `AgentCore` doesn't need a separate utility module. Mark the extension `internal` (tests access via `@testable import`).

**`AnthropicProvider.swift`** — The actor:
```swift
public actor AnthropicProvider: LLMProvider {
    private let apiKeyProvider: @Sendable () async throws -> String
    private let session: URLSession
    private let baseURL: URL
    public init(
        baseURL: URL = URL(string: "https://api.anthropic.com")!,
        session: URLSession = .shared,
        apiKeyProvider: @escaping @Sendable () async throws -> String
    ) { ... }
    public nonisolated func stream(
        messages: [LLMMessage], tools: [ToolSchema], toolChoice: ToolChoice,
        model: ModelID, maxOutputTokens: Int, cacheHints: CacheHints?
    ) -> AsyncThrowingStream<LLMEvent, Error> { ... }
}
```
`stream(...)` is `nonisolated` because it creates a new Task per call; returned `AsyncThrowingStream` is self-contained. The task captures `self` via weak reference for cancellation: `continuation.onTermination = { [weak self] _ in /* task.cancel() handled via Task scope */ }`.

Per-turn flow inside the task:
1. Build URLRequest with method POST, URL = `baseURL.appending(path: "v1/messages")`, headers `Content-Type: application/json`, `Accept: text/event-stream`, `anthropic-version: 2023-06-01`, **`anthropic-beta: extended-cache-ttl-2025-04-11`** (unconditional — AGENT-02 has `every request` guarantee), `x-api-key: <result of apiKeyProvider()>`.
2. `httpBody = try RequestBody.encode(messages:..., tools:..., toolChoice:..., model:..., maxOutputTokens:..., cacheHints:...)`.
3. `let (bytes, response) = try await session.bytes(for: request)`.
4. Assert HTTP 2xx — if not, consume body and emit `.providerError(.api(statusCode:..., body:...))` then finish.
5. Hand `bytes` (URLSession.AsyncBytes) to `SSELineReader`. For each frame, call `SSEDecoder.dispatch(frame:, continuation:, state: inout)`.
6. When the `bytes` sequence ends: call `SSEDecoder.flushOnEOF(continuation:, state:)` which does the mid-stream-EOF logic (emit `.partialToolUseAtDisconnect` if buffering, then `.stopReason(.streamTruncated)`, then `.messageStop`) — but only if `message_stop` was not already emitted. Track this with a `messageStopEmitted` flag in decoder state.
7. `continuation.finish()`.

Any caught error (transport, JSON decode on response headers, etc.) → `continuation.finish(throwing: LLMProviderError.transport(description: error.localizedDescription))` OR for decode failures `.decode(reason:)`.

**Test fixture injection for SSEDecoder** — write tests that bypass URLSession: construct an `AsyncThrowingStream<(event: String, data: Data), Error>` of frames in-process, call `SSEDecoder.dispatch` per frame, collect emitted events. Do NOT spin up URLProtocol mocks in Task 2 — those come in Task 3 for the fixture replay suite.

Commit: `feat(04-01): AnthropicProvider with URLSession SSE decoder covering all six AGENT-03 edges + 1h cache TTL header wiring (AGENT-02, AGENT-03, AGENT-07)`.
  </action>
  <verify>
    <automated>cd packages/AgentCore && swift build 2>&1 | tee /tmp/build-04-01-t2.log && swift test --filter AnthropicProviderTests.SSEDecoderTests --filter AnthropicProviderTests.RequestBodyTests 2>&1 | tee /tmp/test-04-01-t2.log && grep -c "Test Suite 'All tests' passed" /tmp/test-04-01-t2.log</automated>
  </verify>
  <done>
    - `cd packages/AgentCore && swift test --filter SSEDecoderTests --filter RequestBodyTests` exits 0; 16+ tests pass.
    - `grep -c 'extended-cache-ttl-2025-04-11' packages/AgentCore/Sources/AnthropicProvider/AnthropicProvider.swift` ≥ 1 (the header literal is present).
    - `grep -c '"ttl":"1h"' packages/AgentCore/Sources/AnthropicProvider/RequestBody.swift` ≥ 1 OR `grep -c 'ttl.*1h' packages/AgentCore/Sources/AnthropicProvider/RequestBody.swift` ≥ 1 (the TTL literal is wired — check both exact-string and templated-string forms).
    - `grep -c 'anthropic-version' packages/AgentCore/Sources/AnthropicProvider/AnthropicProvider.swift` ≥ 1.
    - `grep -c 'message_stop' packages/AgentCore/Sources/AnthropicProvider/SSEDecoder.swift` ≥ 1.
    - `grep -v '^//' packages/AgentCore/Sources/AnthropicProvider/SSEDecoder.swift | grep -c 'ping'` ≥ 1 (ping-swallowing logic is present).
    - `grep -c 'partialToolUseAtDisconnect' packages/AgentCore/Sources/AnthropicProvider/SSEDecoder.swift` ≥ 1.
    - `grep -c '"type":"none"' packages/AgentCore/Sources/AnthropicProvider/RequestBody.swift` ≥ 1 OR equivalent encoding path producing that string — verified by test R3.
  </done>
</task>

<task type="auto" tdd="true">
  <name>Task 3: Byte-replay fixture corpus — 9 recorded SSE streams covering every AGENT-03 edge case</name>
  <files>
    packages/AgentCore/Tests/AnthropicProviderTests/FixtureReplayTests.swift,
    packages/AgentCore/Tests/AnthropicProviderTests/Fixtures/happy-text.txt,
    packages/AgentCore/Tests/AnthropicProviderTests/Fixtures/text-then-tool-use.txt,
    packages/AgentCore/Tests/AnthropicProviderTests/Fixtures/thinking-then-text.txt,
    packages/AgentCore/Tests/AnthropicProviderTests/Fixtures/refusal.txt,
    packages/AgentCore/Tests/AnthropicProviderTests/Fixtures/mid-delta-disconnect.txt,
    packages/AgentCore/Tests/AnthropicProviderTests/Fixtures/ping-spam.txt,
    packages/AgentCore/Tests/AnthropicProviderTests/Fixtures/unknown-event.txt,
    packages/AgentCore/Tests/AnthropicProviderTests/Fixtures/cache-hit.txt,
    packages/AgentCore/Tests/AnthropicProviderTests/Fixtures/empty-input-json-delta.txt
  </files>
  <behavior>
    - Test F1 (FixtureReplayTests): `happy-text.txt` → decoder emits exactly `[.messageStart, .textDelta(...)×N, .stopReason(.endTurn), .usage, .messageStop]` (N text deltas documented as a constant per fixture).
    - Test F2: `text-then-tool-use.txt` → `[.messageStart, .textDelta(...), .toolUseBuffering(...), .toolUseRequested(ToolUseRequest), .stopReason(.toolUse), .usage, .messageStop]` — critical: `.toolUseRequested` fires ONCE after content_block_stop, with a fully-assembled `argsJSON` that JSON-decodes successfully.
    - Test F3: `thinking-then-text.txt` → includes at least two `.thinkingDelta(...)` events before any `.textDelta(...)`.
    - Test F4: `refusal.txt` → final stopReason is `.refusal` (NOT `.endTurn`).
    - Test F5: `mid-delta-disconnect.txt` → ends with `.partialToolUseAtDisconnect(req)` where `req.argsJSON` is the partial (invalid) JSON bytes accumulated up to EOF, followed by `.stopReason(.streamTruncated)` and `.messageStop`. The fixture's file bytes stop mid-`input_json_delta`.
    - Test F6: `ping-spam.txt` → 20 ping events interleaved with 3 text deltas → decoder emits exactly 3 `.textDelta` events (plus .messageStart / .stopReason / .usage / .messageStop).
    - Test F7: `unknown-event.txt` → decoder emits expected text events, does NOT throw, does NOT log at error level (it logs a warning and continues).
    - Test F8: `cache-hit.txt` → `message_start.usage.cache_read_input_tokens > 0` is parsed into `TurnUsage.cacheReadInputTokens > 0`, surfaces in the emitted `.messageStart` event's `usagePrefix`.
    - Test F9: `empty-input-json-delta.txt` → 5 input_json_delta chunks where the middle one has `partial_json: ""`; assembled tool_use argsJSON equals the non-empty chunks concatenated.
  </behavior>
  <action>
Update `packages/AgentCore/Package.swift` test target for `AnthropicProviderTests` to include `resources: [.process("Fixtures")]` so the fixture .txt files are accessible via `Bundle.module.url(forResource: ..., withExtension: "txt")`.

Hand-craft 9 fixture .txt files. Each file is a literal byte-for-byte Anthropic SSE stream (LF line endings, no CRLF). Shape per frame:
```
event: message_start
data: {"type":"message_start","message":{...}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"text"}}

```
(blank line between frames is the SSE separator.)

**`happy-text.txt`** — 3 text deltas ("Hello", " ", "world"). Tight & minimal. `stop_reason: "end_turn"`. `usage.output_tokens: 3`.

**`text-then-tool-use.txt`** — 1 text delta ("Let me check"), then content_block_stop, then a new content_block_start with `type: "tool_use", id: "toolu_ABC", name: "get_time"`, then 4 `input_json_delta` chunks whose `partial_json` concatenates to `{"timezone":"UTC"}`, then content_block_stop, then `message_delta` with `stop_reason: "tool_use"`, then `message_stop`.

**`thinking-then-text.txt`** — content_block_start with `type: "thinking"`, 2 `thinking_delta` chunks, content_block_stop, then a text content block with 1 delta.

**`refusal.txt`** — Empty content array (no blocks), then `message_delta` with `stop_reason: "refusal"`, then `message_stop`. Per Anthropic shape — refusals can have empty content.

**`mid-delta-disconnect.txt`** — Starts a tool_use content block, emits 2 of 5 `input_json_delta` chunks (partial_json = `{"que`, `ry":`), then the file ends. No `content_block_stop`, no `message_stop`. The test asserts `SSEDecoder.flushOnEOF` emits `.partialToolUseAtDisconnect`.

**`ping-spam.txt`** — message_start, then an alternating pattern: 1 text delta, 5 ping events, 1 text delta, 10 ping events, 1 text delta, 5 ping events, then content_block_stop, message_delta, message_stop. Total 3 text deltas + 20 pings.

**`unknown-event.txt`** — Standard shape but includes one `event: future_event` with arbitrary data payload midway through. Decoder logs a warning, continues. Test asserts no throw + expected text events still flow.

**`cache-hit.txt`** — `message_start.usage.cache_read_input_tokens: 4251`, `cache_creation_input_tokens: 0`, `input_tokens: 12`. Then 1 text delta. stop_reason: end_turn. Confirms the `cache_read_input_tokens > 0` signal surfaces correctly.

**`empty-input-json-delta.txt`** — tool_use content block with 5 `input_json_delta` chunks, where the THIRD chunk's `partial_json` is the empty string `""`. Full assembled JSON from chunks 1,2,4,5 is `{"a":"1","b":2}`.

Create `FixtureReplayTests.swift` — an XCTestCase that, per fixture, loads via `Bundle.module.url(forResource: "<name>", withExtension: "txt")`, reads bytes, converts to `AsyncStream<UInt8>`, hands to `SSELineReader`, pushes frames through `SSEDecoder`, collects emitted `LLMEvent`s into an array, and asserts against an expected sequence hand-written in the test per fixture (case-analyzed via pattern matching, since LLMEvent is not Equatable due to associated `Data` and error types — write a helper `eventMatches(_ actual: LLMEvent, _ expected: ExpectedEvent) -> Bool` with case-by-case branches).

**Implementation detail:** because `LLMProviderError` contains `statusCode:body:` which is hard to compare across fixtures, use a reduced `ExpectedEvent` enum for test assertions: `.messageStart`, `.textDelta(String)`, `.thinkingDelta(String)`, `.toolUseRequested(id: String, name: String, argsJSON: Data)`, `.toolUseBuffering(String)`, `.partialToolUseAtDisconnect(id: String)`, `.stopReason(StopReason)`, `.usage, .messageStop` — assertion compares structural shape, not deep equality of associated error payloads.

Commit: `test(04-01): byte-replay fixture corpus — 9 SSE streams covering every AGENT-03 edge case`.
  </action>
  <verify>
    <automated>cd packages/AgentCore && swift test --filter FixtureReplayTests 2>&1 | tee /tmp/test-04-01-t3.log && grep -c "Test Suite 'All tests' passed" /tmp/test-04-01-t3.log</automated>
  </verify>
  <done>
    - `ls packages/AgentCore/Tests/AnthropicProviderTests/Fixtures/ | wc -l` equals 9 (all fixtures created).
    - `cd packages/AgentCore && swift test --filter FixtureReplayTests` exits 0 with 9 tests passing.
    - `cd packages/AgentCore && swift test` exits 0 with ALL tests across all three test targets passing (AgentCoreTests + AnthropicProviderTests; OllamaProviderTests has 0 tests until Plan 04-02).
    - `grep -l 'content_block_stop' packages/AgentCore/Tests/AnthropicProviderTests/Fixtures/text-then-tool-use.txt` finds the fixture.
    - `grep -l 'refusal' packages/AgentCore/Tests/AnthropicProviderTests/Fixtures/refusal.txt` finds the fixture.
    - `awk 'END { print NR }' packages/AgentCore/Tests/AnthropicProviderTests/Fixtures/mid-delta-disconnect.txt` is > 0 AND the file does NOT contain `message_stop` (assert via `! grep -q message_stop <file>`).
    - Final full test run: `cd packages/AgentCore && swift test` exits 0; combined test count is ≥ 30 (AgentCoreTests 10 + SSEDecoderTests 11 + RequestBodyTests 5 + FixtureReplayTests 9 = 35, allow some variance).
  </done>
</task>

</tasks>

<threat_model>
## Trust Boundaries

| Boundary | Description |
|----------|-------------|
| Anthropic API → Swift process | Remote LLM response (SSE bytes) crosses network; content is attacker-controlled via prompt-injection attempts reflected in model output. |
| Keychain → AnthropicProvider | API key read per-request (S-5 pattern); leaks through logs, error messages, or URL serialization are exfiltration risks. |
| LLMMessage.untrusted → prompt | `untrusted: true` messages (populated by orchestrator from tool results in Plan 04-04) cross into prompt space; injection defense is Plan 04-04's job, but this plan must not accidentally promote untrusted content. |

## STRIDE Threat Register

| Threat ID | Category | Component | Disposition | Mitigation Plan |
|-----------|----------|-----------|-------------|-----------------|
| T-04-01-01 | Information Disclosure | `AnthropicProvider` error paths | mitigate | `LLMProviderError.api(statusCode, body)` — body is Anthropic's error response (may echo API key in malformed header scenarios); sanitize by never logging `.api` bodies at the provider layer. Orchestrator (Plan 04-04) handles redaction via `Redact.apply` from `JarvisLogging`. Test: synthetic 401 response with an echoed `x-api-key: sk-ant-FAKE` in body → provider error payload contains the body verbatim (caller must redact); log-level check via `grep -c 'sk-ant-FAKE' /tmp/*.log` = 0 after test run. |
| T-04-01-02 | Tampering | SSE stream injection | mitigate | Attacker who MitMs the TLS connection can inject arbitrary SSE events. URLSession enforces TLS + certificate validation by default (no pinning in P4 — deferred). Mitigation is structural: `SSEDecoder` never executes content, only yields into `LLMEvent`. Prompt-injection within tool-use blocks is neutralized by orchestrator (SEC-06, Plan 04-04) via `turnNonce` wrapping BEFORE content reaches the provider. |
| T-04-01-03 | Denial of Service | Infinite SSE stream | accept | URLSession has no built-in stream timeout; an attacker (compromised Anthropic) could hold the connection forever. Defence: orchestrator (Plan 04-04) wraps `stream()` in `Task { try await withTimeout(300s) { ... } }`. Not in this plan. Documented here, enforced there. |
| T-04-01-04 | Repudiation | Provider silently downgrades cache TTL | mitigate | `anthropic-beta: extended-cache-ttl-2025-04-11` header unconditionally present on every request (verified by Test R1 request-body assertion + a dedicated header-presence test asserting the URLRequest.allHTTPHeaderFields dictionary contains the exact key/value). Missing header is a silent 5m-TTL regression in production → this is specifically the AGENT-02 defense. |
| T-04-01-05 | Spoofing | Empty `apiKeyProvider()` return | mitigate | `apiKeyProvider()` returns an empty string (e.g., keychain item missing). Anthropic would 401; `AnthropicProvider` emits `.providerError(.api(statusCode: 401, body: "..."))`. Test: injected `apiKeyProvider` returning `""` → `URLRequest.x-api-key` = `""`; against a mock URLProtocol that returns 401, assert provider yields `.providerError` and stream finishes cleanly. |
| T-04-01-06 | Tampering | BoundedAsyncChannel drop-policy exploitation | mitigate | `.dropOldest` could be exploited by an adversarial producer to cause replay gaps. In Plan 04-04 this is bounded to `tokenDelta` ONLY; other event types use `.suspend`. This plan provides the primitive; the safety property is enforced by the per-channel wiring in Plan 04-04 + Plan 04-03. |
</threat_model>

<verification>
- `cd packages/AgentCore && swift build` — builds clean with zero warnings.
- `cd packages/AgentCore && swift test` — all tests across AgentCoreTests + AnthropicProviderTests pass (≥ 30 tests total).
- Frontmatter/structure validation: `gsd-sdk query frontmatter.validate .planning/phases/04-agent-core/04-01-llm-provider-anthropic-PLAN.md --schema plan` returns valid.
- Grep gates (see individual task `<done>` lines) all pass.
- `grep -r "tool_choice.*none" packages/AgentCore/ | grep -v Tests` finds the AGENT-07 serialization in RequestBody.swift.
</verification>

<success_criteria>
- `packages/AgentCore/Package.swift` exists with three library products; `swift build` and `swift test` pass at the package root.
- `LLMProvider` protocol exists with non-defaulted `toolChoice:` argument; `ToolChoice.none` serializes to Anthropic `{"type":"none"}`.
- `ModelID.opus47.rawValue == "claude-opus-4-7"` (RESEARCH-DELTAS D1 literal honored).
- Every Anthropic request carries `anthropic-beta: extended-cache-ttl-2025-04-11` header (AGENT-02).
- Every SSE edge case in AGENT-03 has a unit test AND a byte-replay fixture test: empty `input_json_delta` skipped, `message_stop` (not `message_delta`) as canonical close, `ping` swallowed, `refusal` first-class, `thinking_delta` own case, mid-delta disconnect emits `.partialToolUseAtDisconnect`.
- `BoundedAsyncChannel` supports `.suspend`, `.dropOldest`, `.dropNewest`; load-tested at 10K items without hangs (AGENT-10 primitive is ready for Plan 04-03 + 04-04 wiring).
- No Anthropic SDK dependency in `Package.swift` (hand-rolled URLSession only — per D1 and research §3).
</success_criteria>

<output>
After completion, create `.planning/phases/04-agent-core/04-01-SUMMARY.md` per the GSD summary template.
</output>
