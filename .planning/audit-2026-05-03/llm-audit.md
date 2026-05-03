# LLM Provider + Orchestrator + MCP Deep Audit (2026-05-03)

## TL;DR — Grade: **D+**

Verdict: **the wiring graph is impressive and the unit tests are real, but every actual production path past the `URLSession.bytes(...)` boundary is unverified — and the one symptom you have (200 + immediate EOF) is precisely the failure mode that this codebase has zero live-network tests against.** 50 hours of architecture have been poured into a fixture-replay + structural-composition test pyramid that proves the Swift code will *correctly handle a recorded fixture* without proving any byte ever traveled to or from a real Anthropic / Ollama / MCP-helper process under app-launch conditions.

---

## 1. AnthropicProvider — most likely cause of `streamTruncatedFinal`

The HTTP path is fine (verified against curl). The SSE state machine handles every documented edge case correctly. The bug is **on the wire, not in decode**, and the Swift code has one specific behavior that *will* manifest as `streamTruncatedFinal` even when the curl-equivalent succeeds.

### Tracing the symptom

`AnthropicProvider.run` (`packages/AgentCore/Sources/AnthropicProvider/AnthropicProvider.swift:119-220`):

1. Builds body (line 134-150) — encoder uses `.sortedKeys` so JSON is deterministic.
2. Fetches API key per request via injected closure (line 152-160). **This is where the key bug lives — see §1c below.**
3. Performs HTTP (line 166).
4. Status check at line 175 — if non-2xx, drains body and emits `.providerError(.api(...))`. Good.
5. Wires `SSELineReader → SSEDecoder` (line 196-211).
6. **Key hot-path:** if EOF arrives before `message_stop`, line 207 calls `SSEDecoder.flushOnEOF`, which (`SSEDecoder.swift:69-87`) **synthesizes** `.stopReason(.streamTruncated)` + `.messageStop`. The orchestrator retries once (`AgentOrchestrator.swift:550-606`), gets the same EOF, and emits `.streamTruncatedFinal` (line 607-614). Exactly the symptom you describe.

### a. The empty-stream collapse bug (`SSEDecoder.flushOnEOF` semantics)

`SSEDecoder.flushOnEOF` (`SSEDecoder.swift:69-87`) handles three cases, and one is wrong for diagnosis:

- If a tool-use was buffering → emit `partialToolUseAtDisconnect`. ✓
- If `message_stop` was already emitted → `guard` returns. ✓
- **Otherwise → emit `.stopReason(.streamTruncated)` unconditionally.**

That third branch fires for **two distinct underlying conditions**:
1. Real mid-stream truncation after some events were received.
2. **Empty stream** — server closed before sending a single byte after `200 OK`.

The decoder collapses these to the same event. Combined with `AnthropicProvider.swift:175-193` (which only emits `.providerError` for non-2xx), an Anthropic 200 + zero-byte body is **indistinguishable from "we got 5 deltas then it dropped"** at the orchestrator layer. **Both look like `streamTruncated` → retry → `streamTruncatedFinal`.**

This is your symptom. The Swift code is correctly identifying that nothing arrived. It is *not* telling you why nothing arrived.

### b. The most likely root cause — `cache_control` on a too-small system prompt

`AppDelegate.swift:931` sets the system prompt to:

```
You are Jarvis, a personal macOS assistant.
```

40 characters. ~10 tokens.

`AgentOrchestrator.swift:351, 360` passes `cacheHints: CacheHints(systemPromptTTL: .extended1h)` on every Anthropic call. `RequestBody.encodeCacheControl` (`RequestBody.swift:132-142`) emits `{"type":"ephemeral","ttl":"1h"}` on the first system block. **Anthropic's prompt cache requires a minimum of 1024 tokens per cache breakpoint for Sonnet/Opus models.** Below that, Anthropic's documented behavior is to return an SSE error frame after `200 OK`. If the error frame is mis-formatted in a way SSELineReader doesn't pick up, or if the server simply closes the connection on cache validation failure (some Anthropic edge cases do this for invalid `cache_control` shape combined with extended-ttl beta), **you get 200 + immediate close.**

