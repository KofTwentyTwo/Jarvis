# Session State

**Last Updated:** 2026-05-04

## Current Status

`develop` at `5cd46c9`, ahead of origin by 4 commits (push pending). Tree clean. Track A + Track B-1..7 + Cleanup batch (BLOCKER-INT-1, F-A2-01, tests-audit cleanup, F2 linter) closed. Tracks C (vision) and D (memory) are the next session's pickup points.

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
| `develop` | At `5cd46c9`, 4 commits ahead of origin (push pending). Tree clean. |

## Pending Work

- [ ] **AudioLevelEmitter production wiring** — emitter is constructed only in tests today; AppDelegate doesn't yet build/start it. When wired, it MUST call `audioGraphOwner.subscribe()` (the broadcaster fan-out is in place from Track B-7). Small follow-up.
- [ ] **Track C** — vision: `AVCapturePhotoOutput` delegate flow (currently allocated but never called); HUD camera button (doesn't exist); `frameStream` returns immediately-finished `AsyncStream`. ~1 day.
- [ ] **Track D** — memory: bundle custom libsqlite3 with `SQLITE_ENABLE_LOAD_EXTENSION=1`, ship `vec0.dylib`, register `SearchMemoryTool` + `ForgetFactTool` with MCP runtime, fix `priorFacts: []` hardcode. ~3 days.
- [ ] **Pre-existing TTSInterruptTests.testI3 flake** — `XCTAssertLessThan failed: ("10.4...") is not less than ("0.08")`. Deterministic 10s timeout in `InterruptSequence.run`; pre-dates Track B-4. Not blocking but should be triaged.
- [ ] streamTruncated empirical confirmation — re-launch app and verify cache_control fix actually completes a turn.

## Key Reference

- Audit reports: `.planning/audit-2026-05-03/{SYNTHESIS,voice,voice-audit,hud-audit,vision-audit,memory-audit,llm-audit,tests-audit}.md`
- Plan: `.planning/AUDIT-AND-FIX-PLAN.md`, findings tracker: `.planning/AUDIT-FINDINGS.md`
- Test stack at session end: Voice 84 XCTest + 22 swift-testing (3 skipped; 1 pre-existing TTSInterruptTests.testI3 failure), AgentCore 215/215, Replay 33/33, Bus 58/58 (F-A2-01 fixed), webview/hud 94/94, all 5 boundary gates + new check-no-leftover-stubs PASS, app builds clean. Net test delta from cleanup batch: -3 tests (3 deleted XCTAssertTrue(true) placeholders; MCPRuntimeWiringTests in-place fix and ToolChoiceTests trailing tautology removed without affecting test count). Pre-existing baseline issue unrelated to this batch: `packages/Shell/Tests/ShellTests/InputMonitoringDenialTests.swift` fails to *compile* on a clean tree (MockProbe missing `isListenEventAccessGranted()`); reproduced via `git stash`. Flag for follow-up; out of scope here.
- Next-session orientation: read `.planning/audit-2026-05-03/SYNTHESIS.md` first, then this file, then `git log --oneline 5cd46c9 08125a4 6f6617e ad93dac bce725b`'s commit bodies for the cleanup batch + B-7 story.
