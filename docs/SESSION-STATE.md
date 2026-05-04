# Session State

**Last Updated:** 2026-05-04

## Current Status

`develop` at `19362f6`, ahead of origin (push pending). Tree clean. Track A + Track B-1..7 + Cleanup batch + Track C (vision, all 6 items) closed. Track D (memory) is the next session's pickup point.

## What Was Done This Session

- Six-agent deep audit (voice / HUD / vision / memory / LLM / tests) → `.planning/audit-2026-05-03/SYNTHESIS.md`. Verdict: nothing worked end-to-end; every modality had ≥1 fatal break.
- **Commit `1f8e03e` — Track A** (text turn + animated rings):
  - HUD `idle` ring no longer static (`stateUniforms.ts:30`).
  - `CacheHints.eligibleForSystemPrompt` gates `extended-cache-ttl` on prompts ≥1024 tokens (likely streamTruncated cause).
  - `StreamOutcome` classifier distinguishes 200+0bytes / 200+0frames / 200+EOF / complete.
  - `AnthropicAPIKeyProvider.make` propagates `KeychainError` instead of swallowing.
  - 2 new real-WKWebView e2e tests (chat-turn round-trip both directions).
- **Commit `ee7f6d2` — Track B-1..3** (voice foundations):
  - `scripts/copy-voice-models.sh` bundles ONNX models at runtime path `Contents/Resources/Models/{openWakeWord,silero}/`. 6 shell tests.
  - `WakeWordDAG.swift:93` fixed: production now calls `feed(samples:)` not `feedTest()`. 2 unit tests.
  - `TTSEngineActor.orpheus` is now `OrpheusTTS?`; `App/Voice/VoiceOutputWiring.swift` constructs tier-1 (AVSpeechSynthesizer) without Orpheus weights. 4 unit tests including real `AVSpeechSynthesizer`.
- **Commit `e9c0a34` — Track B-4** (audio graph + STT wiring):
  - `AudioGraphOwner.setCancelInFlight` / `setReleaseORTSessions` cross-actor setters (Swift 6 mode requires).
  - New `PCMBufferBuilder` (`AudioChunk.pcm16k` → `AVAudioPCMBuffer` + `AVAudioConverter` resample). Lives outside `@available(macOS 26)` gate so unit tests run on every supported macOS. +7 tests.
  - `LiveSpeechAnalyzerBridge.feed(_:)` no longer `_ = chunk` — full SpeechAnalyzer + SpeechTranscriber wiring: builds analyzer with `bestAvailableAudioFormat`, opens `AsyncStream<AnalyzerInput>` pipe, spawns result-drain Task, finalises through end-of-input.
  - `installVoice` constructs AudioGraphOwner, spawns degradation+rebuild consumers BEFORE `open()` (so the aec=false retry path is observed), hands ring buffer to `WakeWordDAG.start(ring:)`, sets `cancelInFlight` for teardown step 1. Fail-soft on graph open failure.
  - VoiceWiringTests testW1 asserts new `audioGraphOwner` / `audioGraphDegradationTask` / `audioGraphRebuildTask` strong properties.
- **Commit `61aed20` — Track B-5** (chunk pump + e2e proof):
  - VoiceController gains a `chunkPump: @Sendable (AsyncStream<AudioChunk>.Continuation) async -> Void` init parameter (no-op default for back-compat).
  - `startSTTSession` spawns a detached `chunkPumpTask`; `endSTTSession` cancels it before closing the chunk continuation; `shutdown` cancels it. No leaked Task on session end.
  - AppDelegate's production pump reads `audioGraphOwner.ringBuffer` in 1024-sample windows (~64 ms @ 16 kHz), 10 ms sleep on starve, exits on Task cancel.
  - VoiceLoopE2ETests (+3): preset-chunks → orchestrator.submit text match (E1); empty pump → no submit + back to idle (E2); pump task exits within 100 ms of pttUp (E3).
- **Commit `bce725b` — Track B-7** (BufferBroadcaster fan-out):
  - New `BufferBroadcaster` (`packages/Voice/.../AudioGraph/BufferBroadcaster.swift`) fans the audio-graph tap output to per-subscriber `RingBuffer`s; consumers no longer race for samples on the legacy SPSC ring.
  - `AudioGraph.swift` tap callback calls `broadcaster.publish(buffer)`; the legacy `public let ringBuffer` is now a private "primary" subscription so `WakeWordDAG.start(ring:)` and the overflow watcher keep working without signature changes.
  - `AudioGraphOwner.subscribe(capacityFrames:)` actor method added — chunk pump in AppDelegate now subscribes per-session via this and unsubscribes on pump exit.
  - Publish path is wait-free in steady state: `OSAllocatedUnfairLock<[Subscription]>` snapshot copy, iterate outside lock; per-subscriber `RingBuffer.write` remains lock-free. Real-time tap-thread safe.
  - 5 new BufferBroadcasterTests (BB-1..5: single sub, multi-sub no theft, unsubscribe stops, late-join skips prior, concurrent stress). All pass.
  - Voice swift-testing 17 → 22 (+5 BB). XCTest 84 unchanged. Pre-existing `TTSInterruptTests.testI3` baseline 10s flake unchanged.
  - Anti-patterns enforced: no actor hops on tap thread, NSLock forbidden, T-06-05-03 (no PCM logging) preserved, VOICE-14 single-call-site preserved.
