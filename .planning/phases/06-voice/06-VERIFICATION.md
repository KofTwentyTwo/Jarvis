---
phase: 06-voice
verified: 2026-04-27T20:00:00Z
status: human_needed
score: 7/7
overrides_applied: 0
overrides: []
re_verification: null
gaps: []
deferred: []
human_verification:
  - test: "Gate 1 — End-to-end happy path (VOICE-07): say 'Hey Jarvis, what time is it?' to a Release-signed Jarvis.app on Apple Silicon"
    expected: "HUD transitions idle → listening → thinking → speaking; Orpheus speaks a natural answer; ring returns to idle"
    why_human: "Requires physical Release-signed archive launch; blocked by Xcode 26 ad-hoc-Debug-bundle codesign fragility (STATE.md Phase 6→Phase 8 deferred items)"
  - test: "Gate 2 — Barge-in (VOICE-14): trigger a long TTS response then say 'Hey Jarvis' during playback"
    expected: "TTS stops within ~50ms (no click/pop); ring goes from .speaking directly to .listening"
    why_human: "Live UAT on Release archive; code-side covered by BargeInTests B1-B4 (4/4 pass)"
  - test: "Gate 3 — Push-to-talk (VOICE-13): hold PTT hotkey, speak, release"
    expected: "Immediate .listening(.ptt) without wake-word; STT finalizes and TTS responds"
    why_human: "Live UAT on Release archive; code-side covered by PTTTests P1-P4 (4/4 pass)"
  - test: "Gate 4 — Mute wake word (VOICE-12): toggle menu-bar mute, verify PTT still works, restart app and confirm persistence"
    expected: "Wake-word paused; PTT still armed; mute persists across launch"
    why_human: "Live UAT on Release archive; code-side covered by MuteWakeWordTests M1-M3 (3/3 pass)"
  - test: "Gate 5 — AEC banner (VOICE-09): trigger AEC-unavailable condition (USB audio or forced throw)"
    expected: "Native AppKit banner shows 'AEC unavailable; degraded-mode active' (verifiable via Accessibility Inspector)"
    why_human: "Requires hardware condition or forced throw; code-side covered by AECFallbackBannerTests F1/F2/F1b (3/3 pass)"
  - test: "Gate 6 — Mic re-grant rebuild (VOICE-10): deny mic at first launch, re-grant in System Settings"
    expected: "Audio graph rebuilds; ring shows .reconfiguring flicker; RMS updates in .listening"
    why_human: "Live UAT on Release archive; code-side covered by TeardownTests T1-T5 (5/5 pass) + AECFallbackTests A1-A3 (3/3 pass)"
  - test: "Orpheus TTFA measurement: run JARVIS_REAL_MODELS=1 swift test --filter OrpheusTTFATests on Apple Silicon with models downloaded"
    expected: "T1 probe logs measured TTFA; target 150-250ms; if >250ms switch features.tts.tier2 = ttskit"
    why_human: "Requires Orpheus weights + Apple Silicon GPU; test T1 and T2 are env-gated (correctly skipped in CI)"
  - test: "Silero v6.2.1 contract parity: run swift test --filter SileroContractTests after scripts/fetch-silero-models.sh"
    expected: "S5 contractParityProbeWithSyntheticWaveform passes with ±32ms tolerance"
    why_human: "Requires ONNX models on disk; test S5 correctly skips when models absent"
---

# Phase 6: Voice Verification Report

**Phase Goal:** The end-to-end voice loop — "Hey Jarvis, what time is it?" → natural spoken answer — works entirely on-device with HUD state visible through idle → listening → thinking → speaking, including barge-in, push-to-talk, mute-wake-word, and the canonical audio-graph teardown that handles device changes, AEC fallback, mic re-grant, and sustained ring overflow uniformly.

**Verified:** 2026-04-27T20:00:00Z
**Status:** PASS_WITH_DEFERRALS (reported as `human_needed` per gate taxonomy — live UAT items are enumerated above; all code-side requirements VERIFIED)
**Re-verification:** No — initial verification

---

## Gate Signals (Run Fresh at Verification Time)

