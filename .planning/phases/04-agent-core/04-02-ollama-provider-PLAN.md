---
phase: 04-agent-core
plan: 02
type: execute
wave: 2
depends_on: [01]
files_modified:
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
autonomous: true
requirements: [AGENT-04, AGENT-07]
must_haves:
  truths:
    - "OllamaProvider conforms to LLMProvider protocol from Plan 04-01"
    - "OllamaProvider.init takes baseURL: URL (validated at Config layer to 127.0.0.1/localhost/::1 — AGENT-05 delivered in P1), URLSession, and useOpenAICompat: Bool (default false)"
    - "Default path is /api/chat NDJSON — OpenAI-compat /v1/chat/completions SSE is behind useOpenAICompat flag (AGENT-04)"
    - "NDJSONDecoder emits .toolUseRequested WHENEVER tool_calls is present on any chunk — NEVER gates on done:true (AGENT-04)"
    - "NDJSONDecoder synthesizes UUID for each tool_use id (Ollama does not emit ids; orchestrator maps back to tool_result by position)"
    - "NDJSONDecoder maps done_reason: 'stop' → .endTurn; 'length' → .maxTokens; 'tool_calls' or missing-but-tool-calls-present → .toolUse"
    - "NDJSONDecoder has no 'refusal' concept (Ollama protocol does not emit it)"
    - "Mid-stream EOF on NDJSON emits .stopReason(.streamTruncated) + .messageStop (no partial_tool_use because each line is atomic JSON)"
    - "OllamaRequestBody: ToolChoice.none causes the 'tools' array to be OMITTED ENTIRELY from the request body — not {type:none} (AGENT-07, critical cap-recovery)"
    - "OllamaRequestBody: ToolChoice.auto / .any / .tool include the tools array; for Ollama there is no first-class 'force', just best-effort via a system message hint"
    - "OpenAICompatDecoder handles SSE 'data: {...}' frames with choices[0].delta.content / choices[0].delta.tool_calls (atomic tool_calls, not split like Anthropic)"
    - "Both decoders share zero state machine code with each other or with AnthropicProvider's SSEDecoder (protocol-shape parity via LLMEvent is the only coupling)"
    - "ModelID.qwen25coder32b (rawValue 'qwen2.5-coder:32b') is the only Ollama model surface in code; no qwen3/qwen3.5 constants exist (per RESEARCH-DELTAS D3)"
    - "Fixture replay suite covers 6 byte-stream fixtures: happy-text (NDJSON), text-then-tool-call (NDJSON — verifies tool_calls on chunk WHERE done=false), parallel-tool-calls (NDJSON — multiple tool_calls in one chunk), mid-stream-eof (NDJSON), openai-compat-happy (SSE), openai-compat-tool-call (SSE)"
  artifacts:
    - path: "packages/AgentCore/Sources/OllamaProvider/OllamaProvider.swift"
      provides: "URLSession-based Ollama provider; branches between /api/chat NDJSON and /v1/chat/completions SSE on feature flag"
      contains: "useOpenAICompat"
    - path: "packages/AgentCore/Sources/OllamaProvider/NDJSONDecoder.swift"
      provides: "Line-delimited-JSON state machine; critical tool_calls-on-sight invariant (AGENT-04)"
      contains: "tool_calls"
    - path: "packages/AgentCore/Sources/OllamaProvider/OpenAICompatDecoder.swift"
      provides: "SSE decoder for /v1/chat/completions with atomic tool_calls"
      contains: "data: "
    - path: "packages/AgentCore/Sources/OllamaProvider/OllamaRequestBody.swift"
      provides: "Request body builder; ToolChoice.none DROPS tools array entirely (AGENT-07 critical)"
      contains: "ToolChoice"
    - path: "packages/AgentCore/Tests/OllamaProviderTests/Fixtures/text-then-tool-call.txt"
      provides: "NDJSON fixture where tool_calls appear on a done:false chunk — regression guard for AGENT-04"
      contains: "tool_calls"
  key_links:
    - from: "packages/AgentCore/Sources/OllamaProvider/OllamaProvider.swift"
      to: "packages/AgentCore/Sources/AgentCore/LLMProvider.swift"
      via: "actor OllamaProvider: LLMProvider conformance"
      pattern: "OllamaProvider: LLMProvider"
    - from: "packages/AgentCore/Sources/OllamaProvider/NDJSONDecoder.swift"
      to: "packages/AgentCore/Sources/AgentCore/LLMEvent.swift"
      via: "emits .toolUseRequested on seeing tool_calls, regardless of done flag"
      pattern: "toolUseRequested"
    - from: "packages/AgentCore/Sources/OllamaProvider/OllamaRequestBody.swift"
      to: "packages/AgentCore/Sources/AgentCore/ToolChoice.swift"
      via: "ToolChoice.none causes tools array to be absent from JSON body"
      pattern: "case \\.none"
---

