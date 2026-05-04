# Voice

The voice loop: audio graph + wake word + VAD + STT + TTS + the state machine actor that stitches them. Local-only by user constraint — no cloud STT/TTS.

## Key public types

| Type | Purpose |
|------|---------|
| `VoiceController` (actor) | Top-level state machine — `idle / listening / thinking / speaking` |
| `VoiceState` | State enum |
| `AudioGraphOwner` (actor) | `AVAudioEngine` lifecycle + canonical six-step teardown (VOICE-10) |
| `BufferBroadcaster` | Multi-consumer fan-out from the Core Audio tap (Track B-7) |
| `RingBuffer` | SPSC ring (one consumer per ring; never read directly outside Voice) |
| `WakeWordDAG` | mel ring → embedding ring → classifier; openWakeWord `hey_jarvis`; 4-frame hysteresis |
| `OpenWakeWordSession` | ONNX Runtime session wrapper |
| `SileroVAD` | VAD on 512-sample / 32 ms / 16 kHz windows |
| `SpeechAnalyzerSTT` | macOS 26 Tahoe primary (gated by `@available(macOS 26, *)`) |
| `WhisperKitSTT` | Argmax `large-v3-v20240930_626MB` fallback (feature-flagged) |
| `STTProvider` (protocol) | Common contract |
| `TTSEngineActor` | Tier-1 / tier-2 dispatcher with serial executor (prevents Metal cmd-buffer deadlock) |
| `AVSpeechSynth` | Tier-1 `AVSpeechSynthesizer` (instant, mediocre) |
| `OrpheusTTS` | Tier-2 (deferred — weights download outstanding) |
| `TTSKitFallback` | Tier-2 fallback via Argmax `TTSKit` |
| `AudioLevelEmitter` | RMS → `BusOutbound.audioLevel` for HUD pulse (production wiring open) |
| `PushToTalk` / `MuteWakeWord` | Per-call control surface |

## Depends on

`AgentCore`, `Bus`, `Logging`, `Config`. External: `onnxruntime-swift-package-manager`, `argmax-oss-swift` (WhisperKit + TTSKit), `mlx-audio-swift` (Orpheus), `swift-atomics`, `swift-log`.

## Used by

`App/AppDelegate`, `App/Voice/` (production adapters — `VoiceOrchestratorAdapter`, `VoiceTTSAdapter`, `VoiceBusEmitterAdapter`).

## Key invariants / contracts

- **VOICE-14 single `cancelAndSubmit` call site.** Only `VoiceController.bargeIn()`. Grep-gated.
- **T-06-05-03: never log voice transcript text.** Every Voice `logger.debug` call site reviewed.
- **T-06-05-02: AEC banner via native AppKit, never webview modal.** `scripts/check-no-modal-presentation.sh`.
- **T-06-05-04: 200 ms barge-in debounce.** `BargeInTests` B4.
- **VOICE-12: PTT works when wake-word is muted.** `pttDown()` / `pttUp()` bypass the mute gate.
- **VOICE-09: AEC-off as distinct variant.** If `setVoiceProcessingEnabled(true)` throws, emit `.aecUnavailable` THEN rebuild with `aec: false`.
- **VOICE-10: six-step teardown.** All four rebuild triggers call the single `teardown()` private method on `AudioGraphOwner`.
- **Multi-consumer audio: `BufferBroadcaster.subscribe()`, never raw `RingBuffer`** outside the Voice package. `RingBuffer` is documented SPSC.
- **`BufferBroadcaster.publish` is real-time-thread-safe.** Lock-free / wait-free `OSAllocatedUnfairLock` snapshot — no actor hops, no Foundation locks.
- **VAD-gated session end.** STT session ends on `.speechEnd` + 5-chunk hangover (~160 ms). Mid-utterance speech resumption cancels the pending finalize.
- **`TTSEngineActor` serial executor.** Prevents Metal command-buffer serialization deadlock on rapid-fire syntheses.
- **Test seam visibility.** `_forceState`, `_testFireSpeechEnd`, `_testCurrentSttSessionId` are `internal` (P2-14); tests use `@testable import`.

## Tests

87 XCTest + 23 swift-testing (3 skipped). Includes `BufferBroadcasterTests` (BB-1..5 incl. concurrent stress), `VoiceLoopE2ETests` (E1..E3 — preset chunks → orchestrator.submit), `VADGatedSessionTests` (VAD-1..5), `BargeInTests` (B1..B4). Pre-existing 10s flake on `TTSInterruptTests.testI3` (fixed in audit-2026-05-04 batch — propagates consumer cancellation in `ScriptedSpeechModel`).

## Notable files

- `Sources/Voice/VoiceController.swift` — top-level state machine
- `Sources/Voice/AudioGraph/AudioGraphOwner.swift` — engine lifecycle
- `Sources/Voice/AudioGraph/BufferBroadcaster.swift` — multi-consumer fan-out
- `Sources/Voice/STT/SpeechAnalyzerSTT.swift` — macOS 26 STT
- `Sources/Voice/TTS/TTSEngineActor.swift` — tier-1 / tier-2 dispatcher