Curl reproduction "rules out URL/model/network" — but does it reproduce **with the exact same body bytes**? The most efficient diagnostic now is to dump the request body bytes from `RequestBody.encodeMultimodal` to a file, then `curl --data-binary @body.json`. If curl also EOFs, you've found it. Predicted: it will.

**Mitigation:** drop `CacheHints` until your system prompt is ≥1024 tokens, or pass `nil` cacheHints from the orchestrator until the prompt grows. The code has the right plumbing — just don't enable extended cache on a 10-token prompt. Note the unit test suite has `testNoCacheControlWithoutHints` and `testEphemeral5mProducesNoCacheControl` (`RequestBodyTests.swift:32, 49`) but **no test that exercises a real Anthropic 400 response to invalid cache_control** — because there's no live test at all.

### c. Other rule-outs (in descending likelihood)

- **`anthropic-beta: extended-cache-ttl-2025-04-11`** — confirmed valid per CLAUDE.md. Not the cause.
- **API key from Keychain malformed** — `AppDelegate.swift:885-887` does `(try? keychainStoreLocal.get(.anthropic)) ?? ""`. If the Keychain throws or returns nil, you send `x-api-key: ""` — **but Anthropic returns 401 not 200**. So this isn't your symptom. (It is, however, a HI-01-shaped lurking bug — the API key gets `try?`'d into "" and the orchestrator gets a 401 with no log of the underlying KeychainError.)
- **Tools array shape** — `RequestBody.swift:89` correctly omits `tools` when empty. `AppDelegate.swift:932` passes `availableTools: []`. So tools field is absent. No issue.
- **Body encoding double-string** — `RequestBodyTests.swift:114-137` proves `input_schema` is inline-JSON not string-escaped. ✓
- **Tool-choice default** — `EncodedToolChoice` is always emitted (`RequestBody.swift:121-128`), defaulting to `auto`. Anthropic accepts. ✓
- **Beta header conflict** — only one `anthropic-beta` header is set. No conflict.

### d. What the Anthropic test suite actually covers

`packages/AgentCore/Tests/AnthropicProviderTests/`:

- `SSEDecoderTests.swift` — 12 tests, all **REAL** unit tests against the in-process decoder. Covers ping swallow, refusal, partial tool use, mid-stream EOF, etc. Does **NOT** cover empty-stream EOF (the case you're hitting). Does not cover an actual `200 + 0 bytes` close.
- `FixtureReplayTests.swift` — 9 tests replaying recorded fixture `.txt` files through the decoder. **REAL** at the decode layer. **MOCK** at the network layer — no `URLSession`, no `URLProtocol` stub, no localhost server.
- `RequestBodyTests.swift` — 8 tests, **REAL** byte-level encoding assertions.
- `AnthropicImageBlockEncodingTests.swift` — vision encoding, REAL.
- **There is zero test that:**
  - Stands up a `URLProtocol` mock server that returns `200` + immediate EOF and asserts `.streamTruncated` is emitted (this would have *immediately* proved your bug class is reachable).
  - Hits api.anthropic.com with a recorded API key in CI (rightly skipped, but no opt-in flag exists either).
  - Sends a `cache_control` request to a mock Anthropic server with a too-small system prompt and asserts the error path.

---

## 2. OllamaProvider — does it actually work?

**Decoders are real and well-tested. End-to-end against `http://127.0.0.1:11434` is structurally untouched.**

- `OllamaProvider.swift:21-200` — clean. Handles both `/api/chat` (NDJSON) and `/v1/chat/completions` (SSE) per CLAUDE.md transport gotchas.
- `NDJSONDecoderTests.swift` — 14 tests. Covers `testToolCallsOnNonTerminatorChunk_AGENT04` which is exactly the CLAUDE.md gotcha. **REAL.**
- `OpenAICompatDecoderTests.swift` — 7 tests. **REAL.**
- `OllamaRequestBodyTests.swift` — `testToolChoiceNone_DropsToolsArrayEntirely_AGENT07` proves cap-recovery wiring. **REAL.**

**Production wiring (`AppDelegate.swift:888-890`):**

```swift
case .ollama:
    return OllamaProvider(baseURL: URL(string: "http://127.0.0.1:11434")!)
```

- `useOpenAICompat: false` → uses `/api/chat` NDJSON path.
- Model resolved via `AgentOrchestrator.swift:671-676` → `.qwen25coder32b` ("qwen2.5-coder:32b"). **Correct per CLAUDE.md.** Qwen3 is not wired anywhere — good.
- `URL(string:...)!` force-unwrap is fine (literal won't fail).

**But:** there is **no end-to-end test that spawns a local `ollama serve` (or a mock 11434 listener) and asserts `qwen2.5-coder:32b` actually streams a response.** Decoder unit tests exhaustively cover NDJSON-shape edge cases. Network-shape edge cases (Ollama returning 404 on missing model, hanging on cold model load, etc.) are unverified.

If today you flipped `ProviderSelection` to `.ollama`, behavior is **probably** correct — but you'd be the first runtime to find out. There's no integration smoke test on disk.

---

## 3. AgentOrchestrator — race-condition audit

The fix in 048ab08 addressed one race (mcpInstallTask awaited from agentInstallTask). Walking through every `Task { }` in `installAgent` and the surrounding boot sequence:

### `applicationWillFinishLaunching` (`AppDelegate.swift:485-572`)

| # | Task | Awaits | Concern |
|---|------|--------|---------|
| 10 | `mcpInstallTask` (line 485) | nothing — kicks off MCPRuntimeWiring.build | **OK now**: agentInstallTask awaits at line 556. |
| 11 | `memoryInstallTask` (line 508) | nothing | OK — agent awaits at line 554. |
| 12 | `visionInstallTask` (line 526) | nothing | OK — agent awaits at line 555. |
| 13 | `agentInstallTask` (line 553-558) | memory + vision + mcp | The fix you made. Correct. |
| 14 | `voiceInstallTask` (line 569) | agent | Correct. |

### `installAgent` internal subscriber tasks

- `memoryEventSubscriberTask` (line 970) — subscribes broadcaster, awaits coord.start. Strong-self via `[weak self]`. **OK.**
- `transcriptSubscriberTask` (line 997) — broadcaster .transcript drain. **OK.**
- `devOverlaySubscriberTask` (line 1015) — drains discard. **OK.**
- `frameAttachReleaseTask` (line 1034) — broadcaster .frameAttach drain. **OK.**
- `voiceEventTranslatorTask` (line 1062) — broadcaster .voice drain. **OK.**
- `busSubscriberTask` (line 1113) — broadcaster .bus drain → BusForwarder. **OK.**

### Latent race: `outboundBatcher` construction order

`AppDelegate.swift:955-959`:

```swift
if self.outboundBatcher == nil, let bridge = self.webviewBridge {
    self.outboundBatcher = OutboundBatcher(sink: bridge)
} else if self.webviewBridge == nil {
    systemLogger?.warning("installAgent: webviewBridge nil — outboundBatcher not constructed; bus forwarder will drop events")
}
```

`installAgent` runs from `agentInstallTask`. `webviewBridge` is set from a different code path (the WKWebView's `didFinish` navigation handler at line 1722). **If the webview hasn't finished navigating by the time `installAgent` runs, `outboundBatcher` is permanently nil and the bus subscriber drains events into the void.** No retry, no observer, no future hook to construct the batcher when the webview later arrives.

This is plausibly a real race. Symptoms: token deltas reach the broadcaster, the bus subscriber drains them, but the chat panel sees nothing. Recommend: make `outboundBatcher` construction lazy or add a webview-ready hook that re-attempts construction.

### Latent race: `replayLog.beginSession` failure → silent return

`AppDelegate.swift:920-924` — if `beginSession` throws, `installAgent` logs and returns **without ever constructing the orchestrator**. `agentOrchestrator` stays nil. Every subsequent `chatSubmit → orchestrator?.submit(...)` silently no-ops. **No banner, no chat-panel feedback, no auto-retry.** This is a hard footgun. The session-FK fix (Phase E) addressed the *cause* of beginSession failures, but the *handler* still drops on the floor.

### `AgentOrchestrator.runTurnLoop` — internal correctness

- Cancellation handling (line 366-369, 650-651): correct — checks `Task.isCancelled` and `CancellationError`.
- Cap-recovery (line 333-334): tools array empty + `toolChoice: .none`. Correct per AGENT-07.
- `streamTruncated` retry (line 550-606): retry budget, fresh TurnID, retryOf set. Correct per AGENT-09.
- **Tool-result error path (line 437-455):** if `toolDispatcher.dispatch` throws, ERROR text is concatenated into the model's tool_result. The model can absorb this, but ERROR strings can leak file paths / stderr. (Not your current bug; future prompt-injection surface.)

The orchestrator code is the strongest link in this chain.

---

## 4. MCP runtime — real subprocesses or stubs?

### Production wiring — REAL

Three helper bundles exist on disk: `build/Build/Products/Debug/Jarvis.app/Contents/Helpers/{mcp-time,mcp-clipboard,mcp-applescript}.app/Contents/MacOS/<name>`. Confirmed binaries present.

`MCPRuntimeWiring.build` (`App/MCP/MCPRuntimeWiring.swift:89-157`):
1. Constructs `MCPClient` (real actor).
2. Calls `client.register(name:binaryURL:requiresConfirmation:)` for each helper.
3. `MCPClient.register` (`MCPClient.swift:60-80`) → constructs `MCPServerHandle`, calls `handle.start()`.
4. `MCPServerHandle.start` (`MCPServerHandle.swift:80-117+`) → runs `Process.run()`, wires three pipes, completes SDK initialize handshake, gets tools list. **REAL subprocess.** Uses `ChildSpawnGate.shared.prepare()` for FD_CLOEXEC sweep.

This is real. The helpers are real subprocesses. The SDK Client speaks real JSON-RPC over real pipes.

### Test coverage — strong but skip-prone

- `MCPTimeIntegrationTests.swift` — **REAL** end-to-end test. `test_get_time_returns_iso8601` spawns mcp-time and asserts ISO8601 timestamp within ±60s. ✓
- `MCPClipboardIntegrationTests.swift` — **REAL** end-to-end. ✓
- `MCPRestartTests.swift`, `MCPClientHappyPathTests.swift` — **REAL** subprocess tests using `MockHelperBuilder`.
- **CAVEAT (`HelperBundleLocator.swift:60-87`):** when running `swift test --package-path packages/MCP` standalone, no Jarvis.app is built, so locator throws `XCTSkip`. **The integration tests silently no-op outside of an Xcode-driven full-app build.** If your CI ever ran `swift test` instead of `xcodebuild test`, your "MCP integration green" badge was a lie.

The locator also has a real production-relevant note (line 67-86): Debug builds emit `mcp-time.debug.dylib` whose code signature diverges from the bundle, causing dyld rejection. The locator works around it by skipping Debug candidates — but **production runtime spawns from the same Debug build path, with no equivalent skip.** If you launch the Debug Jarvis.app and the `.debug.dylib` is present, **the helper subprocess will fail to launch with a Team ID mismatch, and `MCPRuntimeWiring.build` will throw, and `installAgent` will silently skip.** This may be why "nothing demonstrably works" if you've been on Debug builds.

Recommend: either Release build for testing, or strip `.debug.dylib` post-build, or document the Team-ID-mismatch failure mode in the boot path.

---

## 5. NoopBusGateway — what it actually breaks

`AppDelegate.swift:1735-1739` — `NoopBusGateway` is a `BusGateway` whose three methods are bodies of `{}`. Wired into `MCPRuntimeWiring.build` at `AppDelegate.swift:487` as the bus adapter for `ConfirmingToolDispatcher`.

### What gets dropped

`ConfirmingToolDispatcher.dispatch` (`packages/MCP/Sources/MCP/ConfirmingToolDispatcher.swift:104-217`) calls `bus?.emitToolCallStart` / `updateArgsPreview` / `emitToolCallEnd` at five sites (lines 132, 151, 167, 175, 185, 200, 209). Each one drops on the floor.

### Surfaces affected

1. **HUD-07 ToolCallCard awaiting-approval seal (MCP-04 / SEC-08).** `emitToolCallStart` with `argsPreview = "{\"awaitingApproval\":true}"` is supposed to land on the bus and drive the HUD to render a "tool X requested approval" card. Today: nothing renders. The user sees no indication a tool has been gated.
2. **HUD ToolCallCard Running → Completed transition.** `emitToolCallEnd(ok: true)` from line 167. Without it the HUD card stays in "Running" forever even after the tool succeeds. (The orchestrator's `.toolCardUpdate(.completed)` from `AgentOrchestrator.swift:428-435` is a *separate* bus surface that does work — but only via the broadcaster path; this dispatcher-side drop means parallel-emission redundancy is broken.)
3. **HUD denial / timeout / barge feedback.** Lines 185, 200, 209 all drop. User has no UI signal that a confirmation timed out.
4. **Defense-in-depth args masking.** The whole point of MCP-04 was the `awaitingApproval` seal *on the bus*, so a misbehaving HUD never sees raw args before user approval. NoopBusGateway makes the seal unverifiable end-to-end.

### Why it doesn't matter for your current symptom

The first 3 starter tools (`get_time`, `get_clipboard`) have `requiresConfirmation: false`, so the dispatcher takes the fast path (line 108-110) and doesn't touch `bus` at all. Only `run_applescript` exercises the gated path. **For text-only `get_time` / `get_clipboard` calls the NoopBusGateway is invisible.** This is why your streamTruncatedFinal symptom is upstream of the dispatcher entirely — the failure is at the LLM, not the tools.

But: the moment the first AppleScript tool fires, the HUD-07 contract is dead. Worth replacing before any AppleScript demo.

---

## 6. Test classification

| Subsystem | File | Type | Catches `streamTruncated` empty-stream? | Catches FK violation? | Catches install race? | Catches NoopBus drop? |
|---|---|---|---|---|---|---|
| Anthropic | `SSEDecoderTests.swift` | **REAL unit** | NO (only mid-stream EOF, never empty) | N/A | N/A | N/A |
| Anthropic | `FixtureReplayTests.swift` | **REAL fixture replay** (no network) | NO | N/A | N/A | N/A |
| Anthropic | `RequestBodyTests.swift` | **REAL byte-level** | N/A | N/A | N/A | N/A |
| Anthropic | `AnthropicImageBlockEncodingTests.swift` | **REAL** | N/A | N/A | N/A | N/A |
| Ollama | `NDJSONDecoderTests.swift` | **REAL unit** | NO (mid-stream only) | N/A | N/A | N/A |
| Ollama | `OpenAICompatDecoderTests.swift` | **REAL unit** | NO | N/A | N/A | N/A |
| Ollama | `OllamaRequestBodyTests.swift` | **REAL** | N/A | N/A | N/A | N/A |
| Ollama | `FixtureReplayTests.swift` | **REAL fixture** (no network) | NO | N/A | N/A | N/A |
| Orchestrator | `OrchestratorSubmitTests.swift` | **REAL** (MockLLMProvider) | NO | NO (mock replay) | NO | N/A |
| Orchestrator | `OrchestratorRetryTests.swift` | **REAL** | YES — for streamTruncated retry, but using **mocked** stream | NO | N/A | N/A |
| Orchestrator | `OrchestratorEventBroadcasterTests.swift` | **REAL** | N/A | N/A | NO | N/A |
| Orchestrator | `BusForwarderTests.swift` | **REAL** | N/A | N/A | N/A | YES (would catch if BusForwarder dropped, but does not catch NoopBus on dispatcher path) |
| Orchestrator | `TextInputEndToEndTests.swift` | **REAL** but mocked LLM + ToolDispatcher | NO (no real network) | NO | NO | NO |
| MCP | `MCPTimeIntegrationTests.swift` | **REAL subprocess** | N/A | N/A | N/A | NO (uses mock bus) |
| MCP | `ConfirmingToolDispatcherTests.swift` | **REAL** | N/A | N/A | N/A | YES (asserts bus.emit calls) |
| MCP | `MCPRestartTests.swift` | **REAL subprocess** | N/A | N/A | N/A | N/A |
| MCP | `MCPServerHandleStartTests.swift` | **REAL subprocess** | N/A | N/A | N/A | N/A |

**No test catches:**
1. Anthropic `200 + 0 bytes` empty-stream case.
2. `cache_control` on a too-small system prompt error path.
3. `webviewBridge nil → outboundBatcher nil → bus subscriber silently drops` race.
4. `replayLog.beginSession` throws → orchestrator never constructed → `chatSubmit` silently no-ops.
5. `Debug` build's `mcp-time.debug.dylib` Team-ID-mismatch causing helper spawn failure.
6. `installAgent` silently returns on missing deps (only a system log line).

---

## 7. What actually works (one sentence each)

- **AnthropicProvider HTTP path:** correct — headers, body, status handling, key fetch all wired and unit-tested.
- **AnthropicProvider SSE decode:** correct — every documented edge case covered, but **collapses "empty stream" into "streamTruncated" with no diagnostic distinction**, which is your current symptom.
- **AnthropicProvider tool calling:** unit-tested (input_json_delta assembly, tool_choice serialization), no real-network verification.
- **OllamaProvider:** decoders correct and well-tested; **never run against a real Ollama instance in any test on disk**.
- **MCP tools at runtime:** real subprocesses, real JSON-RPC, real integration tests that *would* run if invoked through Xcode but `XCTSkip` under `swift test` standalone — and the **Debug build's `.debug.dylib` may be silently breaking helper spawn at app launch**, which would explain the broader "nothing works" report.
- **NoopBusGateway:** silently drops 5 dispatcher-side bus emissions; today only impacts `run_applescript` (the only confirmation-gated tool); HUD ToolCallCard awaiting-approval / completed transitions are dead until replaced.

---

## Recommended next moves (ordered by ROI)

1. **Dump the actual Anthropic request body bytes from production code, then `curl --data-binary @body.json`.** If curl reproduces 200+EOF, the body is the bug — most likely the cache_control on a 10-token system prompt (§1b).
2. **Make `flushOnEOF` distinguish empty-stream from mid-stream truncation** — emit a different LLMEvent or include a flag. Today both look identical at the orchestrator, costing you debug visibility.
3. **Add a `URLProtocol` mock test for `200 + 0 bytes`** — would have caught this on day one and would protect against regression.
4. **Verify Debug helper spawn works** — check `~/Library/Logs/Jarvis/system.log` (or Console.app filtered to com.koftwentytwo.jarvis) for `MCPRuntime built — N tools` vs `MCPRuntime build failed`. If the latter, you've been running with `mcpRuntime == nil` and `installAgent` silently skipping for who knows how long.
5. **Replace NoopBusGateway** before any AppleScript demo — currently a 5-line struct with `{}` bodies wired into production.
6. **Add a banner / chat-panel error path for `replayLog.beginSession` throw and missing deps in `installAgent`** — silent returns are the cause of "I submit chat and nothing happens." Today they only log to `systemLogger`.

The architecture is sound. The unit tests are real. **The integration trust is paper-thin and the product of fixture-replay tests masquerading as end-to-end tests.** That mismatch is what 50 hours has paid for, and it's why you don't have a working demo.