<objective>
Deliver the second `LLMProvider` conformance — `OllamaProvider` — covering the native `/api/chat` NDJSON transport (primary) and the `/v1/chat/completions` OpenAI-compat SSE transport (behind a feature flag). The critical correctness invariant is AGENT-04: NDJSON chunks carrying `tool_calls` arrive on the chunk PRECEDING the `done:true` terminator, so the decoder must read `tool_calls` on sight and never gate on `done`. This is the #1 documented Ollama transport gotcha in `CLAUDE.md`, and a naive `if chunk.done { emit tool calls }` loses every tool call silently.

Purpose: Phase 4's protocol-agnostic design is meaningless without a second implementation. Ollama is a first-class alternate (not a bolted-on fallback) per `CLAUDE.md` — swapping Opus ↔ local model is a `ProviderSelection` toggle. This plan fills the `Sources/OllamaProvider/` directory created in Plan 04-01 and adds the test target scaffolded there.

Output: A working `OllamaProvider` actor against a known-good local baseline (`qwen2.5-coder:32b` — never Qwen3/3.5 per RESEARCH-DELTAS D3), the `tool_calls`-on-sight invariant captured as both a unit test and a byte-replay fixture, and the AGENT-07 cap-recovery wiring (`ToolChoice.none` drops the `tools` array entirely — not `{type:none}`) verified.

**Scope note:** ~14 files, within the threshold. Three tasks: Task 1 = NDJSON decoder + request body; Task 2 = OpenAI-compat SSE decoder + provider actor; Task 3 = fixture corpus. All commits are atomic per task.
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
@.planning/phases/04-agent-core/04-01-SUMMARY.md

<interfaces>
<!-- Contracts established by Plan 04-01 that this plan consumes -->

```swift
// From packages/AgentCore/Sources/AgentCore/LLMProvider.swift
public protocol LLMProvider: Sendable {
    func stream(
        messages: [LLMMessage], tools: [ToolSchema], toolChoice: ToolChoice,
        model: ModelID, maxOutputTokens: Int, cacheHints: CacheHints?
    ) -> AsyncThrowingStream<LLMEvent, Error>
}

// From packages/AgentCore/Sources/AgentCore/LLMEvent.swift
public enum LLMEvent: Sendable {
    case messageStart(LLMMessageStart), textDelta(String), thinkingDelta(String),
         toolUseRequested(ToolUseRequest), toolUseBuffering(toolUseId: String),
         partialToolUseAtDisconnect(ToolUseRequest), stopReason(StopReason),
         usage(TurnUsage), providerError(LLMProviderError), messageStop
}
public struct ToolUseRequest: Sendable, Equatable {
    public let id: String, name: String, argsJSON: Data
}

// From packages/AgentCore/Sources/AgentCore/ToolChoice.swift
public enum ToolChoice: Sendable, Equatable { case auto, none, any, tool(name: String) }

// From packages/AgentCore/Sources/AgentCore/ModelID.swift
public static let qwen25coder32b = ModelID(rawValue: "qwen2.5-coder:32b")
```

<!-- Contracts this plan ESTABLISHES that Plan 04-04 (orchestrator) consumes -->

```swift
public actor OllamaProvider: LLMProvider {
    public init(
        baseURL: URL,                          // from LaunchSnapshot.ollama.baseURL — AGENT-05 validated
        session: URLSession = .shared,
        useOpenAICompat: Bool = false          // false = /api/chat NDJSON; true = /v1/chat/completions SSE
    )
    public nonisolated func stream(...) -> AsyncThrowingStream<LLMEvent, Error>
}
```

From Phase 1 `packages/Config/Sources/Config/OllamaConfig.swift`:
- `baseURL: URL` — already validated to host ∈ {127.0.0.1, localhost, ::1} at config decode time; this plan passes it through verbatim.
</interfaces>

