---
phase: 06-voice
plan: 01
type: execute
wave: 1
depends_on: []
files_modified:
  - packages/Voice/Package.swift
  - packages/Voice/Sources/Voice/VoiceError.swift
  - packages/Voice/Sources/Voice/AudioGraph/AudioGraph.swift
  - packages/Voice/Sources/Voice/AudioGraph/AudioGraphVariant.swift
  - packages/Voice/Sources/Voice/AudioGraph/InputFormatProbe.swift
  - packages/Voice/Sources/Voice/AudioGraph/RingBuffer.swift
  - packages/Voice/Sources/Voice/AudioGraph/RebuildTrigger.swift
  - packages/Voice/Sources/Voice/AudioGraph/AudioGraphOwner.swift
  - packages/Voice/Sources/Voice/AudioGraph/AudioGraphError.swift
  - packages/Voice/Sources/Voice/AudioGraph/DegradationReason.swift
  - packages/Voice/Tests/VoiceTests/VpioOrderingTests.swift
  - packages/Voice/Tests/VoiceTests/InputFormatProbeTests.swift
  - packages/Voice/Tests/VoiceTests/RingBufferTests.swift
  - packages/Voice/Tests/VoiceTests/TeardownTests.swift
  - packages/Voice/Tests/VoiceTests/AECFallbackTests.swift
