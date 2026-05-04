# Code & Functionality Audit — 2026-05-04

## Verdict: MIXED

The wiring layer that the 2026-05-03 audit found dead is now substantially real. Track A (text turn), Track B (voice — minus AudioLevelEmitter), and Track C (vision) all have producer→cable→consumer chains that you can trace by file:line. The MCP tool-call card chain to the HUD is real and proven by a real-batcher test. Replay log + sessions row creation is real. Entitlements are correct on Release.

But two production paths are still functionally dead, and one is structurally fragile:

1. **Memory writes & search are dead at runtime.** `vec0.dylib` is still the placeholder text file (`packages/Memory/Sources/Memory/Resources/PLACEHOLDER.txt`); `MemoryStore.init` will throw `vecLoadFailed` on every cold launch. Track D-1's "graceful degradation" is real — extractor still calls Ollama, applyOp logs+drops — but every memory write is a no-op and `search_memory` is never registered. This is acknowledged in TODO.md as user environment work (D-5/D-6/D-7); the code-side wiring is honest. **Memory is OFF until D-5/6/7 land.**

2. **AudioLevelEmitter is unwired in production.** The HUD ring's reactive pulsing on mic input has no producer. It is referenced only in tests and one doc-comment. Track B-7 wired the broadcaster fan-out so the level emitter *could* subscribe non-destructively, but no AppDelegate construction call exists. The HUD will look static during voice listening.

3. **Track C T2 (vllm-mlx) is permanently `MissingT2Provider` until vllm-mlx codesigning + binary bundling + flag wiring lands.** Track C-4 made this explicit (good — was silent t1 fallback before). Production callers gate on `t2Available: false` so it never streams; the deferral is honest.

The Debug entitlements file (`App/Jarvis.Debug.entitlements`) is missing `com.apple.developer.speech-recognition-assets`. Per CLAUDE.md this causes silent `assetUnavailable` on first-launch SpeechAnalyzer. Release has it; Debug doesn't. Voice STT will silently break in Debug builds.

Overall: of the 22 commits today, the ones I can verify by reading the code do what their messages claim. The illusion-of-completion pattern is not present in the new wiring. The remaining gaps are honestly documented (TODO.md, SESSION-STATE.md "Pending Work").

---

## Findings

### 1. Text turn flow — REAL
**Severity:** INFO

**Trace:**
1. JS chat input → `BusInbound.chatSubmit(text)` → `webview/packages/hud/src/chat/ChatInput.tsx`
2. Swift WKScriptMessageHandler → `bridge.onInbound` → `AppDelegate.swift:1838-1840` (`handleChatSubmit`)
3. Frame-attach pre-check (Track-C 5) → `AppDelegate.swift:1456-1462`
4. `agentOrchestrator.submit(.text(text))` → `packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift:283` — `CacheHints.eligibleForSystemPrompt(finalSystem)` returns `nil` for the default 10-token prompt (gated at 4096 chars in `CacheHints.swift:50-52`).
5. Anthropic SSE stream → `AnthropicProvider.stream` → token deltas yielded into orchestrator's broadcaster
6. `OrchestratorEventBroadcaster` → six subscribers; `.bus` subscriber → `BusForwarder.drain` → `AppBusForwarderSink.postToken` → `OutboundBatcher.postToken` → WebviewBridge → `BusOutbound.tokenDelta` → JS-side reconciler
7. `StreamOutcome` log line written at `AnthropicProvider.swift:195` and `:227` so production triage can distinguish 200+0bytes / 200+truncation / complete.

**Verdict:** REAL. The `streamTruncatedFinal` cache_control bug is genuinely fixed. The eligibility floor uses 4096 *chars* (~1024 tokens) — slightly conservative but correct shape. The diagnostic StreamOutcome is real, not a comment.

**Evidence:** `packages/Bus/Tests/BusTests/RealWKWebViewIntegrationTests.swift:302-356` — `test_chatTurnRoundTrip_busOutboundReachesPageHandler` mounts a real WKWebView and asserts the `turnStarted → tokenDelta("Hello, ") → tokenDelta("world.") → turnEnded(.completed)` envelope sequence reaches a JS handler. This is a real-runtime test exercising the bus across the JS/Swift boundary, not a fake.