<codebase_patterns>
- Swift 6 strict concurrency — `.swiftLanguageMode(.v6)` on the target (inherited from Package.swift in Plan 04-01).
- Fetch-per-request is NOT applicable — Ollama has no auth (it's localhost-only).
- Decoder state machines live in their own file separate from the provider actor (matches Plan 04-01 AnthropicProvider layout: provider = transport + lifecycle; decoder = stateful parser).
- `grep -v '^//' <file> | grep -c <token>` is the mandatory pattern for grep gates (self-invalidating grep gate rule).
- Do NOT use `SQLite.swift`, `OllamaKit`, or any Ollama SDK — hand-rolled URLSession per research §4 (rationale: we need `/api/chat` NDJSON support that most SDKs gloss over).
</codebase_patterns>
</context>

<tasks>

<task type="auto" tdd="true">
  <name>Task 1: NDJSONDecoder + OllamaRequestBody — AGENT-04 tool_calls-on-sight + AGENT-07 drop-tools-array</name>
  <files>
    packages/AgentCore/Sources/OllamaProvider/NDJSONDecoder.swift,
    packages/AgentCore/Sources/OllamaProvider/OllamaRequestBody.swift,
    packages/AgentCore/Tests/OllamaProviderTests/NDJSONDecoderTests.swift,
    packages/AgentCore/Tests/OllamaProviderTests/OllamaRequestBodyTests.swift
  </files>
  <behavior>
    - Test N1 (NDJSONDecoderTests): Happy-text NDJSON — 3 chunks with `message.content` non-empty and `done:false`, then 1 chunk with `done:true`, `done_reason:"stop"`, `eval_count:47` → decoder emits `.messageStart`, `.textDelta("x")`, `.textDelta("y")`, `.textDelta("z")`, `.stopReason(.endTurn)`, `.usage(TurnUsage(inputTokens:promptEvalCount, outputTokens:47, cacheCreationInputTokens:0, cacheReadInputTokens:0))`, `.messageStop`.
    - Test N2 (NDJSONDecoderTests, **critical AGENT-04 regression guard**): Chunk sequence is [ chunk1: `{"message":{"content":"let me check"}, "done":false}`, chunk2: `{"message":{"content":"","tool_calls":[{"function":{"name":"get_time","arguments":{"timezone":"UTC"}}}]},"done":false}`, chunk3: `{"message":{"content":""},"done":true,"done_reason":"stop"}`]. Decoder MUST emit `.toolUseRequested(ToolUseRequest(id: <UUID>, name: "get_time", argsJSON: Data("{\"timezone\":\"UTC\"}".utf8)))` upon chunk2 — NOT on chunk3. Test asserts the event is emitted before the `.stopReason` (by event-index order in the collected array).
    - Test N3 (NDJSONDecoderTests): `done_reason` mapping — `"stop"` → `.endTurn`, `"length"` → `.maxTokens`, `"tool_calls"` → `.toolUse`, missing `done_reason` BUT `tool_calls` was seen mid-stream → also `.toolUse`.
    - Test N4 (NDJSONDecoderTests): Mid-stream EOF (AsyncSequence ends after 2 chunks, no `done:true`) → decoder emits `.stopReason(.streamTruncated)`, `.messageStop`. NO `.partialToolUseAtDisconnect` (NDJSON is atomic per line; partial tool use is an Anthropic-only concept).
    - Test N5 (NDJSONDecoderTests): Parallel tool calls — single chunk with `tool_calls: [{function:{name:"a",...}}, {function:{name:"b",...}}]` emits two `.toolUseRequested` events in order.
    - Test N6 (NDJSONDecoderTests): Each `.toolUseRequested` id is a fresh UUID string (not empty, not duplicated across tool calls in the same chunk). Assertion: `UUID(uuidString: req.id) != nil` AND `req1.id != req2.id` for parallel calls.
    - Test N7 (NDJSONDecoderTests): Malformed JSON line (e.g. `{"incomplete":`) → decoder emits `.providerError(.decode(reason: ...))` then `.messageStop`; the stream terminates cleanly.
    - Test R1 (OllamaRequestBodyTests, **critical AGENT-07 regression guard**): `ToolChoice.none` produces a request body JSON that does NOT contain the key `"tools"` at all. `JSONSerialization.jsonObject(with: body)` as `[String: Any]` → `body["tools"] == nil`.
    - Test R2 (OllamaRequestBodyTests): `ToolChoice.auto` + non-empty tools → body contains `"tools": [...]` array with each tool's `name`, `description`, `parameters` (Ollama uses `parameters` not `input_schema`).
    - Test R3 (OllamaRequestBodyTests): `ToolChoice.tool(name: "get_time")` → tools array is present AND a synthetic system message hint `"Please use the get_time tool."` is appended to the messages array. Comment: Ollama has no first-class force; hint is best-effort.
    - Test R4 (OllamaRequestBodyTests): Model string passes through — `ModelID.qwen25coder32b` → body `"model":"qwen2.5-coder:32b"`.
    - Test R5 (OllamaRequestBodyTests): `"stream": true` is present in body.
    - Test R6 (OllamaRequestBodyTests): Messages with `.toolResult` content blocks are encoded as `role:"tool"` messages with `content: "<string>"` and `tool_call_id: "<id from ToolUseRequest.id>"` — Ollama's native shape.
  </behavior>
  <action>
Delete `packages/AgentCore/Sources/OllamaProvider/Placeholder.swift` that was created in Plan 04-01.

**`OllamaRequestBody.swift`**:

```swift
import Foundation
import AgentCore

enum OllamaRequestBody {
    /// Native /api/chat body shape.
    static func encodeNative(
        messages: [LLMMessage],
        tools: [ToolSchema],
        toolChoice: ToolChoice,
        model: ModelID,
        maxOutputTokens: Int,
        stream: Bool = true
    ) throws -> Data

    /// OpenAI-compat /v1/chat/completions body shape.
    static func encodeOpenAICompat(...) throws -> Data
}
```

Native body JSON:
```json
{
  "model": "qwen2.5-coder:32b",
  "messages": [{"role":"user","content":"..."}, {"role":"tool","content":"...","tool_call_id":"..."}],
  "tools": [{"type":"function","function":{"name":"get_time","description":"...","parameters":{...}}}],
  "stream": true,
  "options": {"num_predict": 8192}
}
```
- `tools` field **omitted entirely** when `toolChoice == .none` — this is the AGENT-07 critical invariant. Verified by Test R1.
- For `.tool(name: n)`, append a synthetic system message at the end of `messages`: `{"role":"system","content":"Please use the \(n) tool."}`. Comment in code: "Ollama has no first-class tool-choice.force; this is best-effort."
- For `.any`, include tools array; no special hint.
- For `.auto`, include tools array; no special hint.
- `ToolSchema.inputSchema` — Ollama uses `parameters` key, not `input_schema`. Pass through as JSON object (not double-encoded).
- `LLMMessage.Role.tool` maps to `"role":"tool"`. `ContentBlock.toolResult` serializes content as a simple string (Ollama expects plain-string content for tool messages; an array-of-content-blocks is Anthropic-only).
- `ContentBlock.toolUse` in assistant messages serializes to `"tool_calls": [{"id":..., "function":{"name":..., "arguments":{...}}}]` — Ollama shape.
- Include `options.num_predict: maxOutputTokens`.

OpenAI-compat body JSON (used when `useOpenAICompat == true`):
```json
{
  "model": "qwen2.5-coder:32b",
  "messages": [...],
  "tools": [{"type":"function","function":{"name":"...","description":"...","parameters":{...}}}],
  "tool_choice": "none|auto|{\"type\":\"function\",\"function\":{\"name\":\"...\"}}",
  "stream": true,
  "max_tokens": 8192
}
```
For the OpenAI-compat path, `ToolChoice.none` serializes `"tool_choice":"none"` as a string (OpenAI shape). Tools array can still be present — on OpenAI-compat the `"tool_choice":"none"` string suppresses tool use. This is deliberately different from the native path per research §4.

**`NDJSONDecoder.swift`**:

```swift
import Foundation
import AgentCore

struct NDJSONDecoder {
    private(set) var messageId: String?
    private(set) var modelName: String?
    private(set) var emittedMessageStart = false
    private(set) var sawToolCalls = false
    private(set) var promptEvalCount: Int = 0   // input tokens accumulator from chunks
    private(set) var messageStopEmitted = false

    mutating func dispatch(line: Data, into cont: AsyncThrowingStream<LLMEvent, Error>.Continuation)

    mutating func flushOnEOF(into cont: AsyncThrowingStream<LLMEvent, Error>.Continuation)
}
```

Per-line logic:
1. Parse `line` as JSON. If it fails, emit `.providerError(.decode(reason: ...))` + set `messageStopEmitted = true` + call `cont.finish()` and return.
2. If `emittedMessageStart` is false, emit `.messageStart(LLMMessageStart(messageId: UUID().uuidString, model: parsed.model, usagePrefix: nil))` and set flag true. (Ollama doesn't have a message_start semantic; we synthesize one so the orchestrator sees the same shape as Anthropic.)
3. If `parsed.message.tool_calls` is a non-nil non-empty array, for each entry:
   - Extract `function.name` (String) and `function.arguments` (any JSON value — re-serialize to Data for argsJSON).
   - Emit `.toolUseBuffering(toolUseId: uuid)` followed by `.toolUseRequested(ToolUseRequest(id: uuid, name: functionName, argsJSON: argsData))`.
   - Set `sawToolCalls = true`.
4. If `parsed.message.content` is a non-empty string, emit `.textDelta(content)`.
5. If `parsed.prompt_eval_count` is an Int, add to `promptEvalCount` accumulator.
6. If `parsed.done == true`:
   - Map `done_reason` → StopReason: `"stop"` → `.endTurn` (unless `sawToolCalls` then `.toolUse`), `"length"` → `.maxTokens`, `"tool_calls"` → `.toolUse`, missing → if `sawToolCalls` then `.toolUse` else `.endTurn`.
   - Emit `.stopReason(mapped)`.
   - Emit `.usage(TurnUsage(inputTokens: promptEvalCount, outputTokens: parsed.eval_count ?? 0, cacheCreationInputTokens: 0, cacheReadInputTokens: 0))`.
   - Emit `.messageStop`. Set `messageStopEmitted = true`.

`flushOnEOF` logic (called when the AsyncSequence of bytes ends WITHOUT seeing `done:true`):
- If `messageStopEmitted` is true, do nothing.
- Else emit `.stopReason(.streamTruncated)`, `.usage(TurnUsage(inputTokens: promptEvalCount, outputTokens: 0, ...))`, `.messageStop`.

**Critical test for N2:** Because the emission ordering is load-bearing (tool_calls MUST fire before stop_reason), the test collects events into a `var events: [LLMEvent]` array, then asserts both the presence AND the index ordering.

Commit: `feat(04-02): NDJSONDecoder with tool_calls-on-sight invariant + OllamaRequestBody drop-tools-array on .none (AGENT-04, AGENT-07)`.
  </action>
  <verify>
    <automated>cd packages/AgentCore && swift build 2>&1 | tee /tmp/build-04-02-t1.log && swift test --filter OllamaProviderTests.NDJSONDecoderTests --filter OllamaProviderTests.OllamaRequestBodyTests 2>&1 | tee /tmp/test-04-02-t1.log && grep -c "Test Suite 'All tests' passed" /tmp/test-04-02-t1.log</automated>
  </verify>
  <done>
    - `cd packages/AgentCore && swift test --filter NDJSONDecoderTests --filter OllamaRequestBodyTests` exits 0; at least 13 tests pass.
    - `grep -v '^//' packages/AgentCore/Sources/OllamaProvider/NDJSONDecoder.swift | grep -c 'tool_calls'` ≥ 2 (at least one for the JSON key and one for the logic).
    - `grep -v '^//' packages/AgentCore/Sources/OllamaProvider/NDJSONDecoder.swift | grep -c 'done:' ` = 0 AND `grep -v '^//' packages/AgentCore/Sources/OllamaProvider/NDJSONDecoder.swift | grep -c 'if.*done.*tool_calls'` = 0 (regression guard — no code path gates tool_calls emission on done).
    - `grep -c 'qwen2.5-coder:32b\|qwen3' packages/AgentCore/Sources/OllamaProvider/` (recursive) finds `qwen2.5-coder:32b` but NO `qwen3` / `qwen3.5` (per RESEARCH-DELTAS D3).
  </done>
</task>

<task type="auto" tdd="true">
  <name>Task 2: OpenAICompatDecoder + OllamaProvider actor + transport wiring</name>
  <files>
    packages/AgentCore/Sources/OllamaProvider/OpenAICompatDecoder.swift,
    packages/AgentCore/Sources/OllamaProvider/OllamaProvider.swift,
    packages/AgentCore/Tests/OllamaProviderTests/OpenAICompatDecoderTests.swift
  </files>
  <behavior>
    - Test O1 (OpenAICompatDecoderTests): Standard SSE `data: {"choices":[{"delta":{"content":"hello"},"finish_reason":null}]}` → emits `.textDelta("hello")`.
    - Test O2 (OpenAICompatDecoderTests): `data: [DONE]` sentinel → emits `.stopReason(.endTurn)`, `.usage(...)`, `.messageStop`.
    - Test O3 (OpenAICompatDecoderTests): `finish_reason: "stop"` → `.endTurn`; `"length"` → `.maxTokens`; `"tool_calls"` → `.toolUse`.
    - Test O4 (OpenAICompatDecoderTests): Tool call comes atomically — `data: {"choices":[{"delta":{"tool_calls":[{"id":"call_X","function":{"name":"get_time","arguments":"{\"timezone\":\"UTC\"}"}}]}}]}` → emits ONE `.toolUseRequested(ToolUseRequest(id:"call_X", name:"get_time", argsJSON: <decoded from stringified JSON>))`. NB: OpenAI emits arguments as a JSON-encoded STRING, unlike Ollama native which uses an object — decoder handles both.
    - Test O5 (OpenAICompatDecoderTests): Mid-stream EOF (no `[DONE]`) → emits `.stopReason(.streamTruncated)`, `.messageStop`.
    - Test P1 (build-only — covered by test R1/R2/R3 above integration): OllamaProvider conforms to LLMProvider (compile test — the actor declaration references the protocol).
  </behavior>
  <action>
**`OpenAICompatDecoder.swift`** — SSE state machine for the OpenAI-compat path. Similar shape to Anthropic's SSEDecoder but distinct state:

```swift
struct OpenAICompatDecoder {
    private(set) var emittedMessageStart = false
    private(set) var messageStopEmitted = false
    private(set) var capturedStopReason: StopReason?
    private(set) var toolCallArgBuffers: [String: Data] = [:]   // keyed by call_id — OpenAI can split args across deltas in theory
    private(set) var toolCallNames: [String: String] = [:]

    mutating func dispatch(line: String, into cont: AsyncThrowingStream<LLMEvent, Error>.Continuation)
    mutating func flushOnEOF(into cont: AsyncThrowingStream<LLMEvent, Error>.Continuation)
}
```

Per-line logic:
1. Strip `data: ` prefix. If the remainder is `[DONE]` → emit `.stopReason(capturedStopReason ?? .endTurn)`, `.usage(...)`, `.messageStop`, set `messageStopEmitted = true`.
2. Parse JSON. Extract `choices[0].delta`.
3. If `delta.content` is non-empty string → emit `.textDelta(content)`.
4. If `delta.tool_calls` present: for each entry, extract `id` (call_id), `function.name`, `function.arguments` (may be a String — the OpenAI-compat convention — decode as UTF-8 bytes directly; if it's an object, re-encode to Data). Merge into `toolCallArgBuffers[id]` (append; rare that OpenAI splits but safe to support). Set captured name.
5. If `choices[0].finish_reason` is non-nil, capture to `capturedStopReason` per mapping. Also at this point flush any accumulated tool_call buffers as `.toolUseRequested` events.
6. If `emittedMessageStart` is false, emit it first (synthesized).

**`OllamaProvider.swift`** — the actor:

```swift
public actor OllamaProvider: LLMProvider {
    private let baseURL: URL
    private let session: URLSession
    private let useOpenAICompat: Bool

    public init(baseURL: URL, session: URLSession = .shared, useOpenAICompat: Bool = false)

    public nonisolated func stream(
        messages: [LLMMessage], tools: [ToolSchema], toolChoice: ToolChoice,
        model: ModelID, maxOutputTokens: Int, cacheHints: CacheHints?
    ) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let path = useOpenAICompat ? "/v1/chat/completions" : "/api/chat"
                    var request = URLRequest(url: baseURL.appending(path: path))
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    if useOpenAICompat {
                        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                        request.httpBody = try OllamaRequestBody.encodeOpenAICompat(
                            messages: messages, tools: tools, toolChoice: toolChoice,
                            model: model, maxOutputTokens: maxOutputTokens, stream: true)
                    } else {
                        request.setValue("application/x-ndjson", forHTTPHeaderField: "Accept")
                        request.httpBody = try OllamaRequestBody.encodeNative(
                            messages: messages, tools: tools, toolChoice: toolChoice,
                            model: model, maxOutputTokens: maxOutputTokens, stream: true)
                    }
                    let (bytes, response) = try await session.bytes(for: request)
                    try assertHTTP2xx(response)

                    if useOpenAICompat {
                        var decoder = OpenAICompatDecoder()
                        for try await line in bytes.lines {
                            if line.isEmpty { continue }
                            decoder.dispatch(line: line, into: continuation)
                            if decoder.messageStopEmitted { break }
                        }
                        if !decoder.messageStopEmitted { decoder.flushOnEOF(into: continuation) }
                    } else {
                        var decoder = NDJSONDecoder()
                        for try await line in bytes.lines {
                            if line.isEmpty { continue }
                            decoder.dispatch(line: Data(line.utf8), into: continuation)
                            if decoder.messageStopEmitted { break }
                        }
                        if !decoder.messageStopEmitted { decoder.flushOnEOF(into: continuation) }
                    }
                    continuation.finish()
                } catch {
                    continuation.yield(.providerError(.transport(description: error.localizedDescription)))
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
```

`assertHTTP2xx` — shared helper; can live in the same file (small internal func). On non-2xx, read body synchronously via `String(data: ..., encoding: .utf8)` and throw `LLMProviderError.api(statusCode:..., body:...)`.

Commit: `feat(04-02): OllamaProvider actor + OpenAI-compat SSE decoder behind feature flag`.
  </action>
  <verify>
    <automated>cd packages/AgentCore && swift build 2>&1 | tee /tmp/build-04-02-t2.log && swift test --filter OllamaProviderTests.OpenAICompatDecoderTests 2>&1 | tee /tmp/test-04-02-t2.log && grep -c "Test Suite 'All tests' passed" /tmp/test-04-02-t2.log</automated>
  </verify>
  <done>
    - `cd packages/AgentCore && swift test --filter OpenAICompatDecoderTests` exits 0 with 5 tests passing.
    - `grep -c 'OllamaProvider: LLMProvider' packages/AgentCore/Sources/OllamaProvider/OllamaProvider.swift` ≥ 1 (conformance present).
    - `grep -c 'useOpenAICompat' packages/AgentCore/Sources/OllamaProvider/OllamaProvider.swift` ≥ 2 (param declared + used for path branching).
    - `grep -c 'application/x-ndjson' packages/AgentCore/Sources/OllamaProvider/OllamaProvider.swift` ≥ 1 (native path content-type).
    - `grep -c 'text/event-stream' packages/AgentCore/Sources/OllamaProvider/OllamaProvider.swift` ≥ 1 (compat path content-type).
  </done>
</task>

<task type="auto" tdd="true">
  <name>Task 3: Byte-replay fixture corpus — 6 recorded NDJSON + SSE streams</name>
  <files>
    packages/AgentCore/Tests/OllamaProviderTests/FixtureReplayTests.swift,
    packages/AgentCore/Tests/OllamaProviderTests/Fixtures/happy-text.txt,
    packages/AgentCore/Tests/OllamaProviderTests/Fixtures/text-then-tool-call.txt,
    packages/AgentCore/Tests/OllamaProviderTests/Fixtures/parallel-tool-calls.txt,
    packages/AgentCore/Tests/OllamaProviderTests/Fixtures/mid-stream-eof.txt,
    packages/AgentCore/Tests/OllamaProviderTests/Fixtures/openai-compat-happy.txt,
    packages/AgentCore/Tests/OllamaProviderTests/Fixtures/openai-compat-tool-call.txt
  </files>
  <behavior>
    - Test F1 (FixtureReplayTests): `happy-text.txt` (NDJSON) → decoder produces `[.messageStart, .textDelta×N, .stopReason(.endTurn), .usage, .messageStop]`.
    - Test F2 (FixtureReplayTests, **AGENT-04 regression guard at fixture level**): `text-then-tool-call.txt` — chunk 1 is text, chunk 2 has `tool_calls` AND `done:false`, chunk 3 is `done:true`. Assert `.toolUseRequested` event appears BEFORE `.stopReason` in the collected events array. This mirrors Test N2 but pulled from an on-disk fixture file (guards against someone "fixing" the test inline but not the production code).
    - Test F3 (FixtureReplayTests): `parallel-tool-calls.txt` → single NDJSON chunk with two `tool_calls` entries → emits two `.toolUseRequested` events.
    - Test F4 (FixtureReplayTests): `mid-stream-eof.txt` → file ends after 2 chunks, neither with `done:true` → decoder emits `.stopReason(.streamTruncated)` + `.messageStop`.
    - Test F5 (FixtureReplayTests): `openai-compat-happy.txt` via `OpenAICompatDecoder` → emits standard sequence terminating with `[DONE]`.
    - Test F6 (FixtureReplayTests): `openai-compat-tool-call.txt` → single `data:` frame carrying `tool_calls` atomically → emits `.toolUseRequested` with the correct id/name/args.
  </behavior>
  <action>
Update `packages/AgentCore/Package.swift` test target for `OllamaProviderTests` to declare `resources: [.process("Fixtures")]`.

Hand-craft 6 fixture files:

**`happy-text.txt`** — NDJSON, 4 lines:
```
{"model":"qwen2.5-coder:32b","created_at":"2026-04-22T00:00:00Z","message":{"role":"assistant","content":"Hello"},"done":false}
{"model":"qwen2.5-coder:32b","created_at":"2026-04-22T00:00:00Z","message":{"role":"assistant","content":" world"},"done":false}
{"model":"qwen2.5-coder:32b","created_at":"2026-04-22T00:00:00Z","message":{"role":"assistant","content":"!"},"done":false}
{"model":"qwen2.5-coder:32b","created_at":"2026-04-22T00:00:00Z","message":{"role":"assistant","content":""},"done":true,"done_reason":"stop","prompt_eval_count":12,"eval_count":3}
```

**`text-then-tool-call.txt`** — NDJSON, 3 lines:
```
{"model":"qwen2.5-coder:32b","message":{"role":"assistant","content":"let me check"},"done":false}
{"model":"qwen2.5-coder:32b","message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"get_time","arguments":{"timezone":"UTC"}}}]},"done":false}
{"model":"qwen2.5-coder:32b","message":{"role":"assistant","content":""},"done":true,"done_reason":"tool_calls","prompt_eval_count":14,"eval_count":8}
```

**`parallel-tool-calls.txt`** — NDJSON, 2 lines:
```
{"model":"qwen2.5-coder:32b","message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"get_time","arguments":{}}},{"function":{"name":"get_clipboard","arguments":{}}}]},"done":false}
{"model":"qwen2.5-coder:32b","message":{"role":"assistant","content":""},"done":true,"done_reason":"tool_calls","prompt_eval_count":20,"eval_count":12}
```

**`mid-stream-eof.txt`** — NDJSON, 2 lines, no `done:true`:
```
{"model":"qwen2.5-coder:32b","message":{"role":"assistant","content":"partial"},"done":false}
{"model":"qwen2.5-coder:32b","message":{"role":"assistant","content":" response"},"done":false}
```

**`openai-compat-happy.txt`** — SSE:
```
data: {"id":"chatcmpl-x","choices":[{"delta":{"role":"assistant","content":"Hello"},"index":0}]}

data: {"id":"chatcmpl-x","choices":[{"delta":{"content":" world"},"index":0}]}

data: {"id":"chatcmpl-x","choices":[{"delta":{},"index":0,"finish_reason":"stop"}]}

data: [DONE]

```

**`openai-compat-tool-call.txt`** — SSE:
```
data: {"id":"chatcmpl-y","choices":[{"delta":{"role":"assistant","tool_calls":[{"id":"call_X","type":"function","function":{"name":"get_time","arguments":"{\"timezone\":\"UTC\"}"}}]},"index":0}]}

data: {"id":"chatcmpl-y","choices":[{"delta":{},"index":0,"finish_reason":"tool_calls"}]}

data: [DONE]

```

**`FixtureReplayTests.swift`**:
- Loads each fixture via `Bundle.module.url(forResource:, withExtension: "txt")`.
- Creates an `AsyncStream<UInt8>` from the file bytes.
- For NDJSON fixtures: splits on `\n`, calls `NDJSONDecoder.dispatch` per non-empty line.
- For SSE fixtures: calls a small SSE line reader (can reuse the one from `AnthropicProvider/SSELineReader.swift` via `@testable import AnthropicProvider`, OR inline a simple line splitter — inline is simpler since this is test-only).
- Collects LLMEvents into an array and asserts expected event sequence using the same `ExpectedEvent` reduced enum pattern from Plan 04-01 Task 3 (hoist to a shared `TestHelpers/ExpectedEvent.swift` under `Tests/` so both test targets can use it — add to Package.swift as a test helper target if easier, or duplicate the enum inline; duplication is acceptable for 10 lines).

Commit: `test(04-02): byte-replay fixture corpus — 6 NDJSON + SSE streams with AGENT-04 regression guard`.
  </action>
  <verify>
    <automated>cd packages/AgentCore && swift test --filter OllamaProviderTests.FixtureReplayTests 2>&1 | tee /tmp/test-04-02-t3.log && grep -c "Test Suite 'All tests' passed" /tmp/test-04-02-t3.log</automated>
  </verify>
  <done>
    - `ls packages/AgentCore/Tests/OllamaProviderTests/Fixtures/ | wc -l` equals 6.
    - `cd packages/AgentCore && swift test --filter OllamaProviderTests.FixtureReplayTests` exits 0 with 6 tests passing.
    - `cd packages/AgentCore && swift test` exits 0 for the entire package (AgentCoreTests + AnthropicProviderTests + OllamaProviderTests all pass together).
    - `grep -q '"tool_calls"' packages/AgentCore/Tests/OllamaProviderTests/Fixtures/text-then-tool-call.txt` succeeds.
    - `grep -q '"done":true' packages/AgentCore/Tests/OllamaProviderTests/Fixtures/text-then-tool-call.txt` succeeds.
    - `grep -c '"done":true' packages/AgentCore/Tests/OllamaProviderTests/Fixtures/mid-stream-eof.txt` equals 0 (fixture deliberately truncated before done).
    - `grep -q "\[DONE\]" packages/AgentCore/Tests/OllamaProviderTests/Fixtures/openai-compat-happy.txt` succeeds.
  </done>
</task>

</tasks>

<threat_model>
## Trust Boundaries

| Boundary | Description |
|----------|-------------|
| Ollama HTTP server → Swift process | Loopback-only (127.0.0.1 / localhost / ::1 per AGENT-05 already validated). Still untrusted in the prompt-injection sense — responses may contain model-generated injection attempts. |
| `LLMMessage.untrusted` → prompt space | Same as Plan 04-01 — orchestrator handles `turnNonce` wrapping in Plan 04-04. |

## STRIDE Threat Register

| Threat ID | Category | Component | Disposition | Mitigation Plan |
|-----------|----------|-----------|-------------|-----------------|
| T-04-02-01 | Tampering | NDJSON chunk reordering by a compromised local Ollama | accept | Loopback-only transport + single-user personal project; if attacker owns the Ollama process, they own everything anyway. Documented threat, accepted risk. |
| T-04-02-02 | Information Disclosure | `LLMProviderError.api(body:)` bodies logged | mitigate | Ollama errors are typically `{"error":"model not found"}` — low sensitivity. `Redact.apply` still runs at the orchestrator logging boundary (Plan 04-04). No additional work in this plan. |
| T-04-02-03 | Denial of Service | Infinite NDJSON stream (Ollama hangs) | accept | Same as T-04-01-03 — orchestrator wraps in timeout (Plan 04-04). |
| T-04-02-04 | Elevation of Privilege | Attacker exploits `.none` ToolChoice regression (tools array not dropped) | mitigate | AGENT-07 critical defense. Test R1 asserts the JSON body omits `"tools"` key entirely on `.none`. Cap-recovery loop (Plan 04-04) relies on this — regression means infinite loop back into cap. Byte-level assertion is load-bearing, not a soft check. |
| T-04-02-05 | Repudiation | Tool call lost via `done`-gating regression | mitigate | AGENT-04 critical defense. Tests N2 + F2 (both fixture-based AND inline) verify tool_calls emission fires on `done:false` chunk. Production-code grep gate (`grep -c 'if.*done.*tool_calls' NDJSONDecoder.swift` = 0) ensures the bug cannot be reintroduced. |
| T-04-02-06 | Spoofing | Qwen3/3.5 silent swap into config surfaces a broken tool-calling baseline | mitigate | Per RESEARCH-DELTAS D3, Qwen3 tool-calling is broken upstream. Code-side grep asserts `qwen3` does not appear as a ModelID constant or in any OllamaProvider source file. Config-side (Plan 04-01 Task 1 did not add a constant for qwen3; `ModelID.qwen25coder32b` is the only one present). This plan re-asserts via grep. |
</threat_model>

<verification>
- `cd packages/AgentCore && swift build` — clean with zero new warnings.
- `cd packages/AgentCore && swift test` — all three test targets pass (AgentCoreTests + AnthropicProviderTests + OllamaProviderTests).
- Grep gates (per-task done criteria).
- Manual end-to-end is deferred to Plan 04-05 (TEXT-01 text-input end-to-end uses a live local Ollama).
</verification>

<success_criteria>
- `OllamaProvider` conforms to `LLMProvider` from Plan 04-01.
- NDJSON decoder emits `.toolUseRequested` on sight of `tool_calls` — AGENT-04 verified by unit test + fixture test (defence-in-depth).
- `OllamaRequestBody.encodeNative` omits the `tools` key entirely when `ToolChoice.none` — AGENT-07 verified by JSON-dictionary inspection test.
- `OpenAICompatDecoder` handles `data: [DONE]` sentinel and atomic tool_calls.
- Six fixture files exist and the fixture replay tests pass.
- No `qwen3` / `qwen3.5` references in source or tests (per RESEARCH-DELTAS D3).
- No Ollama SDK dependency in `Package.swift` (hand-rolled URLSession only).
</success_criteria>

<output>
After completion, create `.planning/phases/04-agent-core/04-02-SUMMARY.md` per the GSD summary template.
</output>
