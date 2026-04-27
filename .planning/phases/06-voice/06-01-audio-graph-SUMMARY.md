---
phase: "06-voice"
plan: "01"
subsystem: "AudioGraph"
completed: "2026-04-27T16:19:41Z"
duration: "19m"
tags: [voice, audio-graph, avaudioengine, vpio, aec-fallback, teardown, ring-buffer, foundation]
requirements: [VOICE-08, VOICE-09, VOICE-10]
dependency_graph:
  requires: []
  provides:
    - packages/Voice (new SPM package, AudioGraph subsystem)
    - AudioGraphOwner actor (open, rebuild, shutdown, currentVariant, ringBuffer, degradationStream, rebuildStream)
    - RingBuffer (16 kHz Float32 mono SPSC)
  affects:
    - packages/Voice/Package.swift (closed for Phase 6 — all 3 deps pinned)
tech_stack:
  added:
    - packages/Voice (swift-tools-version 6.0)
    - onnxruntime-swift-package-manager ~> 1.24.2 (pinned, no imports yet — Plan 06-02)
    - argmax-oss-swift ~> 0.18.0 (pinned, no imports yet — Plan 06-03)
    - mlx-audio-swift ~> 0.1.2 (pinned, no imports yet — Plan 06-04)
  patterns:
    - GraphBuilder protocol injection for AVAudioEngine wiring (enables test isolation without live hardware)
    - SPSC RingBuffer with sustained-overflow detection (Pitfall #4)
    - AsyncStream<T>.makeStream() for degradation + rebuild event streams
    - nonisolated(unsafe) for test seams on static/stored vars
key_files:
  created:
    - packages/Voice/Package.swift
    - packages/Voice/Sources/Voice/VoiceError.swift
    - packages/Voice/Sources/Voice/AudioGraph/AudioGraph.swift
    - packages/Voice/Sources/Voice/AudioGraph/AudioGraphVariant.swift
    - packages/Voice/Sources/Voice/AudioGraph/AudioGraphOwner.swift
    - packages/Voice/Sources/Voice/AudioGraph/AudioGraphError.swift
    - packages/Voice/Sources/Voice/AudioGraph/DegradationReason.swift
    - packages/Voice/Sources/Voice/AudioGraph/RebuildTrigger.swift
    - packages/Voice/Sources/Voice/AudioGraph/RebuildEvent.swift
    - packages/Voice/Sources/Voice/AudioGraph/InputFormatProbe.swift
    - packages/Voice/Sources/Voice/AudioGraph/RingBuffer.swift
    - packages/Voice/Tests/VoiceTests/InputFormatProbeTests.swift
    - packages/Voice/Tests/VoiceTests/RingBufferTests.swift
    - packages/Voice/Tests/VoiceTests/VpioOrderingTests.swift
    - packages/Voice/Tests/VoiceTests/AECFallbackTests.swift
    - packages/Voice/Tests/VoiceTests/TeardownTests.swift
decisions:
  - "GraphBuilder protocol with probeFormat + startEngine injection seams avoids global mutable state for test isolation (superior to _probeOverride global)"
  - "TeardownRecorder uses NSLock (not actor) to allow synchronous hook calls from Core Audio-thread-adjacent paths"
  - "AudioGraph._stopHook/_removeTapsHook/_releaseRingsHook + AudioGraphOwner._onGraphBuilt enable teardown-ordering tests without a live audio device"
  - "AVAudioEngineConfigurationChangeNotification raw string used (AVAudioEngine.configurationChangeNotification does not exist as a Swift static on macOS)"
  - "GraphBuilder.connect() is not throwing — AlwaysFailingBuilder uses startEngine throw to test bothVariantsFailed path"
metrics:
  task_count: 3
  test_count: 17
  file_count: 16
---

# Phase 6 Plan 01: Audio-Graph Foundation Summary

SPM `packages/Voice` package landed with the full AudioGraph subsystem: VPIO-ordered engine
build, post-AEC format probe, SPSC ring buffer, AEC-off as distinct variant, and canonical
six-step teardown × four rebuild triggers. All three Phase 6 external deps are pinned in
`Package.swift` so Wave-2 plans run in disjoint worktrees without touching the manifest.

## Seven Primitive Types Added

| Type | File | Purpose |
|------|------|---------|
| `AudioGraphVariant` | `AudioGraphVariant.swift` | Two-case enum `.aecOn(AVAudioFormat)` / `.aecOff(AVAudioFormat)` — distinct graph builds per VOICE-09 |
| `AudioGraphError` | `AudioGraphError.swift` | Five-case error: `vpioNotEnabled`, `formatProbeFailed`, `aecUnavailable`, `engineStartFailed`, `bothVariantsFailed` |
| `DegradationReason` | `DegradationReason.swift` | `.aecUnavailable` case surfaced on `degradationStream` for HUD banner (Plan 06-05) |
| `RebuildTrigger` | `RebuildTrigger.swift` | `.deviceChange`, `.aecFallback`, `.micRegrant`, `.ringOverflow` — four triggers, one teardown |
| `RebuildEvent` | `RebuildEvent.swift` | `.reconfiguring(reason: RebuildTrigger)` emitted at step 6 of teardown |
| `InputFormatProbe` | `InputFormatProbe.swift` | `probe(inputNode:) -> AVAudioFormat` wrapper around `outputFormat(forBus: 0)` |
| `RingBuffer` | `RingBuffer.swift` | SPSC 16 kHz Float32 mono ring; `write`, `readMono16k`, `consumerLagMs`, `overflowDetected` |

Bonus: `VoiceError` (top-level envelope) and `GraphBuilder` protocol (test injection seam for all AVFoundation wiring).

## Canonical Six-Step Teardown Pseudocode (VOICE-10)

Verbatim from `AudioGraphOwner.teardown(trigger:)`:

```swift
private func teardown(trigger: RebuildTrigger) async {
    await cancelInFlight?()                         // (1) cancel in-flight callbacks
    graph?._stopHook?();  graph?.stop()             // (2) stop the engine
    graph?.removeAllTaps(); graph?._removeTapsHook?() // (3) remove all taps
    graph?.releaseRings(); graph?._releaseRingsHook?() // (4) release ring buffers
    await releaseORTSessions?()                     // (5) release ORT sessions (no-op slot)
    rebuildCont.yield(.reconfiguring(reason: trigger)) // (6) emit rebuild event
}
```

All four `RebuildTrigger` cases route through this single `func teardown()` body — DRY per VOICE-10.

## Two `(@Sendable () async -> Void)?` Slots Reserved

| Slot | Owner actor property | Populated by |
|------|---------------------|--------------|
| `cancelInFlight` | `AudioGraphOwner.cancelInFlight` | Plan 06-02: wake-word + VAD DAG cancellation |
| `releaseORTSessions` | `AudioGraphOwner.releaseORTSessions` | Plan 06-04: TTS ORT session release |

Both are `nil` in this plan. Downstream wiring is purely additive.

## Wave-2 Promise: `Package.swift` is Closed

Plans 06-02 (WakeWord) and 06-03 (VAD/STT) run in disjoint worktrees during Wave 2. `Package.swift`
pins all three deps now:

- `onnxruntime-swift-package-manager` from `1.24.2` — for Plans 06-02/03 (ORT inference)
- `argmax-oss-swift` from `0.18.0` — for Plan 06-03 (WhisperKit STT fallback)
- `mlx-audio-swift` from `0.1.2` — for Plan 06-04 (Orpheus TTS tier 2)

No source imports for these deps exist yet; the manifest is closed for Wave 2 parallelism.
`swift package resolve` exits 0 with all three deps fetched.

## Test Counts (RED → GREEN per Task)

| Task | RED commit | GREEN commit | Test count |
|------|-----------|-------------|-----------|
| Task 1: SPM manifest + primitives | `68fb0d9` | `64e2fdb` | 6 (RingBuffer 4 + InputFormatProbe 2) |
| Task 2: AudioGraph + AudioGraphOwner | `2de87c8` | `fe87b2b` | 6 (VpioOrdering 3 + AECFallback 3) |
| Task 3: Six-step teardown × four triggers | (same PR) | `7c7c659` | 5 (TeardownTests T1..T5) |

**Total: 17 tests across 5 suites — all pass.**

```
✔ Test run with 17 tests in 5 suites passed after 2.307 seconds.
```

Debug + Release build: clean.
`swift package resolve`: exits 0.

## Anti-Pattern Callouts (Preserved for Future Maintainers)

Inline comments anchor these in the source; re-stated here for surfaceability:

1. **DO NOT flip `isVoiceProcessingEnabled` after any `connect`/`installTap`** — silent no-op on Tahoe, crash on Sonoma (Pitfall #7). See `AudioGraph.swift` step 1.
2. **DO NOT treat AEC-off as a runtime toggle** — it's a distinct graph build (VOICE-09). `AudioGraphVariant.aecOff` is a rebuild, not a flag flip.
3. **DO NOT rate-convert before channel-coerce** (Pitfall #3 / R4-D4). The mixer (channel-coerce) precedes the tap's implicit rate converter. See `AudioGraph.swift` steps 3-5.
4. **DO NOT silently drop ring-overflow samples** — fire `.ringOverflow` rebuild trigger (Pitfall #4). `RingBuffer.overflowDetected` is the signal.
5. **DO NOT hardcode 16 kHz or 24 kHz** — always probe via `inputNode.outputFormat(forBus: 0)` post-VPIO (Assumption A7). See `InputFormatProbe.probe`.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Global `_probeOverride` caused concurrent test races**
- **Found during:** Task 1 RED phase — `InputFormatProbeTests` raced when run concurrently with `VpioOrderingTests`
- **Issue:** `InputFormatProbe._probeOverride` is a global mutable test seam; parallel Swift Testing suites overwrote each other's overrides
- **Fix:** Added `probeFormat(_ inputNode:)` method to `GraphBuilder` protocol with a default implementation that calls `InputFormatProbe.probe`. Tests inject their desired format through the builder rather than the global. `_probeOverride` is retained for the `InputFormatProbeTests` which test the probe itself (serialized suite).
- **Files modified:** `AudioGraph.swift`, `VpioOrderingTests.swift`, `AECFallbackTests.swift`

**2. [Rule 1 - Bug] `AlwaysFailingBuilder` couldn't reach `bothVariantsFailed` path**
- **Found during:** Task 2 A2 test — `open()` succeeded on the `aec=false` fallback despite intent
- **Issue:** `AudioGraph.init` calls `engine.start()` directly (not through `GraphBuilder`); no way to make it fail from a builder stub
- **Fix:** Added `startEngine(_ engine: AVAudioEngine) throws` to `GraphBuilder` with a default that calls `engine.start()`. `AlwaysFailingBuilder` overrides it to throw `MockVPIOError.engineFailed`.
- **Files modified:** `AudioGraph.swift`, `AECFallbackTests.swift`

**3. [Rule 1 - Bug] `removeAllTaps()` crash when mixer not attached (test scenario)**
- **Found during:** Task 3 T1 test — SIGABRT `required condition is false: NULL != engine`
- **Issue:** Test builders use no-op `attach` so mixer is never attached; `removeTap(onBus:0)` crashes on unattached node
- **Fix:** Added `guard mixer.engine != nil else { return }` to `AudioGraph.removeAllTaps()`
- **Files modified:** `AudioGraph.swift`

**4. [Rule 1 - Bug] `TeardownRecorder` async calls recorded out of order**
- **Found during:** Task 3 T5 ordering test — steps 4 and 5 appeared swapped
- **Issue:** Graph hooks (`_stopHook` etc.) were `() -> Void` but spawned `Task { await recorder.record(...) }` which deferred async actor calls out of the call sequence
- **Fix:** Changed `TeardownRecorder` from `actor` to `final class` with `NSLock` for synchronous recording; graph hooks call `recorder.record()` directly without wrapping in `Task`
- **Files modified:** `TeardownTests.swift`

**5. [Rule 1 - Bug] `AVAudioEngine.configurationChangeNotification` does not exist on macOS**
- **Found during:** Task 2 build — `type 'AVAudioEngine' has no member 'configurationChangeNotification'`
- **Issue:** The macOS SDK exposes this as `AVAudioEngineConfigurationChangeNotification` (raw Obj-C string), not as a Swift static member
- **Fix:** Used `Notification.Name("AVAudioEngineConfigurationChange")` raw string
- **Files modified:** `AudioGraphOwner.swift`

## Known Stubs

None. No data flows through stubs to UI. The `cancelInFlight` and `releaseORTSessions` closure slots are intentional `nil` placeholders documented in the plan — Plans 06-02 and 06-04 wire them.

## Threat Surface Scan

No new network endpoints, auth paths, file access patterns, or schema changes introduced. This plan is purely in-process audio pipeline plumbing with no external surface.

## Self-Check: PASSED

All 16 created files present on disk.

Commits (oldest → newest):
- `68fb0d9`: `test(06-01): add failing tests for AudioGraph primitives`
- `64e2fdb`: `feat(06-01): SPM manifest + AudioGraph primitives`
- `2de87c8`: `test(06-01): add failing tests for AudioGraph + AudioGraphOwner`
- `fe87b2b`: `feat(06-01): AudioGraph + AudioGraphOwner with VPIO ordering + AEC-off variant`
- `7c7c659`: `feat(06-01): six-step teardown x four rebuild triggers (VOICE-10)`