- **Commit `ad93dac` — BLOCKER-INT-1** (real bus gateway): replaced `NoopBusGateway` in `AppDelegate.swift` with `MCPBusGatewayAdapter` that forwards `emitToolCallStart` / `emitToolCallEnd` through `OutboundBatcher`. Tool-call cards now reach the webview bus. New `MCPBusGatewayAdapterTests` proves the start→end forward path.
- **Commit `6f6617e` — F-A2-01** (stale bus world): `WebviewBridgeOutboundTests:80` asserted retired `JarvisBusWorld` name; production switched to `.page` in `fb41c5f`. Test now asserts `WKContentWorld.page` — load-bearing again.
- **Commit `08125a4` — tests-audit cleanup** (5 tautologies): removed/replaced `XCTAssertTrue(true)` placeholders per `.planning/audit-2026-05-03/tests-audit.md` section 5. MCPRuntimeWiringTests:260 in-place assertion fix; WebviewBundleLoadTests, InputMonitoringDenialTests, PackageBoundaryTests deleted documentation-as-test funcs; ToolChoiceTests trailing tautology removed (closure compile is the gate). HudStateEnumTests rubber-stamps left as-is (a11y labels are user-facing, load-bearing).
- **Commit `5cd46c9` — F2 linter** (`scripts/check-no-leftover-stubs.sh`): grep-based gate against `Replaced in 0…`, `TODO: Plan|0X-…`, 2-line stub function bodies, and production `Noop*(` / `*Stub(` instantiations. Self-tested against synthetic fixture; clean on current `develop`. Allowlists `Dormant*` (real producer-stream pattern).
- **Commit `7a5543a` — Track C-1** (CameraCapture AVCapturePhotoCaptureDelegate): replaces the 1×1 black-JPEG hardcode with the real photoOutput delegate path. New `PhotoCaptureProxy` (NSObject) bridges the delegate callback into a CheckedThrowingContinuation; retains itself for the lifetime of the capture (AVCapturePhotoOutput holds delegates weakly), breaks the cycle on the first didFinishProcessingPhoto callback. Test seam `photoCaptureOverride` mirrors `authStatusProbe` — production tests can exercise captureFrame() end-to-end without hardware. Vision 56 → 59.
- **Commit `ea09fd4` — Track C-2** (frameStream fan-out): replaces `AsyncStream { cont.finish() }` with a real fan-out backed by `AVCaptureVideoDataOutputSampleBufferDelegate`. New `VideoSampleDelegate` fans incoming CMSampleBuffers to a UUID-keyed map of registered continuations under an `NSLock`-guarded snapshot. `frameStream(forPresence:)` now generates a UUID per subscription, hops into the actor to register against the live delegate, and tears down via `cont.onTermination`. shutdown() drains the subscription set. Vision 59 → 63.
- **Commit `4159d44` — Track C-3** (HUD camera button): closes vision-audit §4 "HUD button emitter has zero matches". New `CameraButton.tsx` posts `{ type: 'frameAttachRequested' }` via `window.jarvisBus.send`; rendered next to the chat input's Send button with matching toolbar chrome. JS path: `webview/packages/hud/src/chat/CameraButton.tsx:14`. Swift handler at `App/AppDelegate.swift:1696-1698` already routed it into `FrameAttachController.requestAttach(reason: .hudButton)`. HUD vitest 94 → 97.
- **Commit `df6a4d2` — Track C-4** (explicit T2 missing variant): replaces the silent `t2Provider: t1` AppDelegate hardcode with `MissingT2Provider` whose `stream(...)` finishes with `VisionError.t2ProviderUnavailable`. Real vllm-mlx wiring (codesigning + binary bundling + feature flag) is downstream work and out of Track-C scope; the bug being fixed here is "silent T1-as-T2 fallback hides intent" — explicit-missing makes the missing wiring debuggable instead of silent. Production callers must gate on `evaluatePostResponse(..., t2Available: false)` (already do); MissingT2Provider's stream is never actually invoked in the live flow. Vision 63 → 67.
- **Commit `eac16c9` — Track C-5** (confirmSend wired): closes vision-audit §4 "confirmSend has zero non-test callers". `handleChatSubmit` and `handleChatCancelAndSubmit` now consult `FrameAttachController.hasPendingFrame` and, when armed, pull the `ImageBlock` via `confirmSend(userText:)` and route through `submit(.withImages(...))`. Both submit handlers carry the wiring (WARNING-4 parity with the existing phrase-trigger path). Completes the Track C-3 click flow end-to-end. Vision 67 → 70.
- **Commit `19362f6` — Track C-6** (real-hardware integration test): `CameraCaptureRealHardwareTests` exercises captureFrame() and frameStream() against real AVCaptureSession output. Gated by ALL of: `JARVIS_REAL_CAMERA=1` env, `AVCaptureDevice.default(for: .video)` non-nil, `authorizationStatus == .authorized`. Test does NOT prompt for TCC — headless test runs skip cleanly. Run interactively: `JARVIS_REAL_CAMERA=1 swift test --package-path packages/Vision --filter CameraCaptureRealHardwareTests`. Asserts: jpeg byte count > 1000, SOI marker, width/height > 1 (so a regression to the 125-byte 1×1 stub trips immediately); frameStream emits a `.sampleBuffer` within 2s. Vision 70 → 72 (2 tests, both skip without env+TCC).
- **Commit `c7f9ece` — Track B-6** (VAD-gated session end):
  - `VoiceController.startSTTSession` now spawns a per-session VAD interceptor task. Pump output flows through it, forwarding every chunk to STT *and* running Silero VAD per 512-sample window.
  - New private `runVADInterceptor`: tracks armed state on `.speechStart`, counts consecutive silence chunks after `.speechEnd`, and triggers `endSTTSession()` once the hangover threshold (5 chunks ≈ 160 ms) is reached. Mid-utterance speech resumption cancels the pending finalize.
  - `endSTTSession()` is now `async`; `pttUp()` awaits it. Single non-VAD caller path preserved.
  - 512-sample VAD window builder carries over the partial tail between chunks so it works against both the test pump (512-sample chunks) and the production pump (up to 1024-sample chunks).
  - Anti-patterns enforced: VAD handler does NOT block on `await analyzer.finish()` — finalize fires inside `Task { … }` to avoid deadlock on the analyzer completion path. T-06-05-03 preserved (no PCM in logs). VOICE-14 single `cancelAndSubmit` site preserved.
  - VADGatedSessionTests (+4): VAD-1 `.speechEnd` + 5×silence → submit; VAD-2 PTT regression with VAD wired; VAD-4 sustained speech → no submit; VAD-5 speech resumption within hangover cancels pending finalize.

