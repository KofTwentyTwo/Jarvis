# Session State

**Last Updated:** 2026-05-04

## Current Status

`develop` at `bce725b`, pushed. Tree clean. Track A + Track B-1..7 closed. Tracks C (vision) and D (memory) are the next session's pickup points.

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
| `develop` | At `bce725b`, pushed to origin. Tree clean. |

## Pending Work

- [ ] **AudioLevelEmitter production wiring** — emitter is constructed only in tests today; AppDelegate doesn't yet build/start it. When wired, it MUST call `audioGraphOwner.subscribe()` (the broadcaster fan-out is in place from Track B-7). Small follow-up.
- [ ] **Track C** — vision: `AVCapturePhotoOutput` delegate flow (currently allocated but never called); HUD camera button (doesn't exist); `frameStream` returns immediately-finished `AsyncStream`. ~1 day.
- [ ] **Track D** — memory: bundle custom libsqlite3 with `SQLITE_ENABLE_LOAD_EXTENSION=1`, ship `vec0.dylib`, register `SearchMemoryTool` + `ForgetFactTool` with MCP runtime, fix `priorFacts: []` hardcode. ~3 days.
- [ ] BLOCKER-INT-1 — replace `NoopBusGateway` so tool-call cards reach HUD.
- [ ] F-A2-01 — `WebviewBridgeOutboundTests:80` stale `JarvisBusWorld` assertion.
- [ ] **Pre-existing TTSInterruptTests.testI3 flake** — `XCTAssertLessThan failed: ("10.4...") is not less than ("0.08")`. Deterministic 10s timeout in `InterruptSequence.run`; pre-dates Track B-4. Not blocking but should be triaged.
- [ ] streamTruncated empirical confirmation — re-launch app and verify cache_control fix actually completes a turn.

## Key Reference

- Audit reports: `.planning/audit-2026-05-03/{SYNTHESIS,voice,voice-audit,hud-audit,vision-audit,memory-audit,llm-audit,tests-audit}.md`
- Plan: `.planning/AUDIT-AND-FIX-PLAN.md`, findings tracker: `.planning/AUDIT-FINDINGS.md`
- Test stack at session end: Voice 84 XCTest + 22 swift-testing (+5 BufferBroadcasterTests this session; 3 skipped; 1 pre-existing TTSInterruptTests.testI3 failure), AgentCore 215/215, Replay 33/33, Bus 57/58 (1 pre-existing F-A2-01), webview/hud 94/94, all boundary gates PASS, app builds clean.
- Next-session orientation: read `.planning/audit-2026-05-03/SYNTHESIS.md` first, then this file, then `git log --oneline bce725b c7f9ece 61aed20 e9c0a34`'s commit bodies for the B-4..7 audit-and-fix story.
