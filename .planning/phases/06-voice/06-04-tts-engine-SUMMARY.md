---
phase: "06"
plan: "04"
subsystem: voice
tags: [tts, actors, swift-concurrency, audio, orpheus, mlx, avfoundation]
dependency_graph:
  requires: [06-01-audio-graph, 06-02-wake-word, 06-03-vad-stt]
  provides: [tts-engine-actor, interrupt-sequence, tts-event-stream]
  affects: [packages/Voice]
tech_stack:
  added:
    - MLXAudioTTS (mlx-audio-swift v0.1.2) — OrpheusTTS tier-2 engine
    - TTSKit (argmax-oss-swift v0.18.0) — feature-flag-gated fallback
  patterns:
    - Swift actor as serial executor (Metal deadlock mitigation)
    - Protocol-based test seams (SpeechGenerationModelProtocol, InterruptibleAudioSink)
    - DispatchQueue.sync for @unchecked Sendable state in async actors
    - withTaskGroup racing Task.sleep for hard timeout enforcement
key_files:
  created:
    - packages/Voice/Sources/Voice/TTS/TTSEvent.swift
    - packages/Voice/Sources/Voice/TTS/TTSError.swift
    - packages/Voice/Sources/Voice/TTS/AudioSink.swift
    - packages/Voice/Sources/Voice/TTS/AVSpeechSynth.swift
    - packages/Voice/Sources/Voice/TTS/OrpheusTTS.swift
    - packages/Voice/Sources/Voice/TTS/TTSEngineActor.swift
    - packages/Voice/Sources/Voice/TTS/TTSKitFallback.swift
    - packages/Voice/Sources/Voice/TTS/TTSInterrupt.swift
    - packages/Voice/Tests/VoiceTests/AVSpeechSmokeTests.swift
    - packages/Voice/Tests/VoiceTests/OrpheusSerializationTests.swift
    - packages/Voice/Tests/VoiceTests/TTSInterruptTests.swift
  modified:
    - packages/Voice/Package.swift (added MLXAudioTTS + TTSKit product deps)
decisions:
  - "TTSEngineActor uses Swift actor DEFAULT serial executor (not custom) — this IS the Metal deadlock mitigation; no additional locking needed"
  - "ScriptedSpeechModel emits only .token(Int) events — avoids MLXArray Metal GPU requirement in SPM test runner"
  - "InterruptSequence step-4 timeout enforced via withTaskGroup racing Task.sleep, NOT passed to sink — ensures timeout even if sink ignores it"
  - "OrpheusTTS.cancel() called CONCURRENTLY with outer task.cancel() — awaiting task.value first would deadlock (actor-isolated cancel blocks on actor queue)"
  - "cosineFadeOut generates actual PCM samples (cos(pi*i/2n)) — NOT an AVAudioPlayerNode volume ramp, matching VOICE-11 spec"
  - "TTSKit init maps string to TTSModelVariant enum; play uses text: + playbackStrategy: .auto label signature"
metrics:
  duration: "~45 minutes (multi-session)"
  completed: "2026-04-27"
  tasks_completed: 3
  files_created: 11
  files_modified: 1
  tests_added: 12
---

# Phase 6 Plan 4: TTS Engine Summary

TTS tiers 1+2 behind a single `TTSEngineActor` (Swift actor default serial executor as Metal deadlock mitigation), 5-step atomic `InterruptSequence` (VOICE-11), TTSKit fallback behind feature-flag seam, and 12 TDD tests covering serialization, interrupt ordering, ducking gate, and cosine fade math.

## What Was Built

### Task 1 — Core TTS types + AudioSink + AVSpeechSynth (commit `f1e1363`)