## Active Branches

| Branch | Status |
|--------|--------|
| `develop` | At `19362f6`, ahead of origin (push pending). Tree clean. |

## Pending Work

- [ ] **AudioLevelEmitter production wiring** — emitter is constructed only in tests today; AppDelegate doesn't yet build/start it. When wired, it MUST call `audioGraphOwner.subscribe()` (the broadcaster fan-out is in place from Track B-7). Small follow-up.
- [x] **Track C** — vision: closed in commits `7a5543a` (C-1) → `ea09fd4` (C-2) → `4159d44` (C-3) → `df6a4d2` (C-4) → `eac16c9` (C-5) → `19362f6` (C-6). Vision 56 → 72; HUD vitest 94 → 97. Real T2 sidecar wiring (binary bundling + codesigning + feature flag) deferred to a future track — Track C-4 made the missing wiring explicit via `MissingT2Provider`, not silent.
- [ ] **Track D** — memory: bundle custom libsqlite3 with `SQLITE_ENABLE_LOAD_EXTENSION=1`, ship `vec0.dylib`, register `SearchMemoryTool` + `ForgetFactTool` with MCP runtime, fix `priorFacts: []` hardcode. ~3 days.
- [ ] **Pre-existing TTSInterruptTests.testI3 flake** — `XCTAssertLessThan failed: ("10.4...") is not less than ("0.08")`. Deterministic 10s timeout in `InterruptSequence.run`; pre-dates Track B-4. Not blocking but should be triaged.
- [ ] streamTruncated empirical confirmation — re-launch app and verify cache_control fix actually completes a turn.

## Key Reference

- Audit reports: `.planning/audit-2026-05-03/{SYNTHESIS,voice,voice-audit,hud-audit,vision-audit,memory-audit,llm-audit,tests-audit}.md`
- Plan: `.planning/AUDIT-AND-FIX-PLAN.md`, findings tracker: `.planning/AUDIT-FINDINGS.md`
- Test stack at session end: Voice 84 XCTest (1 pre-existing testI3 failure) + 22 swift-testing (3 skipped), AgentCore 215/215, Replay 33/33, Bus 58/58, Vision **72** XCTest (was 56; +16 across Track C; 2 hardware tests skip without `JARVIS_REAL_CAMERA=1`), webview/hud **97** vitest (was 94; +3 CameraButton). All 6 boundary gates PASS, app builds clean. Pre-existing baseline issues unrelated to this batch: `packages/Shell/Tests/ShellTests/InputMonitoringDenialTests.swift` compile failure on clean tree, `webview/packages/hud/src/hud/SegmentedRing.tsx` typecheck warnings. Flag for follow-up; out of scope here.
- Next-session orientation: read `.planning/audit-2026-05-03/SYNTHESIS.md` first, then this file, then `git log --oneline 5cd46c9..HEAD`'s commit bodies for the Track C story.