**Recommendation:** None. Empirical re-launch confirmation is in TODO.md.

---

### 2. Voice loop wake-fired — REAL (but production fan-out untested in code)
**Severity:** MEDIUM

**Trace:**
1. `AVAudioEngine.installTap` → tap callback → `AudioGraph.swift:220-226` → `broadcaster.publish(buffer)` on real-time tap thread
2. `BufferBroadcaster.publish` (`packages/Voice/Sources/Voice/AudioGraph/BufferBroadcaster.swift`) takes `OSAllocatedUnfairLock` snapshot, iterates writing each subscriber's per-subscriber `RingBuffer`. Wait-free in steady state.
3. `WakeWordDAG.start(ring:)` (called from `AppDelegate.swift:803-804`) reads from the broadcaster's *primary* subscription ring (`AudioGraph.swift:165-243` — `primarySub` retained, exposed as legacy `ringBuffer`).
4. Wake-word fires → `WakeWordDAG.wakeWordStream` → `VoiceController.handleWakeWord` (`VoiceController.swift:226-247`) → `.idle → .listening(.wakeWord)` → `startSTTSession()`
5. `startSTTSession()` (`VoiceController.swift:323-387`) spawns `chunkPumpTask` running the production pump (`AppDelegate.swift:892-922`). Pump calls `audioGraphOwner.subscribe()` for a fresh per-subscriber ring (NOT primary), then loops `ring.readMono16k(into: scratch)` 1024 frames at a time.
6. VAD interceptor (`runVADInterceptor`, `VoiceController.swift:403-484`) drains pump output, slices into 512-sample windows, runs Silero, forwards every chunk to STT continuation regardless of VAD decision. On `.speechEnd` + 5 silence chunks → fires `endSTTSession()` from a Task.
7. STT (`SpeechAnalyzerSTT`) feeds via `PCMBufferBuilder.makePCMBuffer` + `AVAudioConverter` → `AnalyzerInput` → SpeechTranscriber → final text
8. `handleSTTFinalized(text:)` → `orchestrator.submit(text:)` → text turn flow (#1)

**Verdict:** REAL. The wake-word DAG's ring read and the chunk pump's ring read are now distinct rings fed by the same broadcaster — the prior race is structurally gone (Track B-7). The production pump uses `subscribe()`, not the primary ring.

**Evidence:** `packages/Voice/Tests/VoiceTests/BufferBroadcasterTests.swift` (BB-1..5) proves the broadcaster's per-subscriber semantics. `VoiceLoopE2ETests.testE1` proves chunkPump → STT → orchestrator.submit using fakes for STT/orchestrator/pump. **No test exercises the production AppDelegate-supplied pump or real `AudioGraphOwner.subscribe()` flow** — both are exercised only at runtime. The prior audit's exact concern ("does the chunk pump actually receive samples in production") is closed at the code-shape level but not at the test level.

**Recommendation:** A single integration test that constructs a real `AudioGraphOwner` with a synthetic `GraphBuilder` (the test seam exists), publishes N buffers via `broadcaster.publish`, and asserts the chunk pump's subscriber ring observes them would close the last gap. ~half-hour of work.

---

### 3. Voice loop PTT — PARTIAL
**Severity:** LOW

**Trace:**
1. PTT key down → `PushToTalk` → `VoiceController.pttDown` (`VoiceController.swift:149-160`) → `.idle → .listening(.ptt) → startSTTSession()`
2. Same `startSTTSession` path as wake-word: chunk pump + VAD interceptor spawn.
3. PTT key up → `pttUp()` (`VoiceController.swift:165-169`) → `endSTTSession()`. State guard `case .listening(.ptt)` ensures other listening sources don't get clobbered.

**Verdict:** PARTIAL. The VAD interceptor *can* fire `endSTTSession` early during a PTT session if the user starts speaking and then pauses for ~160ms. This is because VAD interception is unconditional in `startSTTSession` regardless of source. Today's `testVAD2_pttUp_still_finalizes_when_VAD_silent` only proves PTT finishes correctly when VAD never sees `.speechStart`. There is no test for: PTT down → user speaks → pauses for hangover → VAD ends session before PTT up.

**Evidence:** `packages/Voice/Tests/VoiceTests/VADGatedSessionTests.swift:103-140` (VAD-2) sets all VAD probabilities to 0.1 (silence). With sustained silence VAD never arms (`pendingFinalize` stays false), so the path where `.speechStart` followed by silence triggers premature finalize during a PTT hold is uncovered.

**Recommendation:** Either gate the VAD interceptor on `case .listening(.wakeWord)` (so PTT bypasses it like the doc comments imply was the original intent) or add an explicit test for PTT-with-speech-then-silence. The current behavior is probably *fine for users* (PTT hold + silence = "I'm done" is intuitive) — flag as INFO-level intent question, not a bug.

---

### 4. Vision frame attach — REAL
**Severity:** INFO

**Trace:**
1. JS HUD button click → `webview/packages/hud/src/chat/CameraButton.tsx:18-25` → `window.jarvisBus.send({ type: 'frameAttachRequested' })`
2. Swift WKScriptMessageHandler → `bridge.onInbound` → `AppDelegate.swift:1835-1837`
3. `frameAttachController.requestAttach(reason: .hudButton)` → `packages/Vision/Sources/Vision/FrameAttachController.swift:68-92`
4. `captureSession.captureFrame()` → `CameraCapture.captureFrame()` → `PhotoCaptureProxy.photoOutput(_:didFinishProcessingPhoto:error:)` (`packages/Vision/Sources/Vision/CameraCapture.swift:280-312`) → real `photo.fileDataRepresentation()` JPEG bytes with real width/height
5. Frame parked in `FrameAttachController.pendingFrame` slot
6. User types text → `handleChatSubmit` (`AppDelegate.swift:1450-1465`) → `consumePendingFrameIfAny` → `confirmSend(userText:)` → `ImageBlock`
7. `agentOrchestrator.submit(.withImages(.text, text:, images: [imageBlock]))`

**Verdict:** REAL. The 1×1-stub bug is genuinely closed (`PhotoCaptureProxy` is a real `AVCapturePhotoCaptureDelegate`). `frameAttachRequested` has both producer (`CameraButton.tsx`) and consumer (`AppDelegate.swift:1835`). `confirmSend` has a real non-test caller (`AppDelegate.swift:1500`).

**Evidence:** `packages/Vision/Tests/VisionTests/CameraCaptureRealHardwareTests.swift` (Track C-6) covers the captureFrame path at hardware level when `JARVIS_REAL_CAMERA=1`. Asserts `jpegData.count > 1000` (so a regression to the 125-byte 1×1 stub trips). The integration through to `submit(.withImages(...))` is not covered by a single test, but each link is.

**Recommendation:** None. T2 sidecar wiring is documented as deferred via the explicit `MissingT2Provider`.

---

### 5. Memory extraction — DEAD (acknowledged) / PARTIAL (degraded path)
**Severity:** HIGH (production functionality), INFO (degradation honesty)

**Trace:**
1. Cold launch → `AppDelegate.installMemory` (`AppDelegate.swift:980`)
2. `MemoryStore(databaseURL:)` calls `sqlite3_load_extension(vec0.dylib)` (`packages/Memory/Sources/Memory/MemoryStore.swift:443`). The dylib lookup is `Bundle.module.path(forResource: "vec0", ofType: "dylib")`.
3. `packages/Memory/Sources/Memory/Resources/PLACEHOLDER.txt` exists; **there is no real `vec0.dylib`** anywhere in the repo or built bundle. `Bundle.module.path` returns nil → `throw MemoryError.vecLoadFailed("vec0.dylib not in Bundle.module and JARVIS_VEC0_STUB_PATH unset")`.
4. AppDelegate catches at `:996-1000` → `store = nil`, `searchAvailable = false`, log warning.
5. Extractor still constructs (real OllamaProvider + MemoryExtractor). priorFactsLookup closure returns `[]` because `store == nil` (`AppDelegate.swift:1047-1050`).
6. Coordinator + orchestrator construct; subscribed to broadcaster.
7. Per turnEnd → extractor calls Ollama → emits ADD/UPDATE ops. applyOp closure (`:1038-1046`) hits the `nil` branch and logs+drops every op.
8. `buildInProcessToolRegistry` (`:1107-1119`) registers ZERO tools when both dispatchers are nil. `forget_fact` and `search_memory` are never registered with the agent.

**Verdict:** DEAD for actual functionality, but the degradation is structurally honest. Track D-1 is real (extractor doesn't cascade-fail). Track D-2 is real (registry built when dispatchers exist; correctly skips when not). Track D-3 is real (priorFactsLookup is wired and used). The deferral to user environment work (D-5/D-6/D-7) is in TODO.md.

**Evidence:** Confirm by `find . -name "vec0*"` — only PLACEHOLDER.txt. Build the app, inspect `build/Build/Products/Debug/Jarvis.app/Contents/Resources/Memory_Memory.bundle/Contents/Resources/` — also placeholder. The deferred scripts (`scripts/build-sqlite-with-extensions.sh`, `scripts/fetch-sqlite-vec.sh`) exit 1 with TODO markers.

`App/Tests/AppTests/MemoryInstallWiringTests.swift` proves the cascade closure (D-1) and `c3bd0a5` regression covers extraction → fake store → search.

**Recommendation:** TODO.md is correct that this needs D-5/D-6/D-7 from the user. There are no code-side issues to fix. **Do not let "memory tests pass" be confused with "memory works" — every prod write is silently dropped today.**

---

### 6. Wake-word teardown safety — REAL
**Severity:** INFO

**Trace:**
1. `AppDelegate.swift:812-814` — `await graphOwner.setCancelInFlight { [wakeWordDAG] in await wakeWordDAG.cancel() }`
2. On `RebuildTrigger` (deviceChange / aecFallback / micRegrant / ringOverflow), `AudioGraphOwner.rebuild` → `teardown(trigger:)` calls `await cancelInFlight?()` as step 1 before `graph?.stop()` (per the doc-comment at `AudioGraphOwner.swift:21`).
3. WakeWordDAG.cancel() cancels `feedTask` (`WakeWordDAG.swift:141-142`), so the detached read loop exits before the ring is released.

**Verdict:** REAL. Production wires the slot at the only reasonable place (immediately after `wakeWordDAG.start(ring:)`).

**Evidence:** `packages/Voice/Tests/VoiceTests/TeardownTests.swift` verifies the six-step ordering. The wiring at AppDelegate.swift:812 is one line, hard to misread.

**Recommendation:** None.

---

### 7. MCP tool execution → tool-call card on HUD — REAL
**Severity:** INFO

**Trace:**
1. Agent emits tool_use → `ConfirmingToolDispatcher.dispatch` (`packages/MCP/Sources/MCP/ConfirmingToolDispatcher.swift:132-136`) → `bus?.emitToolCallStart(toolUseId:, name:, argsPreview:)`
2. `bus` is `MCPBusGatewayAdapter` (constructed at `AppDelegate.swift:539-541`, passed to `MCPRuntimeWiring.build`).
3. `MCPBusGatewayAdapter.emitToolCallStart` (`App/MCPBusGatewayAdapter.swift:53-57`) → `resolveBatcher()` → `flushAndSend(.toolCallStart(id:, name:, argsPreview:))`.
4. UUID derivation uses SHA256-derived stable UUID so start/end correlate by id (`MCPBusGatewayAdapter.swift:81-95`).
5. OutboundBatcher → WebviewBridge.sendRaw → JS-side `client.ts` `upsertToolCall(id, name, args)`.

**Verdict:** REAL. The `NoopBusGateway` is gone from AppDelegate.

**Evidence:** `App/Tests/AppTests/MCPBusGatewayAdapterTests.swift` constructs a *real* `OutboundBatcher` with a recording sink and asserts that `emitToolCallStart` produces exactly one `.toolCallStart` envelope at the sink with the right id, name, args, and that `emitToolCallEnd` produces a matching id. This is load-bearing — exercises the real adapter through the real batcher to a sink boundary, not the protocol level.

**Recommendation:** None.

---

### 8. Replay log — REAL
**Severity:** INFO

**Trace:**
1. AppDelegate construct `ReplayLog(databaseURL:)` (`AppDelegate.swift:503`).
2. `installAgent` calls `replayLog.beginSession(appVersion:, buildSHA:)` (`:1194-1197`) BEFORE constructing the orchestrator. Without this row, every `startTurn` would FK-violate; the previous regression was that production never called `beginSession`.
3. `AgentOrchestrator(replayLog:, sessionId:, ...)` records every turn through to ReplayLog.
4. Memory mutations route through `MemoryStore.setReplayLog(AppDelegateMemoryReplaySink(replayLog:))` when store exists.
5. Frame-attach replay sink at `AppDelegate.swift:1647-1656` — wired only if `replayLog != nil`.

**Verdict:** REAL. The `beginSession` fix is in place. Replay covers turn lifecycle, tool calls (via `ReplayingToolResultObserver`), and memory mutations (when store exists).

**Evidence:** `packages/Replay/Tests` — 33 tests pass per SESSION-STATE.

**Recommendation:** I did not check whether a replayer CLI/UI exists to *play back* the log; if "replay log" means "we record turns" the path is real. If it means "we have a working replayer", that's out of scope of what I read.

---

### 9. HUD state coordinator multiplexing — REAL (but presence is record-only)
**Severity:** LOW

**Trace:**
1. `HudStateCoordinator.start(agent:, voice:, confirmation:)` (`App/HUD/HudStateCoordinator.swift:59-98`) spawns three drain tasks; each writes to its respective shadow field on MainActor and calls `resolveAndEmit()`.
2. `resolveAndEmit` (`:159`) is the SINGLE writer of `current`/`emit`. Precedence ladder is exact: `awaitingConfirmation > speaking > listening > thinking > idle > booting > reconfiguring`.
3. Initialised at `:1790` of AppDelegate; `start` called at `:1809-1811` immediately after.
4. `attachPresence(bus.stream)` (`HudStateCoordinator.swift:135-153`) drains presence events but **the body is empty `for try await _ in stream`** — presence is *recorded* (subscriber exists for VISION-03 boundary check) but does not affect any HUD state. This matches the doc-comment but means the "subtle ring indicator" promised in plan 07-04 has no observable effect today.

**Verdict:** REAL for the agent/voice/confirm three-way multiplex. Presence subscription is a no-op consumer — single-writer invariant trivially preserved by virtue of consuming nothing.

**Evidence:** `App/Tests/AppTests/HudStateCoordinatorTests.swift` and `HudStateCoordinatorBusWiringTests.swift` cover the precedence and the bus wiring.

**Recommendation:** Document or fix. If presence is supposed to drive a subtle ring indicator (per the doc comment), it needs to actually do something — currently no path from presence event to HUD visual exists.

---

### 10. App entitlements — PARTIAL
**Severity:** MEDIUM (silently breaks Debug voice STT)

**Trace:**
- `App/Jarvis.Release.entitlements` — has `com.apple.security.cs.allow-jit` ✓, `com.apple.developer.speech-recognition-assets` ✓, audio-input + camera ✓
- `App/Jarvis.Debug.entitlements` — has `cs.allow-jit` ✓, `audio-input` ✓, `camera` ✓, **MISSING `com.apple.developer.speech-recognition-assets`** ✗
- `App/Info.plist` — has `NSSpeechRecognitionAssetsUsageDescription` ✓, `NSMicrophoneUsageDescription` ✓, `NSCameraUsageDescription` ✓, `NSAppleEventsUsageDescription` ✓

**Verdict:** PARTIAL. The Release path has correct entitlements per CLAUDE.md's "load-bearing" warning. Debug builds will silently fail SpeechAnalyzer asset download with `SFSpeechErrorCode.assetUnavailable` — exactly the failure mode CLAUDE.md flagged. Per CLAUDE.md: "missing either causes silent assetUnavailable on first-launch Release (not Debug)" — actually the entitlement check at runtime affects both configurations; CLAUDE.md's parenthetical is wrong about Debug. Either way, parity with Release would prevent confusion.

**Evidence:** Reading the two entitlement files directly.

**Recommendation:** Add `com.apple.developer.speech-recognition-assets` to `Jarvis.Debug.entitlements` for Debug-build voice testing parity.

---

## Cross-cutting concerns

### AudioLevelEmitter is unwired
`packages/Voice/Sources/Voice/Control/AudioLevelEmitter.swift` exists; the only references in App-side code are in `App/Voice/VoiceBusEmitterAdapter.swift:6` (a doc comment) and tests. The emitter never subscribes to the broadcaster in production. Visible HUD effect: the listening-state ring will not pulse in response to mic input — the WARNING-5 flow promised "audio-level RMS at ~30 Hz" but the producer doesn't run.

This is acknowledged in TODO.md ("B-7-followup") but **the listening-state HUD experience is currently a static or VAD-driven illusion, not real.**

### Memory-vec0 is the largest remaining wiring honesty risk
The pattern "extractor still runs, applyOp drops, registry skips tools" is structurally fine. But there's no eval / smoke test that asserts the system behaves correctly when `store == nil` — for example, that the agent doesn't try to call `search_memory` on a turn that mentions memory. Today, since the tool isn't registered, the agent just doesn't see it. Acceptable, but the runbook for "what does the user observe when memory is off" is unwritten.

### Test pyramid: real-runtime tests still rare
Of the new tests landed today, the ones I count as exercising real production wiring (not protocol-level fakes):
- `MCPBusGatewayAdapterTests` — real `OutboundBatcher` to a recording sink ✓
- `RealWKWebViewIntegrationTests.test_chatTurnRoundTrip_*` — real WKWebView + JS bridge ✓
- `CameraCaptureRealHardwareTests` — real AVCaptureSession (env-gated) ✓
- `BufferBroadcasterTests` BB-1..5 — real broadcaster + real RingBuffer ✓
- `TTSEngineActorTier1Tests` — real `AVSpeechSynthesizer` ✓

Everything else exercises one of: pure logic (good), protocol boundary with fakes (acceptable), or a mock-against-mock surface where both sides are written by the same pen (theatrical).

`VoiceLoopE2ETests.testE1` is in the middle — it uses the *real* `VoiceController` and the *real* `runVADInterceptor` chain, but with a fake STT, fake orchestrator, and a fake pump. **No test exercises the production AppDelegate-supplied chunk pump against a real ring buffer.** This is the prior audit's exact ask and the most leveraged test still missing.

### Track A's 4096-char floor is heuristic
`CacheHints.swift:50` uses 4096 chars as the proxy for "≥1024 tokens". For Latin text that's roughly correct (~4 chars/token average); for tokenizer-heavy content (URLs, code, non-Latin) the threshold could be over- or under-restrictive. Today's default system prompt (~10 tokens) is well under, so the gate fires correctly. Once memory/presence enrichment grows the prompt, the proxy may emit cache_control on a 1023-token prompt and recreate the bug, or skip cache_control on a 1100-token prompt and lose the perf benefit. Token-count would be more correct but `client.tokenize` isn't free.

Not blocking; flag for future tightening.

## Things that surprised you

- **Track B-7's broadcaster fan-out is genuinely lock-free in steady state.** I expected a hand-wavy "we'll fix it later" but `BufferBroadcaster.publish` (`OSAllocatedUnfairLock<[Subscription]>` snapshot copy out of lock + iterate) is a real RT-safe design. Tap thread does not block on subscribe/unsubscribe.
- **The MCPBusGatewayAdapter test uses a real OutboundBatcher.** Most "fix the no-op gateway" PRs would land a SpyBatcher and call it good. This one runs the actual coalescing actor with a recording sink. That's the right test shape — close to what tests-audit.md was asking for.
- **`VAD interceptor runs unconditionally during PTT sessions.** Either intentional ("VAD also ends PTT silence") or an oversight. The doc comments hedge — line 339-345 of VoiceController says PTT was the "explicit finalize" path before VAD, suggesting the original intent was VAD only on wake-word. Worth confirming with the user.
- **Presence subscriber drains and discards.** `HudStateCoordinator.attachPresence` runs a `for try await _ in stream` with empty body. Documented as "07-04's job to do the visual" but currently the camera + presence detection runs full hardware path on every frame and the only effect is the bus drain. That's measurable battery cost for zero observable behavior.
- **Debug entitlements drift.** Easy to miss; would have bit someone in dev when they tried voice in a Debug build.
- **The 22 commits today actually moved the needle.** I went into this assuming the synthesis pattern of "wiring exists, data doesn't flow" would repeat. With the exceptions of AudioLevelEmitter and vec0 (both honestly TODO'd), the new wiring is real wiring. That's a significant step up from the 2026-05-03 baseline.