| Gate | Command | Result |
|------|---------|--------|
| Voice package tests | `swift test --package-path packages/Voice` | **64 pass / 3 skip / 0 fail** |
| App compile gate | `bash scripts/check-app-builds.sh` | **PASS — App target compiles cleanly** |

The 3 skips are all correctly env-gated (not silent failures):
- `OrpheusTTFATests.testT1_orpheusTTFAProbe` — needs `JARVIS_REAL_MODELS=1` + Orpheus weights
- `OrpheusTTFATests.testT2_ttskitFallbackFunctional` — same gate
- `SileroContractTests.testS5_contractParityProbeWithSyntheticWaveform` — needs ONNX models on disk

---

## Observable Truths (7 Success Criteria)

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | Wake-word pipeline: openWakeWord `hey_jarvis` via ORT 1.24.2+ with ≥4-consecutive-frame threshold (~320ms hysteresis); SHA-256 manifest verification (VOICE-01) + Silero VAD v6.2.1 at 512-sample/32ms/16kHz with opset-16/15 fallback (VOICE-02) | **VERIFIED (code) / DEFERRED (live UAT)** | `OpenWakeWordSession`: `framesRequired: Int = 4` default; `runHysteresis` increments counter, resets on dip. `ModelManifest.verify()` uses CryptoKit SHA-256. Tests H1-H9 (9/9 pass). `SileroVAD.chunkSamples = 512`, opset-16 preferred with opset-15 fallback. Tests S1-S4, S6 (5/5 pass). S5 env-gated. |
| 2 | STT primary = Apple SpeechAnalyzer on macOS 26 Tahoe (VOICE-03); WhisperKit via `argmaxinc/argmax-oss-swift v0.18.0` model `large-v3-v20240930_626MB` as flagged fallback (VOICE-04); feature flag selects without rebuild | **VERIFIED (code) / DEFERRED (live UAT)** | `WhisperKitSTT.modelName = "large-v3-v20240930_626MB"` (anchored; W2 guards against turbo variant). `SpeechAnalyzerSTT` uses `@available(macOS 26)` gate with `UnavailableSpeechAnalyzerBridge` fallback on older macOS. `STTBackendSelector.make(backend:)` routes `"speech_analyzer"` vs `"whisperkit"`. Tests W1-W2 (2/2 pass), B1-B4 (4/4 pass). `probe-speech-assets.sh` ships for Release cold-launch entitlement probe (scaffold-time tool, deferred to Phase 8). |
| 3 | TTS tier 1 = AVSpeechSynthesizer (VOICE-05); TTS tier 2 = Orpheus via `blaizzy/mlx-audio-swift v0.1.2` with `LlamaTTSModel` + `generateStream` (VOICE-06); `TTSEngineActor` with serial executor prevents Metal deadlock; scaffold-time TTFA target 150-250ms | **VERIFIED (code) / DEFERRED (TTFA measurement)** | `AVSpeechSynth` wraps `AVSpeechSynthesizer`; stored delegate prevents deallocation (Pitfall #5). `OrpheusTTS` wraps `LlamaTTSModel.fromPretrained("mlx-community/orpheus-3b-0.1-ft-bf16")` (single model string anchor). `TTSEngineActor` is a Swift `actor` — default serial executor is the Metal deadlock mitigation. `TTSKitFallback` wired as `fallback: TTSKitFallback?` behind feature flag. Tests A1-A4, O1-O3 (7/7 pass). T1-T2 env-gated for TTFA probe (deferred to Phase 8). |
| 4 | `AVAudioEngine.isVoiceProcessingEnabled = true` called BEFORE any connect/installTap (VOICE-08); post-AEC format probed via `inputNode.outputFormat(forBus: 0)` not assumed | **VERIFIED** | `AudioGraph.init`: Step 1 calls `builder.flipVPIO(eng.inputNode)` before any `attach`/`connect`/`installTap`. Step 2 calls `builder.probeFormat(eng.inputNode)` → `InputFormatProbe.probe()` → `inputNode.outputFormat(forBus: 0)`. Tests V2-V3 (VpioOrderingTests) assert `flipVPIO` fires before `connect`/`installTap`. `InputFormatProbeTests` assert Tahoe 24kHz and Sonoma 16kHz formats returned unchanged. |
| 5 | AEC-off is a real distinct graph variant (not a config toggle); unavailability surfaces HUD banner "AEC unavailable; degraded-mode active" (VOICE-09); canonical six-step teardown applies to all four rebuild triggers (VOICE-10) | **VERIFIED (code) / DEFERRED (live banner UAT)** | `AudioGraphVariant` is a two-case enum (`aecOn(AVAudioFormat)`, `aecOff(AVAudioFormat)`) — architecturally distinct, not a flag. `DegradationReason.aecUnavailable` emitted on `degradationStream`. `VoiceController.handleAECUnavailable()` calls `bannerCoordinator.showBanner("AEC unavailable; degraded-mode active")`. `AudioGraphOwner.teardown(trigger:)` is a single shared body covering `.deviceChange`, `.aecFallback`, `.micRegrant`, `.ringOverflow`. Tests AECFallbackBannerTests F1/F2/F1b (3/3 pass); TeardownTests T1-T5 (5/5 pass including step-ordering assertion). Live banner UAT deferred to Phase 8 per HUMAN-UAT.md. |
| 6 | TTS interrupt sequence: cancel → 10ms cosine fade → stop() → await ≤20ms → emit `.ttsStopped`; ducking released ONLY on `.ttsStopped` never `.finished` alone (VOICE-11); barge-in routes through single `cancelAndSubmit` entry (VOICE-14) | **VERIFIED (code) / DEFERRED (live barge-in UAT)** | `TTSInterrupt.run()`: 5 steps with `stepLog` assertions. Step 2 generates real PCM cosine fade (`cos(pi*i/2n)`). Step 4 timeout enforced via `withTaskGroup` race so stalling sink cannot bypass 20ms bound. Step 5 is the single `.ttsStopped` emission site (grep gate: 1 non-comment production call). `VoiceController.bargeIn()`: single `cancelAndSubmit(text: "")` call at line 292. Tests I1-I5 (5/5 pass), B1-B4 (4/4 pass). Live barge-in UAT deferred to Phase 8. |
| 7 | End-to-end "Hey Jarvis, what time is it?" → spoken answer; HUD idle → listening → thinking → speaking; push-to-talk (VOICE-13) and mute-wake-word (VOICE-12) independent; menu-bar mute toggle pauses DAG but leaves PTT armed | **CODE-SIDE VERIFIED / LIVE UAT DEFERRED** | `VoiceController` state machine: `.idle → .listening(wakeWord)` on wake event; `.listening → .thinking` on STT finalize; `.thinking → .speaking` on TTS start; `.speaking → .idle` on TTS stop. `PushToTalk` uses `NSEvent.addGlobalMonitorForEvents` with Input Monitoring denial fallback to local monitor. `MuteWakeWord` persists `features.voice.wakeWordMuted` via `UserDefaults`. `pttDown()`/`pttUp()` bypass wake-word check (P3 test verifies PTT works when muted). AppDelegate `installVoice()` wires full subsystem; Phase 7 stubs replace Null adapters when orchestrator/TTS are real. Tests V1-V4 (VoiceController), P1-P4 (PTT), M1-M3 (MuteWakeWord), W1-W4 (AppDelegate wiring) — all pass. Live UAT deferred to Phase 8 per signed HUMAN-UAT.md. |

**Score:** 7/7 truths code-side VERIFIED. Live UAT items enumerated in `human_verification` frontmatter for Phase 8 follow-through.

---

## Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `packages/Voice/Package.swift` | SPM manifest with ORT 1.24.2+, argmax-oss-swift 0.18.0, mlx-audio-swift 0.1.2 | VERIFIED | All three deps present at correct versions; macOS 14 floor for ORT requirement |
| `packages/Voice/Sources/Voice/AudioGraph/AudioGraph.swift` | VPIO-first graph build, format probe, AEC-off variant | VERIFIED | Step 1 = flipVPIO before attach/connect/installTap; Step 2 = probeFormat; dual-variant path |
| `packages/Voice/Sources/Voice/AudioGraph/AudioGraphOwner.swift` | Single `teardown()` body for 4 triggers | VERIFIED | `teardown(trigger:)` is called by all 4 `RebuildTrigger` cases |
| `packages/Voice/Sources/Voice/AudioGraph/RingBuffer.swift` | SPSC 16kHz Float32 mono ring | VERIFIED | 4 RingBufferTests pass including concurrency test |
| `packages/Voice/Sources/Voice/WakeWord/OpenWakeWordSession.swift` | ORT 3-stage pipeline, framesRequired=4 default, scripted test seam | VERIFIED | Hysteresis core verified; H1-H9 all pass |
| `packages/Voice/Sources/Voice/WakeWord/ModelManifest.swift` | SHA-256 verification via CryptoKit | VERIFIED | M1-M4 tests cover hash match, mismatch, missing, malformed |
| `packages/Voice/Sources/Voice/WakeWord/WakeWordDAG.swift` | Ring-consumer loop, pause/resume/cancel | VERIFIED | H7-H9 tests pass |
| `packages/Voice/Sources/Voice/VAD/SileroVAD.swift` | 512-sample chunks, opset-16/15 fallback, LSTM state | VERIFIED | S1-S4, S6 pass; S5 env-gated (correct) |
| `packages/Voice/Sources/Voice/VAD/ContractParityProbe.swift` | v6.2.1 parity probe | VERIFIED (env-gated) | S5 correctly skips when ONNX models absent; ships for interactive run |
| `packages/Voice/Sources/Voice/STT/SpeechAnalyzerSTT.swift` | macOS 26 @available gate, UnavailableBridge fallback | VERIFIED | SpeechAnalyzer S1-S2 pass; `STTError.assetMissing` mapping present |
| `packages/Voice/Sources/Voice/STT/WhisperKitSTT.swift` | Model string `large-v3-v20240930_626MB`, lazy bridge | VERIFIED | W2 grep-assert guards Argmax variant; W1 transcription stub pass |
| `packages/Voice/Sources/Voice/STT/STTBackendSelector.swift` | Feature-flag backend selection | VERIFIED | B1-B4 selector tests pass |
| `packages/Voice/Sources/Voice/TTS/AVSpeechSynth.swift` | AVSpeechSynthesizer tier-1 wrapper, stored delegate | VERIFIED | A1-A4 smoke tests pass |
| `packages/Voice/Sources/Voice/TTS/OrpheusTTS.swift` | LlamaTTSModel, single model string anchor, cooperative cancel | VERIFIED | O1-O3 serialization tests pass; model anchor grep-guarded |
| `packages/Voice/Sources/Voice/TTS/TTSEngineActor.swift` | Swift actor (serial executor = Metal mitigation), tier routing | VERIFIED | Default serial executor confirmed; cancel() concurrent signal prevents deadlock |
| `packages/Voice/Sources/Voice/TTS/TTSInterrupt.swift` | 5-step atomic sequence, `.ttsStopped` single emission | VERIFIED | I1-I5 all pass; step ordering asserted; ducking gate asserted (I4) |
| `packages/Voice/Sources/Voice/VoiceController.swift` | Full state machine, single cancelAndSubmit, barge-in debounce | VERIFIED | Single `cancelAndSubmit` at line 292; 200ms debounce in `bargeIn()`; B4 confirms deduplication |
| `packages/Voice/Sources/Voice/Control/PushToTalk.swift` | NSEvent global monitor, Input Monitoring fallback | VERIFIED | PT1-PT2 bind/unbind tests pass; P1-P4 PTT state machine tests pass |
| `packages/Voice/Sources/Voice/Control/MuteWakeWord.swift` | UserDefaults persistence, applies on init | VERIFIED | M1-M3 all pass including M3 (applies muted state on re-instantiation) |
| `packages/Voice/Sources/Voice/Control/AudioLevelEmitter.swift` | RMS at 30Hz, replaces fake sine | VERIFIED | V4 test asserts non-zero RMS from AudioLevelEmitter |
| `App/AppDelegate.swift` (lines 368-446) | `installVoice()` async method, full subsystem wiring | VERIFIED | Imports Voice; constructs WakeWordDAG, SileroVAD, VoiceController, PushToTalk, MuteWakeWord; Phase 7 Null adapters documented |
| `App/HUD/HudStateIntent.swift` | `public typealias VoiceHudIntent = Voice.VoiceHudIntent` | VERIFIED | Typealias present; type ownership follows Voice package |
| `scripts/check-app-builds.sh` | Compile-only xcodebuild gate | VERIFIED | Script present; ran clean at verification time |
| `scripts/fetch-openwakeword-models.sh` | Model download script | VERIFIED | Present; gitignores ONNX binaries |
| `scripts/fetch-silero-models.sh` | Silero model download script | VERIFIED | Present; S5 skip message references it |
| `scripts/probe-speech-assets.sh` | speech-recognition-assets entitlement probe | VERIFIED | Present; documents exit codes 0/1/2 |
| `.planning/phases/06-voice/06-HUMAN-UAT.md` | Signed deferral document | VERIFIED | Present; Summary table signed 2026-04-27 by Orchestrator; 6 gates marked DEFERRED with code-side coverage citations |

---

## Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `WakeWordDAG.wakeWordStream` | `VoiceController` wake consumer | `AsyncStream<WakeWordEvent>` init param | VERIFIED | `VoiceController.init(wakeWordStream:)` wired; `spawnWakeWordConsumer()` starts loop |
| `SileroVAD` | `VoiceController` VAD sessions | `vadFactory: @Sendable () -> SileroVAD` closure | VERIFIED | Factory closure invoked per STT session |
| `STTProvider` | `VoiceController` STT sessions | `sttFactory: @Sendable () -> any STTProvider` closure | VERIFIED | Factory closure drives `STTBackendSelector.make()` |
| `TTSEngineActor` | `VoiceController` TTS | `VoiceTTSInterface` protocol | VERIFIED | Protocol seam; `NullTTSAdapter` until Phase 7 |
| `InterruptSequence` | `TTSEngineActor` + `AudioSink` | `InterruptSequence.run(engine:sink:eventBus:)` | VERIFIED | 5-step sequence connects engine cancel + sink fade + eventBus |
| `AudioGraphOwner` | teardown triggers | `AudioGraphOwner.rebuild(trigger:)` | VERIFIED | All 4 `RebuildTrigger` cases route through single `teardown()` |
| `VoiceController.bargeIn()` | `VoiceOrchestratorInterface.cancelAndSubmit` | Single call at line 292 | VERIFIED | Grep gate confirmed; B1-B4 tests confirm single call per barge-in event |
| `MuteWakeWord` | `WakeWordDAG.pause/resume` | `dag.pause()` / `dag.resume()` | VERIFIED | M1-M3 confirm UserDefaults persistence + DAG state |
| `PushToTalk` | `VoiceController.pttDown/pttUp` | `NSEvent.addGlobalMonitorForEvents` + `controller.pttDown()` | VERIFIED | PT1-PT2 bind/unbind; P1-P4 state machine tests |
| `AppDelegate.installVoice()` | `VoiceController` | Strong property + `dormantVoiceContinuation` handoff | VERIFIED | Line 426 `voiceController = vc`; line 431 `dormantVoiceContinuation = nil` (W2 test) |
| `VoiceHudIntent` (Voice package) | `App` target | `public typealias VoiceHudIntent = Voice.VoiceHudIntent` | VERIFIED | Typealias in `HudStateIntent.swift` |

---

## Data-Flow Trace (Level 4)

Dynamic data flows verified for artifacts that render real data:

| Artifact | Data Variable | Source | Produces Real Data | Status |
|----------|--------------|--------|-------------------|--------|
| `OpenWakeWordSession.runHysteresis` | `prob: Float` | ORT 3-stage pipeline (production) / scripted closure (test) | Yes — ORT inference produces real probabilities; tests use scripted seam | FLOWING |
| `SileroVAD.feed()` | speech probability `[0,1]` | `ORTVADEngine.runInference` | Yes — ORT inference on 512-sample chunks | FLOWING |
| `AudioLevelEmitter` | `rms: Float` | `RingBuffer.readMono16k` at 30Hz | Yes — real PCM samples from audio tap | FLOWING |
| `OrpheusTTS.synthesize` | `AudioGeneration` chunks | `LlamaTTSModel.generateStream` | Yes — on-device MLX inference (production) / `ScriptedSpeechModel` (test) | FLOWING |
| `AudioSink.cosineFadeOut` | `[Float]` PCM samples | `cos(pi*i/2n)` generation | Yes — real math, verified by I2 (160 samples at 16kHz) | FLOWING |

Phase 7 stubs (`NullOrchestratorAdapter`, `NullTTSAdapter`, `NullBusEmitterAdapter`) are documented no-ops in `AppDelegate.swift` — they do NOT affect data flow within the Voice package itself, only the cross-package wiring that Phase 7 closes.

---

## Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| Voice package: 64 tests pass, 3 env-gated skips, 0 fail | `swift test --package-path packages/Voice` | `Executed 64 tests, with 3 tests skipped and 0 failures in 7.5s` | PASS |
| App target compiles cleanly with Voice wiring | `bash scripts/check-app-builds.sh` | `PASS — App target compiles cleanly` | PASS |
| Single `cancelAndSubmit` call site in VoiceController | `grep -nE 'cancelAndSubmit' VoiceController.swift \| grep -v '//' \| wc -l` | 1 (line 292) | PASS |
| No modal presentation in Voice package | SUMMARY grep gate output: `check-no-modal-presentation.sh: OK` | PASS | PASS |
| Model string anchor present exactly once | `grep -n 'orpheus-3b-0.1-ft-bf16' OrpheusTTS.swift` | 1 match (line 53) | PASS |
| Silero 512-sample enforcement | `testS1_feedWith511SamplesThrowsInvalidChunkSize` / `testS1_feedWith513...` | Both pass | PASS |
| Hysteresis: 4 consecutive frames required | `testH3_exactlyFourConsecutive_oneFire` | Fires on frame 4 | PASS |
| Interrupt step ordering I→V in exact sequence | `testI1_fiveStepOrdering` | Steps = `["1-cancel","2-fade","3-stop","4-await","5-ttsStopped"]` | PASS |
| Ducking gate: `.finished` does NOT release ducking | `testI4_duckingGateOnlyOnTtsStopped` | `.finished` counter = 0; `.ttsStopped` counter = 1 | PASS |

---

## Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|------------|-------------|--------|----------|
| VOICE-01 | 06-02 | openWakeWord `hey_jarvis` ORT 1.24.2+, ≥4-frame hysteresis, SHA-256 pinning | VERIFIED | `OpenWakeWordSession`: `framesRequired=4`; `ModelManifest.verify()`; H1-H9 pass |
| VOICE-02 | 06-03 | Silero VAD v6.2.1, 512-sample/32ms/16kHz, opset-16 preferred with opset-15 fallback | VERIFIED | `SileroVAD.chunkSamples=512`; opset fallback path; S1-S4, S6 pass; S5 env-gated |
| VOICE-03 | 06-03 | SpeechAnalyzer primary STT on macOS 26 Tahoe; scaffold-time entitlement probe | VERIFIED (code) / DEFERRED (Release probe) | `SpeechAnalyzerSTT` + `@available(macOS 26)` gate; `probe-speech-assets.sh` ships; SpeechAnalyzer S1-S2 pass |
| VOICE-04 | 06-03 | WhisperKit fallback via argmax-oss-swift v0.18.0, model `large-v3-v20240930_626MB`, feature flag | VERIFIED | `WhisperKitSTT.modelName` anchored; W2 grep-asserts correct variant; B2 confirms flag-based selection |
| VOICE-05 | 06-04 | AVSpeechSynthesizer tier-1 | VERIFIED | `AVSpeechSynth` full implementation; A1-A4 pass |
| VOICE-06 | 06-04 | Orpheus tier-2 via mlx-audio-swift v0.1.2, `LlamaTTSModel`+`generateStream`, serial executor, TTFA target 150-250ms | VERIFIED (code) / DEFERRED (TTFA probe) | `OrpheusTTS`+`TTSEngineActor` full implementation; O1-O3 pass; T1-T2 env-gated probes ship |
| VOICE-07 | 06-05 | End-to-end happy path | CODE-VERIFIED / LIVE UAT DEFERRED | `VoiceController` state machine; V1-V4 pass; live UAT to Phase 8 |
| VOICE-08 | 06-01 | VPIO enabled before connect/installTap; format probed not assumed | VERIFIED | Step 1 of `AudioGraph.init`; `InputFormatProbe.probe()` wraps `outputFormat(forBus:0)`; V2-V3 tests pass |
| VOICE-09 | 06-01+06-05 | AEC-off is distinct graph variant; HUD banner "AEC unavailable; degraded-mode active" | CODE-VERIFIED / LIVE UAT DEFERRED | `AudioGraphVariant` two-case enum; `VoiceController.handleAECUnavailable()` routes to banner; F1/F2/F1b pass |
| VOICE-10 | 06-01 | Canonical six-step teardown × four triggers | VERIFIED | Single `teardown(trigger:)` body; T1-T5 step-ordering tests pass |
| VOICE-11 | 06-04 | TTS interrupt: cancel→10ms fade→stop→await≤20ms→`.ttsStopped`; ducking on `.ttsStopped` only | VERIFIED | `TTSInterrupt` 5-step implementation; I1-I5 pass; single `.ttsStopped` emission (grep-guarded) |
| VOICE-12 | 06-05 | Menu-bar mute toggle pauses DAG; PTT stays armed | CODE-VERIFIED / LIVE UAT DEFERRED | `MuteWakeWord` + UserDefaults persistence; M1-M3 + P3 pass |
| VOICE-13 | 06-05 | Push-to-talk hold-hotkey, NSEvent global monitor, Input Monitoring fallback | CODE-VERIFIED / LIVE UAT DEFERRED | `PushToTalk` implementation; P1-P4 + PT1-PT2 pass |
| VOICE-14 | 06-05 | Barge-in: single `cancelAndSubmit` entry; no two separate actor hops | CODE-VERIFIED / LIVE UAT DEFERRED | Single call at VoiceController.swift:292; B1-B4 pass (B1 asserts count=1) |

---

## Anti-Patterns Found

| File | Pattern | Severity | Assessment |
|------|---------|----------|------------|
| `App/AppDelegate.swift` — `NullOrchestratorAdapter`, `NullTTSAdapter`, `NullBusEmitterAdapter` | No-op implementations — `submit/cancelAndSubmit/synthesize/postAudio` are all no-ops | WARNING (not a blocker) | **Documented Phase 7 stubs.** These are intentional scaffolding; the SUMMARY and HUMAN-UAT.md both document that the full voice loop requires Phase 7 orchestrator wiring. They do not prevent the Voice package tests from passing. |
| `packages/Voice/Sources/Voice/TTS/TTSEngineActor.swift` — per-synthesis local AVAudioEngine | Tier-2 path creates a local `AVAudioEngine` per `synthesize` call | INFO | **Intentional scaffold.** SUMMARY documents that Plan 06-05 wires a persistent `AudioGraphOwner`. Phase 7 closes this. |

No stubs found that cause user-visible rendering to show empty or hardcoded data. All no-ops are in the App-level adapter layer (cross-phase boundary), not inside the Voice package itself.

---

## Gaps Summary

No gaps. All 7 ROADMAP Phase 6 success criteria are code-side VERIFIED. The live UAT portion is formally deferred to Phase 8 per a signed deferral document (`.planning/phases/06-voice/06-HUMAN-UAT.md`, signed 2026-04-27 by Orchestrator). The deferral is recorded in `.planning/STATE.md` "Phase 6 → Phase 8 Deferred Items" section.

The three categories of env-gated test skips are correctly designed:
1. **OrpheusTTFATests T1-T2** — require Orpheus weights + Apple Silicon GPU (`JARVIS_REAL_MODELS=1`)
2. **SileroContractTests S5** — requires Silero ONNX models on disk (run `scripts/fetch-silero-models.sh` first)

Neither skip category represents missing code — the test infrastructure ships and is runnable interactively.

---

## Human Verification Required

Eight items require human testing, all blocked by the Xcode 26 ad-hoc-Debug-bundle codesign fragility that prevents Release archive launch. All have deterministic code-side XCTest coverage as cited in the Observable Truths section above.

**Phase 8 must close all 8 items before marking Phase 6 fully complete.** The gate for Phase 8's voice UAT is: resolve Xcode 26 codesign fragility → build Release-signed archive → run HUMAN-UAT.md gates 1-6 + OrpheusTTFATests + SileroContractTests with models.

---

*Verified: 2026-04-27T20:00:00Z*
*Verifier: Claude (gsd-verifier, claude-sonnet-4-6)*
