# Session State

**Last Updated:** 2026-05-03

## Current Status

`develop` at `e9c0a34`, **NOT yet pushed**. Tree clean. Track A + Track B-1..4 closed. Track B-5 (voice loop e2e test) is the next session's pickup point.

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

## Active Branches

| Branch | Status |
|--------|--------|
| `develop` | At `e9c0a34`, **NOT yet pushed**. Tree clean. |

## Pending Work

- [ ] **Track B-5** — voice loop e2e test: feed a known WAV at the audio graph, assert STT result lands on the orchestrator. **Also need: VoiceController chunk-feeding** — `startSTTSession()` creates `sttChunkCont` but no producer feeds it. Without that, the new SpeechAnalyzer wiring sees zero chunks. Likely scope: an audio-tap → AudioChunk converter that pulls from the ring buffer when state == .listening and yields into `sttChunkCont`.
- [ ] **Track C** — vision: `AVCapturePhotoOutput` delegate flow (currently allocated but never called); HUD camera button (doesn't exist); `frameStream` returns immediately-finished `AsyncStream`. ~1 day.
- [ ] **Track D** — memory: bundle custom libsqlite3 with `SQLITE_ENABLE_LOAD_EXTENSION=1`, ship `vec0.dylib`, register `SearchMemoryTool` + `ForgetFactTool` with MCP runtime, fix `priorFacts: []` hardcode. ~3 days.
- [ ] BLOCKER-INT-1 — replace `NoopBusGateway` so tool-call cards reach HUD.
- [ ] F-A2-01 — `WebviewBridgeOutboundTests:80` stale `JarvisBusWorld` assertion.
- [ ] **Pre-existing TTSInterruptTests.testI3 flake** — `XCTAssertLessThan failed: ("10.4...") is not less than ("0.08")`. Deterministic 10s timeout in `InterruptSequence.run`; pre-dates Track B-4. Not blocking but should be triaged.
- [ ] streamTruncated empirical confirmation — re-launch app and verify cache_control fix actually completes a turn.

## Key Reference

- Audit reports: `.planning/audit-2026-05-03/{SYNTHESIS,voice,voice-audit,hud-audit,vision-audit,memory-audit,llm-audit,tests-audit}.md`
- Plan: `.planning/AUDIT-AND-FIX-PLAN.md`, findings tracker: `.planning/AUDIT-FINDINGS.md`
- Test stack at session end: Voice 77 (+7 PCMBufferBuilderTests this session, 3 skipped, 1 pre-existing TTSInterruptTests.testI3 failure), AgentCore 215/215, Replay 33/33, Bus 57/58 (1 pre-existing F-A2-01), webview/hud 94/94, all boundary gates PASS, app builds clean.
- Next-session orientation: read `.planning/audit-2026-05-03/SYNTHESIS.md` first, then this file, then `git log --oneline e9c0a34`'s commit body for the B-4 audit-and-fix story.