autonomous: true
requirements: [VOICE-08, VOICE-09, VOICE-10]
tags: [voice, audio-graph, avaudioengine, vpio, aec-fallback, teardown, ring-buffer, foundation]
assumptions:
  - Swift toolchain on the build host is >= 6.1 (matches Phase 5 SPM tree). The Voice package declares `swift-tools-version: 6.0` to align with sibling packages.
  - This plan is the SPM foundation for Phase 6; it pins ALL three external deps (`onnxruntime-swift-package-manager` ~> 1.24.2, `argmax-oss-swift` ~> 0.18.0, `mlx-audio-swift` ~> 0.1.2) so Plans 06-02..06-05 only touch source files (avoids `Package.swift` write conflicts in parallel waves).
  - The dep declarations carry no source imports yet — those land in 06-02..06-04. Resolution at `swift package resolve` time MUST succeed in this plan's CI gate.
  - `AVAudioEngine.configurationChangeNotification` is the canonical device-change signal on macOS 26 Tahoe (Assumption A7 in 06-RESEARCH).
  - `AVCaptureDevice.authorizationStatus(for: .audio)` polled at 2 s cadence is a reliable mic-re-grant detector when KVO is unavailable (Pitfall #5 in 06-RESEARCH).
  - The 16 kHz Float32 mono target format for downstream consumers (wake-word + Silero) is fixed by VOICE-01/02 contracts — input format MUST be coerced to it via `AVAudioMixerNode` (channel coerce) + `AVAudioConverter` (rate convert) in that order (Pitfall #3 / R4-D4).
  - Anti-pattern callouts: DO NOT flip `isVoiceProcessingEnabled` after any `connect`/`installTap` (silent no-op on Tahoe, crash on Sonoma — Pitfall #7). DO NOT treat AEC-off as a runtime config toggle — it's a distinct graph build (VOICE-09). DO NOT rate-convert before channel-coerce (Pitfall #3). DO NOT silently drop ring-overflow samples — fire `.ringOverflow` rebuild trigger (Pitfall #4). DO NOT hardcode 16 kHz or 24 kHz — always probe (`inputNode.outputFormat(forBus: 0)` post-VPIO).
must_haves:
  truths:
    - "An `AudioGraphOwner` actor builds an `AVAudioEngine`-backed graph with `isVoiceProcessingEnabled = true` set BEFORE any `connect` or `installTap`, and a unit test throws if the ordering is reversed."
    - "Post-VPIO input format is probed at runtime via `inputNode.outputFormat(forBus: 0)` and never hardcoded; the probe handles both 24 kHz Tahoe and 16 kHz Sonoma payloads."
    - "Tap output is coerced to 16 kHz Float32 mono via channel-mix-then-rate-convert (NOT rate-convert-then-mix); a unit test feeds a 24 kHz stereo input and asserts the tap delivers 16 kHz mono."
    - "AEC-off is a distinct graph build: when `setVoiceProcessingEnabled(true)` throws, the owner rebuilds with `aec: false` and emits `.degradedMode(reason: .aecUnavailable)` so the HUD banner can render."
    - "The canonical six-step teardown sequence (cancel in-flight → stop engine → remove taps → release rings → release ORT-session hook → emit `.reconfiguring`) runs uniformly for all four `RebuildTrigger` cases and a unit test exercises each."
    - "An SPSC `RingBuffer` with sustained-overflow detection (>500 ms consumer lag) fires `.ringOverflow` rebuild trigger; the lag threshold is configurable via the `RingBuffer` initializer."
    - "`Package.swift` declares ORT, argmax-oss-swift, and mlx-audio-swift dependencies so Plans 06-02..06-04 can `import` them without re-touching the manifest."
  artifacts:
    - path: "packages/Voice/Package.swift"
      provides: "SPM manifest for the Voice package; pins all three external deps; library product `Voice` + test target `VoiceTests`."
      contains: ".package(url: \"https://github.com/microsoft/onnxruntime-swift-package-manager\""
    - path: "packages/Voice/Sources/Voice/AudioGraph/AudioGraph.swift"
      provides: "Concrete graph wrapper around `AVAudioEngine`; exposes `format`, `variant`, `start()`, `stop()`, `removeAllTaps()`, `releaseRings()`."
      min_lines: 80
    - path: "packages/Voice/Sources/Voice/AudioGraph/AudioGraphVariant.swift"
      provides: "Two-case enum `aecOn(AVAudioFormat)` / `aecOff(AVAudioFormat)` — distinct graph variants per VOICE-09."
      min_lines: 12
    - path: "packages/Voice/Sources/Voice/AudioGraph/InputFormatProbe.swift"
      provides: "Static helper `probe(inputNode:) -> AVAudioFormat` calling `outputFormat(forBus: 0)` — single source of truth for the probe contract."
      min_lines: 20
    - path: "packages/Voice/Sources/Voice/AudioGraph/RingBuffer.swift"
      provides: "Lock-free SPSC ring buffer with `write`, `read`, `consumerLagMs`, `overflowDetected` (>500 ms sustained) primitives."
      min_lines: 80
    - path: "packages/Voice/Sources/Voice/AudioGraph/RebuildTrigger.swift"
      provides: "Four-case trigger enum: `.deviceChange`, `.aecFallback`, `.micRegrant`, `.ringOverflow` (VOICE-10)."
      min_lines: 12
    - path: "packages/Voice/Sources/Voice/AudioGraph/AudioGraphOwner.swift"
      provides: "Actor that owns the live `AudioGraph`; exposes `open()`, `rebuild(trigger:)`, `currentVariant`. Implements canonical six-step teardown."
      min_lines: 120
    - path: "packages/Voice/Sources/Voice/AudioGraph/AudioGraphError.swift"
      provides: "Error enum: `.vpioNotEnabled`, `.formatProbeFailed(underlying:)`, `.aecUnavailable(underlying:)`, `.engineStartFailed(underlying:)`, `.bothVariantsFailed`."
    - path: "packages/Voice/Sources/Voice/AudioGraph/DegradationReason.swift"
      provides: "Reason enum surfaced via `AudioGraphOwner.degradationStream`; `case aecUnavailable` is the only case in P6."
  key_links:
    - from: "packages/Voice/Sources/Voice/AudioGraph/AudioGraphOwner.swift"
      to: "AudioGraphVariant.aecOff"
      via: "fallback path on `setVoiceProcessingEnabled(true)` throw"
      pattern: "case \\.aecOff"
    - from: "packages/Voice/Sources/Voice/AudioGraph/AudioGraph.swift"
      to: "InputFormatProbe.probe"
      via: "called BEFORE installTap, AFTER setVoiceProcessingEnabled"
      pattern: "InputFormatProbe\\.probe"
    - from: "packages/Voice/Sources/Voice/AudioGraph/AudioGraphOwner.swift"
      to: "RebuildTrigger"
      via: "single rebuild path serving all four trigger cases"
      pattern: "func rebuild\\(trigger:"
---

<objective>
Land the audio-pipeline foundation that every other Phase 6 plan stands on. Three locked invariants:

1. **VOICE-08 — VPIO ordering + format probe.** `AVAudioEngine.isVoiceProcessingEnabled = true` is called BEFORE any `connect` / `installTap` on the input node. A unit test throws if the ordering is reversed (`AudioGraphError.vpioNotEnabled`). The post-AEC format is probed at runtime — never hardcoded — handling Tahoe's 24 kHz and Sonoma's 16 kHz uniformly. Channel coerce happens BEFORE rate convert (R4-D4 / Pitfall #3).
2. **VOICE-09 — AEC-off as distinct graph variant.** AEC-off is NOT a runtime toggle. On VPIO failure (`setVoiceProcessingEnabled(true)` throws), the owner tears down the partial graph and rebuilds with `aec: false`. A `.degradedMode(reason: .aecUnavailable)` event flows on the owner's `degradationStream` so Plan 06-05 can wire the HUD banner ("AEC unavailable; degraded-mode active").
3. **VOICE-10 — Canonical six-step teardown × four triggers.** One teardown sequence: (1) cancel in-flight callbacks, (2) `engine.stop()`, (3) `removeAllTaps()`, (4) release ring buffers, (5) release ORT-session hook (no-op slot until 06-02/03), (6) emit `.reconfiguring`. Four triggers route through it: `.deviceChange`, `.aecFallback`, `.micRegrant`, `.ringOverflow`. Unit tests exercise all four.

This plan is plumbing — no wake word, no VAD, no STT, no TTS. It exists so Plans 06-02..06-05 can `import Voice` and read clean 16 kHz Float32 mono frames out of a `RingBuffer` without re-implementing the AEC/format/teardown logic.

Output: a new SPM package at `packages/Voice/` with the AudioGraph subsystem, an error enum, a degradation reason enum, an XCTest target with five test files, and a fully-resolved `Package.swift` declaring all Phase 6 external deps so downstream plans don't touch it.
</objective>

<execution_context>
@~/.claude/get-shit-done/workflows/execute-plan.md
@~/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/PROJECT.md
@.planning/ROADMAP.md
@.planning/STATE.md
@.planning/phases/06-voice/06-RESEARCH.md
@.planning/research/RESEARCH-DELTAS.md
@CLAUDE.md
@App/Jarvis.entitlements
@App/Info.plist
@App/HUD/HudStateIntent.swift
@packages/Bus/Sources/Bus/Protocol.swift
@packages/Bus/Sources/Bus/BusOutbound.swift

<interfaces>
<!--
  Contracts the executor needs. Foundation plan — no upstream deps to mirror.
  Downstream plans (06-02..06-05) consume these names verbatim.
-->

From `AVFoundation` (macOS 26 SDK):

```swift
final class AVAudioEngine {
    var inputNode: AVAudioInputNode { get }
    func attach(_ node: AVAudioNode)
    func connect(_ node1: AVAudioNode, to node2: AVAudioNode, format: AVAudioFormat?)
    func start() throws
    func stop()
    static let configurationChangeNotification: Notification.Name
}

final class AVAudioInputNode: AVAudioIONode {
    func setVoiceProcessingEnabled(_ enabled: Bool) throws  // LOAD-BEARING ORDERING
    func outputFormat(forBus bus: AVAudioNodeBus) -> AVAudioFormat
    func installTap(onBus bus: AVAudioNodeBus,
                    bufferSize: AVAudioFrameCount,
                    format: AVAudioFormat?,
                    block: @escaping AVAudioNodeTapBlock)
    func removeTap(onBus bus: AVAudioNodeBus)
}
```

From `AVFoundation` (macOS 26 SDK):

```swift
final class AVCaptureDevice {
    static func authorizationStatus(for: AVMediaType) -> AVAuthorizationStatus
}
enum AVAuthorizationStatus { case notDetermined, restricted, denied, authorized }
```

From `Bus` package (Phase 2 — already shipped, do NOT modify here):

```swift
public enum BusOutbound: Equatable, Sendable {
    case audioLevel(rms: Float)        // Phase 6 will produce these
    // ...other cases shipped in Phase 2
}
```

This plan does NOT extend the Bus schema. The `audioLevel` case already exists from Phase 2. Plan 06-05 wires the producer.

From `App/HUD/HudStateIntent.swift` (Phase 3 — already shipped, do NOT modify here):

```swift
public enum VoiceHudIntent: Sendable, Equatable {
    case silent
    case listening
    case reconfiguring
}
```

Plan 06-05 emits intents into the dormant `voiceStream` continuation that `AppDelegate.dormantVoiceContinuation` already holds (per Phase 1 wiring).

New surface introduced by this plan (consumed by 06-02..06-05):

```swift
public actor AudioGraphOwner {
    public init(degradationContinuation: AsyncStream<DegradationReason>.Continuation,
                rebuildContinuation: AsyncStream<RebuildTrigger>.Continuation)
    public var currentVariant: AudioGraphVariant { get async }
    public var ringBuffer: RingBuffer { get async }     // 16 kHz Float32 mono frames
    public func open() async throws
    public func rebuild(trigger: RebuildTrigger) async
    public func shutdown() async
}

public enum AudioGraphVariant: Sendable, Equatable {
    case aecOn(AVAudioFormat)
    case aecOff(AVAudioFormat)
}

public enum RebuildTrigger: Sendable, Equatable {
    case deviceChange
    case aecFallback
    case micRegrant
    case ringOverflow
}

public enum DegradationReason: Sendable, Equatable {
    case aecUnavailable
}

public enum AudioGraphError: Error, Sendable, Equatable {
    case vpioNotEnabled
    case formatProbeFailed
    case aecUnavailable
    case engineStartFailed
    case bothVariantsFailed
}

public final class RingBuffer: @unchecked Sendable {
    public init(capacityFrames: Int, sustainedOverflowMs: Double = 500)
    public func write(_ buffer: AVAudioPCMBuffer)         // producer (tap thread)
    public func readMono16k(into: UnsafeMutableBufferPointer<Float>) -> Int  // consumer
    public var consumerLagMs: Double { get }
    public var overflowDetected: Bool { get }             // sustained > sustainedOverflowMs
}
```
</interfaces>
</context>

<tasks>

<task type="auto" tdd="true">
  <name>Task 1: SPM manifest + AudioGraph primitives (Variant / Probe / RingBuffer)</name>
  <files>packages/Voice/Package.swift, packages/Voice/Sources/Voice/AudioGraph/AudioGraphVariant.swift, packages/Voice/Sources/Voice/AudioGraph/AudioGraphError.swift, packages/Voice/Sources/Voice/AudioGraph/DegradationReason.swift, packages/Voice/Sources/Voice/AudioGraph/RebuildTrigger.swift, packages/Voice/Sources/Voice/AudioGraph/InputFormatProbe.swift, packages/Voice/Sources/Voice/AudioGraph/RingBuffer.swift, packages/Voice/Sources/Voice/VoiceError.swift, packages/Voice/Tests/VoiceTests/InputFormatProbeTests.swift, packages/Voice/Tests/VoiceTests/RingBufferTests.swift</files>
  <behavior>
    - InputFormatProbeTests: feeding a 24 kHz stereo `AVAudioFormat` returns it unchanged from `probe(...)` (probe is a pure pass-through with logging — VOICE-08 contract: "probe, never assume"); a 16 kHz mono format also returns unchanged.
    - RingBufferTests R1: write 480 frames of 16 kHz Float32 mono, read 480 frames into a target buffer — sample bytes round-trip identical.
    - RingBufferTests R2: writer fills capacity, reader stalls 600 ms (simulated via test clock); `overflowDetected == true` after 500 ms sustained lag, `false` for 400 ms.
    - RingBufferTests R3: `consumerLagMs` is monotonic when writer outpaces reader; resets to zero when reader catches up.
    - RingBufferTests R4: concurrent producer/consumer Tasks for 1 s with no contention, no dropped frames, no data race (TSan clean).
    - AudioGraphVariant: round-trip `Equatable` between `.aecOn(fmt)` and `.aecOff(fmt)` differing only by tag — equal-format-different-variant is NOT equal.
    - AudioGraphError / DegradationReason / RebuildTrigger: `Equatable` smoke (one assertion per case to lock the surface).
  </behavior>
  <action>
Create `packages/Voice/Package.swift` declaring `swift-tools-version: 6.0`, library product `Voice`, and three external deps:
  - `https://github.com/microsoft/onnxruntime-swift-package-manager` from `1.24.2`
  - `https://github.com/argmaxinc/argmax-oss-swift.git` from `0.18.0`
  - `https://github.com/Blaizzy/mlx-audio-swift.git` from `0.1.2`

The `Voice` target depends on NONE of them at this plan — they are pinned in the manifest so `Package.swift` is closed for downstream plans. The test target depends only on `Voice`.

Implement the seven primitive types (Variant / Error / DegradationReason / RebuildTrigger / InputFormatProbe / RingBuffer / VoiceError). Per `<behavior>`, write the test files first (RED), then implement.

`RingBuffer` is a single-producer / single-consumer lock-free ring with these semantics:
- Producer: tap thread calls `write(AVAudioPCMBuffer)`. Implementation reads `pcmBuffer.floatChannelData`, computes mono mix if channelCount > 1, atomically advances writeIdx.
- Consumer: caller asks for N frames; we copy from readIdx → readIdx+N (with wrap).
- Lag tracking: `consumerLagMs` = `(writeIdx - readIdx) / 16000 * 1000` (frames are 16 kHz mono, fixed downstream contract — comment this anchor).
- Overflow: `overflowDetected` returns `true` once `consumerLagMs > sustainedOverflowMs` for ≥ 500 ms continuously (track with a "first observed lag at" timestamp; reset to nil when lag drops below threshold). Default `sustainedOverflowMs: 500` per Pitfall #4.

`InputFormatProbe.probe(inputNode:)` is a one-line wrapper around `inputNode.outputFormat(forBus: 0)` plus a log line. The wrapper exists so VPIO-ordering tests can stub it without a live AVAudioEngine; a `static var probeOverride: ((AVAudioInputNode) -> AVAudioFormat)?` test seam is acceptable IF it's `internal` and named `_probeOverride` to discourage production use.

Verify: `swift package resolve` succeeds; all three external deps download; tests pass. The library product compiles even with no `AudioGraph.swift` yet (created in Task 2).
  </action>
  <verify>
    <automated>swift test --package-path packages/Voice --filter VoiceTests.RingBufferTests &amp;&amp; swift test --package-path packages/Voice --filter VoiceTests.InputFormatProbeTests &amp;&amp; swift package --package-path packages/Voice resolve</automated>
  </verify>
  <done>Package.swift resolves with all three deps pinned. RingBufferTests (4 cases) and InputFormatProbeTests (2 cases) pass. Variant/Error/Reason/Trigger smoke tests pass. `swift build --package-path packages/Voice` clean.</done>
</task>

<task type="auto" tdd="true">
  <name>Task 2: AudioGraph + AudioGraphOwner with VPIO ordering + AEC-off variant</name>
  <files>packages/Voice/Sources/Voice/AudioGraph/AudioGraph.swift, packages/Voice/Sources/Voice/AudioGraph/AudioGraphOwner.swift, packages/Voice/Tests/VoiceTests/VpioOrderingTests.swift, packages/Voice/Tests/VoiceTests/AECFallbackTests.swift</files>
  <behavior>
    - VpioOrderingTests V1: a wrapper helper `AudioGraphGuard.installTap(on:engine:)` that throws `AudioGraphError.vpioNotEnabled` when called on an `AVAudioInputNode` whose VPIO flag is `false`. Exercise via a real `AVAudioEngine` instance — the test inspects an internal flag on `AudioGraph` rather than relying on AVFoundation private state.
    - VpioOrderingTests V2: building a graph with `aec: true` calls `setVoiceProcessingEnabled(true)` BEFORE the first `attach`/`connect`/`installTap`. Use a record-of-calls test helper (closure injection on `AudioGraph.init`) to assert order: VPIO flip is call #1, attach #2, connect #3, installTap #4.
    - VpioOrderingTests V3: building with `aec: false` does NOT flip VPIO; the call sequence skips that step and the resulting `AudioGraph.variant` is `.aecOff(format)`.
    - AECFallbackTests A1: when the test injects a `setVoiceProcessingEnabled(true)` failure (closure throws `MockError.vpioRefused`), `AudioGraphOwner.open()` rebuilds with `aec: false`, emits exactly one `DegradationReason.aecUnavailable` on `degradationStream`, and `currentVariant == .aecOff(...)`.
    - AECFallbackTests A2: when BOTH variants fail, `AudioGraphOwner.open()` throws `AudioGraphError.bothVariantsFailed`. No degradationStream events emitted on this terminal path.
    - AECFallbackTests A3: a successful `aec: true` build emits ZERO `DegradationReason` events.
  </behavior>
  <action>
Implement `AudioGraph.swift` as a non-actor wrapper struct/class around an `AVAudioEngine`. Constructor is `init(aec: Bool, builder: GraphBuilder = .live) throws` where `GraphBuilder` is a protocol with the four steps as methods (`flipVPIO(_:) throws`, `attach(_:_:)`, `connect(_:to:format:)`, `installTap(...)`) — this protocol IS the test seam.

Implementation order inside `AudioGraph.init` MUST be exactly:
  1. `if aec { try builder.flipVPIO(engine.inputNode) }`
  2. Probe format via `InputFormatProbe.probe(inputNode: engine.inputNode)`.
  3. `attach` mixer node + `connect(inputNode → mixer, format: probedFormat)`.
  4. Compute target format `AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)` — the SINGLE source of truth for downstream consumers (locked by VOICE-01/02 contracts).
  5. `mixer.installTap(onBus: 0, bufferSize: 1024, format: targetFmt) { [ringBuffer] buffer, _ in ringBuffer.write(buffer) }`.
  6. `engine.start()`.

Channel coerce (mixer) precedes rate convert (handled implicitly by `installTap`'s format-conversion path; AVAudioEngine inserts an internal converter when the tap format differs from the connection format). Comment R4-D4 / Pitfall #3 inline.

`AudioGraphOwner` is an actor. `open()`:
  1. `do { graph = try AudioGraph(aec: true) }`
  2. `catch { logger.warning(...); degradationCont.yield(.aecUnavailable); do { graph = try AudioGraph(aec: false) } catch { throw .bothVariantsFailed } }`

Note the deliberate ordering: `.aecUnavailable` is yielded BEFORE the AEC-off rebuild attempt. If that rebuild ALSO fails, the owner throws — but the degradation event has already been emitted. Plan 06-05 will treat the persistent banner as compatible with a hard-failure error log.

Verify: `swift test --package-path packages/Voice` passes; `swift build --package-path packages/Voice` clean.
  </action>
  <verify>
    <automated>swift test --package-path packages/Voice --filter VoiceTests.VpioOrderingTests &amp;&amp; swift test --package-path packages/Voice --filter VoiceTests.AECFallbackTests</automated>
  </verify>
  <done>VpioOrderingTests (3 cases) + AECFallbackTests (3 cases) pass. `AudioGraph.swift` ≥ 80 lines with the documented step ordering and inline R4-D4 comment. `AudioGraphOwner.swift` exposes `open()` / `currentVariant` / `degradationStream` / `rebuildStream`.</done>
</task>

<task type="auto" tdd="true">
  <name>Task 3: Six-step teardown × four rebuild triggers</name>
  <files>packages/Voice/Sources/Voice/AudioGraph/AudioGraphOwner.swift, packages/Voice/Tests/VoiceTests/TeardownTests.swift</files>
  <behavior>
    - TeardownTests T1 (deviceChange): after `open()`, simulate `AVAudioEngine.configurationChangeNotification` → owner runs all six teardown steps in order, then rebuilds. Assert: `engine.stop()` called once, `removeAllTaps()` called once, ring released (consumer reads return 0 frames mid-teardown), `.reconfiguring` event yielded ONCE on `rebuildStream`. Final variant equals `.aecOn(format)` (rebuild succeeded).
    - TeardownTests T2 (aecFallback): same as A1 but routed via `rebuild(trigger: .aecFallback)` rather than `open()` first failing — owner runs the same six steps + rebuilds with `aec: false`.
    - TeardownTests T3 (micRegrant): when `AVCaptureDevice.authorizationStatus(for: .audio)` transitions from `.denied` to `.authorized` (simulated via injected `authStatusProbe` closure), owner runs the six steps + rebuilds. PTT-armed status (Plan 06-05 concern) is not tested here — only the rebuild path.
    - TeardownTests T4 (ringOverflow): when `RingBuffer.overflowDetected == true` (write at full capacity for >500 ms with stalled reader), the overflow watcher fires `rebuild(trigger: .ringOverflow)` exactly once, runs six steps, and rebuilds. The watcher resets after rebuild.
    - TeardownTests T5 (ordering): the six teardown steps run in this exact order: cancel-in-flight closure called → `engine.stop()` → `removeAllTaps()` → `releaseRings()` → `releaseORTSessions` closure called → `.reconfiguring` event yielded. Use a recorder to assert.
  </behavior>
  <action>
Extend `AudioGraphOwner` with the canonical teardown sequence per VOICE-10:

```
private func teardown() async {
  await cancelInFlight?()                               // (1)
  graph?.stop()                                         // (2)
  graph?.removeAllTaps()                                // (3)
  graph?.releaseRings()                                 // (4)
  await releaseORTSessions?()                           // (5) — closure slot, no-op stub
  rebuildCont.yield(.reconfiguring(reason: trigger))    // (6) — actually emits to rebuildStream
}
```

`cancelInFlight` and `releaseORTSessions` are `(@Sendable () async -> Void)?` slots — empty in this plan, populated by Plan 06-02 (wake-word DAG cancellation) and Plan 06-04 (TTS producer cancellation). The slots exist so the teardown contract is closed at this plan and downstream wiring is additive only.

`rebuild(trigger:)`:
```
public func rebuild(trigger: RebuildTrigger) async {
  await teardown()
  do { graph = try AudioGraph(aec: lastVariantWantedAec) }
  catch { /* same fallback as open(): try aec:false; emit degradation if needed */ }
}
```

Watchers:
- `configurationChangeNotification`: `Task { for await _ in NotificationCenter.default.notifications(named: .configurationChange).map(\.name) { await rebuild(trigger: .deviceChange) } }`. Spawn from `open()`.
- `micRegrantWatcher`: a 2-second polling Task that observes `AVCaptureDevice.authorizationStatus(for: .audio)` and fires `rebuild(trigger: .micRegrant)` on `.denied → .authorized` transition.
- `overflowWatcher`: a 250-ms polling Task observing `ringBuffer.overflowDetected`; fires `rebuild(trigger: .ringOverflow)`. The watcher pauses during teardown (a `inTeardown` flag) so it doesn't fire spuriously on a torn-down ring.

All three watchers are owned `Task<Void, Never>?` slots cancelled in `shutdown()`.

Test seams: inject the configurationChangeNotification source, the auth-status probe closure, and the clock used by the overflow watcher so unit tests are deterministic. Test mocks live in `Tests/VoiceTests/AudioGraphTestSupport.swift`.

Verify: `swift test --package-path packages/Voice --filter TeardownTests` passes. The teardown step ordering is verified by recorder, not just the rebuild outcome.
  </action>
  <verify>
    <automated>swift test --package-path packages/Voice --filter VoiceTests.TeardownTests</automated>
  </verify>
  <done>TeardownTests (5 cases — T1..T5) pass. Six-step ordering proven via recorder. All four rebuild triggers route through one shared teardown path (DRY: a single `func teardown()` body invoked by `rebuild`). Inline comment in `AudioGraphOwner.swift` references VOICE-10.</done>
</task>

</tasks>

<threat_model>
## Trust Boundaries

| Boundary | Description |
|----------|-------------|
| Hardware mic → AVAudioEngine VPIO | Untrusted ambient acoustic signal enters the process; VPIO sanitizes via AEC/NS/AGC. |
| AVAudioEngine tap callback → RingBuffer | Cross-thread (Core Audio thread → app thread) hand-off; SPSC semantics MUST hold or audio races corrupt downstream consumers. |
| AudioGraphOwner actor → degradationStream / rebuildStream | Internal app boundary; Plan 06-05 consumes these — no external surface. |

## STRIDE Threat Register

| Threat ID | Category | Component | Disposition | Mitigation Plan |
|-----------|----------|-----------|-------------|-----------------|
| T-06-01-01 | Tampering | AVAudioEngine VPIO ordering | mitigate | VpioOrderingTests V1/V2/V3 enforce flip-before-connect; production build calls `setVoiceProcessingEnabled(_:)` only via `AudioGraph.init` (single call site). Reverse-order attempts surface as `AudioGraphError.vpioNotEnabled` at runtime. |
| T-06-01-02 | Denial of Service | RingBuffer overflow under stalled consumer | mitigate | `RingBuffer.overflowDetected` fires after 500 ms sustained lag; `AudioGraphOwner.rebuild(trigger: .ringOverflow)` recovers via full teardown rather than silent drop (Pitfall #4). |
| T-06-01-03 | Information Disclosure | Pre-AEC raw mic frames leak via tap | mitigate | The tap is installed on the post-VPIO mixer node, not the raw input node, so only AEC-processed audio reaches the ring. AEC-off variant is a deliberate user-visible degradation (banner) — the user knows AEC is off. |
| T-06-01-04 | Denial of Service | Mic re-grant loop (denied↔authorized flapping) | accept | Polling at 2 s cadence amortizes; a single rebuild per transition. If a hostile process flaps TCC, the user has bigger problems. No rate limiter in v1. |
| T-06-01-05 | Spoofing | configurationChangeNotification injection from another process | accept | macOS NotificationCenter is process-local; `.configurationChange` cannot be forged cross-process. No spoof path exists. |
| T-06-01-06 | Tampering | AEC-off graph silently activated without user notice | mitigate | `.degradedMode(reason: .aecUnavailable)` event fires on stream consumed by Plan 06-05's HUD banner. AEC-off is never user-invisible. |
| T-06-01-07 | Repudiation | Unrecorded rebuild events confuse field debugging | mitigate | Every rebuild fires `.reconfiguring(reason:)` on `rebuildStream` AND a structured log line via `JarvisLogChannel.system`. Replay-log integration is Plan 06-05's concern. |
</threat_model>

<verification>
- `swift test --package-path packages/Voice` — 14 cases (4 RingBuffer + 2 InputFormatProbe + 3 VpioOrdering + 3 AECFallback + 5 Teardown — minus a few smoke tests that may collapse under parameterized helpers; ≥12 net) green.
- `swift build --package-path packages/Voice` — clean Debug + Release.
- `swift package --package-path packages/Voice resolve` — exits 0 with all three external deps pinned.
- Grep gates:
  - `grep -nE 'isVoiceProcessingEnabled|setVoiceProcessingEnabled' packages/Voice/Sources/Voice/AudioGraph/AudioGraph.swift` — exactly 1 production call site (the flip in `init`).
  - `grep -nE 'outputFormat\\(forBus:' packages/Voice/Sources/Voice/AudioGraph/InputFormatProbe.swift | grep -v '^[[:space:]]*//' | wc -l` — exactly 1 (no probe duplication elsewhere).
  - `grep -cE 'case \\.aecOn|case \\.aecOff' packages/Voice/Sources/Voice/AudioGraph/AudioGraphVariant.swift` — exactly 2.
  - `grep -nE 'sampleRate: 16_000|sampleRate: 16000' packages/Voice/Sources/Voice/AudioGraph/AudioGraph.swift` — at least 1 (target format anchor).
- The Voice package compiles standalone with NO other Phase 6 source files in place. Plans 06-02..06-05 will add files but never touch `Package.swift`.
</verification>

<success_criteria>
- VOICE-08 closed at the unit-test level: VPIO-before-connect ordering enforced; format probed never assumed; channel-coerce-then-rate-convert ordering documented and enforced via the mixer-then-tap pipeline.
- VOICE-09 closed at the unit-test level: AEC-off is a distinct graph build with a degradation event; falling back is automatic, surfaceable, and reversible (next rebuild can attempt AEC-on again).
- VOICE-10 closed at the unit-test level: one teardown sequence, six steps, four triggers — all proven via recorder + integration assertions.
- `Package.swift` is closed for Phase 6: 06-02..06-05 do NOT modify it. Wave-2 plans can safely run in parallel because file ownership is disjoint.
- `AudioGraphOwner` exposes the actor surface the rest of Phase 6 consumes (`currentVariant`, `ringBuffer`, `degradationStream`, `rebuildStream`, `open()`, `rebuild(trigger:)`, `shutdown()`).
- Inline comments anchor R4-D4 (channel-then-rate ordering), Pitfall #3 (rate-convert order), Pitfall #4 (overflow-as-rebuild), Pitfall #7 (VPIO ordering) — so future maintainers can grep their way to the rationale.
</success_criteria>

<output>
After completion, create `.planning/phases/06-voice/06-01-SUMMARY.md` documenting:
- The seven primitive types added.
- The exact six-step teardown order (with inline pseudocode quoted verbatim).
- The two `(@Sendable () async -> Void)?` slots reserved for Plans 06-02 (wake-word) and 06-04 (TTS) cancellation.
- The Wave-2 promise: 06-02 and 06-03 only modify their own subdirectories; `Package.swift` is closed.
- Test counts (RED→GREEN cycles per task) and `swift test` summary.
</output>