**TTSEvent.swift** — Four-case event enum with ducking-gate documentation built into the type:
- `.started` — synthesis initiated
- `.firstAudio(at: Date)` — TTFA timestamp for latency tracking
- `.finished` — producer stream exhausted (NOT the ducking-release gate)
- `.ttsStopped` — audio sink drained — THIS is the ducking-release gate (VOICE-11 / Pitfall #6)

**TTSError.swift** — Four-case error enum: `modelLoadFailed`, `synthesisFailed`, `cancelled`, `sinkUnavailable`.

**AudioSink.swift** — `AVAudioPlayerNode`-backed audio sink with:
- `enqueue([Float])` — schedules PCM buffers, tracks `pendingBuffers` counter via completion callbacks
- `cosineFadeOut(duration:)` — generates real cosine PCM samples `cos(pi*i/2n)` from 1.0→0.0, stores in `lastFadeSamples` for test inspection
- `awaitCompletion(timeout:)` — uses `CheckedContinuation` + timeout task + `ContinuationBox` one-shot guard
- State tracked via `DispatchQueue.sync` (NSLock unavailable from async contexts in Swift 6)

**AVSpeechSynth.swift** — `AVSpeechSynthesizer` wrapper with:
- Stored synthesizer AND delegate (prevents delegate deallocation — Pitfall #5 guard)
- `stopSpeaking(at: .immediate)` called BEFORE every `speak` call (cancels previous utterance)
- `onStop: (@Sendable () -> Void)?` test seam for rapid-fire stop counting

### Task 2 — OrpheusTTS + TTSEngineActor + TTSKitFallback (commit `f9e7701`)

**OrpheusTTS.swift** — Swift actor wrapping `LlamaTTSModel`:
- `SpeechGenerationModelProtocol` test seam: `makeStream(text:voice:) -> AsyncThrowingStream<AudioGeneration, Error>`
- `LlamaTTSModelWrapper` bridges real model to protocol
- `synthesize(_:voice:into:onFirstAudio:)` — TTFA callback fires on first `.audio` event
- Cooperative cancellation: `Task.checkCancellation()` after each chunk
- Model string anchor: `"mlx-community/orpheus-3b-0.1-ft-bf16"` appears exactly once (grep gate)

**TTSEngineActor.swift** — Public actor coordinating both tiers:
- `ttsEventStream: AsyncStream<TTSEvent>` as `nonisolated let` (HUD + ducking subscriber)
- `hasSynthInFlight: Bool` — idempotency probe for `InterruptSequence`
- `synthesize(_:tier:voice:)` — cancel-before-start reentrancy guard
- Tier-2 path creates local `AVAudioEngine` + `AudioSink` per synthesis (Plan 06-05 wires persistent `AudioGraphOwner`)
- `cancel()` fires `taskToCancel.cancel()` + `await orpheus.cancel()` CONCURRENTLY then awaits — prevents actor-isolation deadlock

**TTSKitFallback.swift** — Feature-flag-gated TTSKit wrapper:
- Maps string model names to `TTSModelVariant` enum
- `synthesize(_:into:)` delegates to `kit.play(text:playbackStrategy:.auto)`
- Wired as `fallback: TTSKitFallback?` in `TTSEngineActor` (nil = disabled, Plan 06-05 flips flag)

### Task 3 — InterruptSequence + 5 interrupt tests (commit `4d7bd76`)

**TTSInterrupt.swift** — 5-step atomic interrupt sequence (VOICE-11):
1. `engine.cancel()` — cooperative producer cancellation
2. `sink.cosineFadeOut(.milliseconds(10))` — anti-click fade
3. `sink.stop()` — halt buffer scheduling
4. `sink.awaitCompletion` bounded ≤ 20 ms (via `withTaskGroup` race, NOT sink-side timeout)
5. `eventBus.yield(.ttsStopped)` — **single ducking-release gate** (single source of truth)

Protocols for test injection:
- `InterruptibleAudioSink` — `cosineFadeOut`, `stop`, `awaitCompletion`
- `InterruptStepRecorder` — `record(_:)` for ordered step assertion
- `AudioSink` extended to conform to `InterruptibleAudioSink` automatically

## Test Coverage

All 12 tests pass (run with `--filter` to reach XCTest classes):

| Suite | Tests | What they verify |
|-------|-------|-----------------|
| `AVSpeechSmokeTests` | A1–A4 | speak resolves <2 s; stop-before-speak; awaitCompletion; cosine 160 samples |
| `OrpheusSerializationTests` | O1–O3 | FIFO serial executor; no deadlock under 10 concurrent; cancel→continue |
| `TTSInterruptTests` | I1–I5 | Step ordering; 10 ms fade; ≤20 ms timeout; ducking gate; idempotency |

Tests `T1`/`T2` in `OrpheusTTFATests` are gated by `JARVIS_REAL_MODELS=1` (require Orpheus weights + Apple Silicon GPU) and are correctly skipped in CI.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] NSLock unavailable from async contexts (Swift 6)**
- **Found during:** Task 1 (AudioSink)
- **Issue:** `NSLock.lock()` / `unlock()` cannot be called from async Swift 6 contexts — `Sendable` conformance rejection
- **Fix:** Switched all state mutations in `AudioSink` to `DispatchQueue.sync`
- **Files modified:** `AudioSink.swift`
- **Commit:** `f1e1363`

**2. [Rule 1 - Bug] OrpheusTTS `private model` inaccessible from TTSEngineActor**
- **Found during:** Task 2 (TTSEngineActor)
- **Issue:** `TTSEngineActor` needed to call `orpheus.synthesize(text:voice:into:onFirstAudio:)` but the original `OrpheusTTS.synthesize` didn't have an `onFirstAudio` callback parameter
- **Fix:** Added `onFirstAudio: (@Sendable (Date) -> Void)?` parameter to `OrpheusTTS.synthesize`; `model` promoted to `internal let` for test access
- **Files modified:** `OrpheusTTS.swift`, `TTSEngineActor.swift`
- **Commit:** `f9e7701`

**3. [Rule 1 - Bug] TTSKit init takes TTSModelVariant enum, not String**
- **Found during:** Task 2 (TTSKitFallback)
- **Issue:** `TTSKit.init(modelVariant:)` requires `TTSModelVariant` enum value; String init does not exist
- **Fix:** Added string→enum mapping in `TTSKitFallback.init`
- **Files modified:** `TTSKitFallback.swift`
- **Commit:** `f9e7701`

**4. [Rule 1 - Bug] MLXArray creation requires Metal GPU (metallib crash in SPM test runner)**
- **Found during:** Task 3 (OrpheusSerializationTests GREEN phase)
- **Issue:** `ScriptedSpeechModel` initially emitted `.audio(MLXArray([...]))` causing "Failed to load the default metallib" crash
- **Fix:** `ScriptedSpeechModel` now emits only `.token(Int)` events; `OrpheusTTS.synthesize` gracefully handles streams with no `.audio` events
- **Files modified:** `OrpheusSerializationTests.swift`
- **Commit:** `f9e7701`

**5. [Rule 1 - Bug] InterruptSequence step-4 timeout bypassed by stalling sink**
- **Found during:** Task 3 (I3 test taking 10+ seconds)
- **Issue:** `InterruptSequence.run` passed `timeout:` to `sink.awaitCompletion(timeout:)` but `StallingSink` (and in theory any sink) could ignore it
- **Fix:** Step 4 wrapped in `withTaskGroup` racing `Task.sleep(for: .milliseconds(20))` — timeout enforced at the `InterruptSequence` level regardless of sink behavior
- **Files modified:** `TTSInterrupt.swift`
- **Commit:** `4d7bd76`

**6. [Rule 1 - Bug] TTSEngineActor.cancel() deadlocked when awaiting task before orpheus.cancel()**
- **Found during:** Task 3 (I1 and I3 tests stalling 10+ seconds)
- **Issue:** Original `cancel()` called `_ = try? await taskToCancel?.value` before `await orpheus.cancel()`. Since `TTSEngineActor.currentTask` awaits an actor-isolated `OrpheusTTS.synthesize` call, and Swift task cancellation does NOT propagate across actor-isolated calls, this deadlocked.
- **Fix:** Reordered to: `taskToCancel.cancel()` → `await orpheus.cancel()` → `_ = try? await taskToCancel?.value` (concurrent cancel signals before awaiting drain)
- **Files modified:** `TTSEngineActor.swift`
- **Commit:** `4d7bd76`

## Known Stubs

- **TTSKitFallback** in `TTSEngineActor.synthesize` tier-2 path: `let _ = fallbackCopy` — TTSKit fallback is wired as a parameter but not yet invoked; invocation is gated on feature flag in Plan 06-05.
- **AudioSink per-synthesis**: The tier-2 path creates a local `AVAudioEngine` + `AVAudioPlayerNode` per `synthesize` call. Plan 06-05 wires a persistent `AudioGraphOwner` from Phase 6 Plan 1.

These stubs are intentional scaffolding — they do not prevent plan 06-04's goal (TTS engine + interrupt tests) from being achieved.

## Threat Flags

None. All new surface is in-process audio (no new network endpoints, no file access, no trust boundary crossings).

## Self-Check: PASSED

Files verified present:
- `packages/Voice/Sources/Voice/TTS/TTSEvent.swift` ✓
- `packages/Voice/Sources/Voice/TTS/TTSError.swift` ✓
- `packages/Voice/Sources/Voice/TTS/AudioSink.swift` ✓
- `packages/Voice/Sources/Voice/TTS/AVSpeechSynth.swift` ✓
- `packages/Voice/Sources/Voice/TTS/OrpheusTTS.swift` ✓
- `packages/Voice/Sources/Voice/TTS/TTSEngineActor.swift` ✓
- `packages/Voice/Sources/Voice/TTS/TTSKitFallback.swift` ✓
- `packages/Voice/Sources/Voice/TTS/TTSInterrupt.swift` ✓
- `packages/Voice/Tests/VoiceTests/AVSpeechSmokeTests.swift` ✓
- `packages/Voice/Tests/VoiceTests/OrpheusSerializationTests.swift` ✓
- `packages/Voice/Tests/VoiceTests/TTSInterruptTests.swift` ✓

Commits verified:
- `f1e1363` (Task 1) ✓
- `f9e7701` (Task 2) ✓
- `4d7bd76` (Task 3) ✓

All 12 TTS tests pass (AVSpeechSmokeTests A1-A4, OrpheusSerializationTests O1-O3, TTSInterruptTests I1-I5).
Build: `swift build -c debug` — clean.
