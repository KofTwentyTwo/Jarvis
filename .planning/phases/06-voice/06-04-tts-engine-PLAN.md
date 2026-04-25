---
phase: 06-voice
plan: 04
type: execute
wave: 3
depends_on: [06-01]
files_modified:
  - packages/Voice/Sources/Voice/TTS/TTSEngineActor.swift
  - packages/Voice/Sources/Voice/TTS/AVSpeechSynth.swift
  - packages/Voice/Sources/Voice/TTS/OrpheusTTS.swift
  - packages/Voice/Sources/Voice/TTS/TTSKitFallback.swift
  - packages/Voice/Sources/Voice/TTS/TTSInterrupt.swift
  - packages/Voice/Sources/Voice/TTS/AudioSink.swift
  - packages/Voice/Sources/Voice/TTS/TTSError.swift
  - packages/Voice/Sources/Voice/TTS/TTSEvent.swift
  - packages/Voice/Tests/VoiceTests/AVSpeechSmokeTests.swift
  - packages/Voice/Tests/VoiceTests/OrpheusSerializationTests.swift
  - packages/Voice/Tests/VoiceTests/OrpheusTTFATests.swift
  - packages/Voice/Tests/VoiceTests/TTSInterruptTests.swift
autonomous: true
requirements: [VOICE-05, VOICE-06, VOICE-11]
tags: [voice, tts, av-speech-synth, orpheus, mlx-audio-swift, ttskit, serial-executor, metal-deadlock, atomic-interrupt]
assumptions:
  - Plan 06-01 has shipped: Voice package + AudioGraphOwner + cancelInFlight slot.
  - Plan 06-01 declared `mlx-audio-swift` v0.1.2 + `argmax-oss-swift` v0.18.0 in `Package.swift`. We add the imports here.
  - `mlx-audio-swift v0.1.2` `LlamaTTSModel.fromPretrained("mlx-community/orpheus-3b-0.1-ft-bf16")` runs in-process on Apple Silicon (RESEARCH-DELTAS D7).
  - `LlamaTTSModel.generateStream(...)` yields events including `.token`, `.audio(Chunk)`, `.info` (RESEARCH §6). Exact event-case shape verified at impl time via Context7.
  - The Metal-buffer serialization deadlock (Pitfall #1) is real and reproducible with overlapping `generateStream` calls. The `TTSEngineActor` actor's serial executor is the enforced mitigation.
  - `argmax-oss-swift v0.18.0` `TTSKit` exposes `play(strategy: .auto)` for streaming playback; voice character differs from Orpheus (RESEARCH §6 fallback).
  - Empirical Orpheus TTFA target is 150–250 ms on the user's M-series Mac. Scaffold-time perf probe (`OrpheusTTFATests`) measures live; if measured TTFA > 250 ms, Plan 06-05 will flip `features.tts.tier2 = "ttskit"` and surface a HUD note.
  - Anti-pattern callouts: DO NOT call `AVSpeechSynthesizer` and `OrpheusTTS` from concurrent actors — TTSEngineActor's serial executor is the GUARD (Pitfall #1). DO NOT release ducking on `TTSEvent.finished` alone — only on `.ttsStopped` (Pitfall #6 / VOICE-11). DO NOT use a Python sidecar for Orpheus (CLAUDE.md voice stack hard rule). DO NOT skip the 10 ms cosine fade — clicks/pops on stop are immediate UX regressions (VOICE-11).
must_haves:
  truths:
    - "An `AVSpeechSynth` wraps `AVSpeechSynthesizer` for tier-1 short confirmations (<1 sentence); `stopSpeaking(at: .immediate)` is called BEFORE every new utterance to prevent queue buildup."
    - "An `OrpheusTTS` actor wraps `LlamaTTSModel.generateStream` for tier-2 streaming synthesis; only one synthesis runs at a time (serial executor); a unit test exercises the rapid-fire pattern that would otherwise deadlock."
    - "A `TTSEngineActor` actor with serial executor coordinates both tiers; concurrent `synthesize` calls FIFO-serialize; cancellation of an in-flight call propagates to the underlying engine within 50 ms."
    - "The TTS interrupt sequence runs atomically in 5 steps: (1) cancel producer, (2) 10 ms cosine fade-out, (3) `playerNode.stop()`, (4) await completion ≤20 ms, (5) emit `.ttsStopped` on `ttsEventStream`."
    - "Ducking lowers ONLY on `.ttsStopped` — a unit test injects a `.finished` event and asserts ducking remains UP; a follow-up `.ttsStopped` triggers ducking release."
    - "An `OrpheusTTFATests` scaffold probe measures empirical time-to-first-audio for a fixed prompt (\"Hello, this is Jarvis.\"); if measured TTFA > 250 ms, the test logs the value and emits a clear remediation note (flip to TTSKit fallback) — does NOT hard-fail."
  artifacts:
    - path: "packages/Voice/Sources/Voice/TTS/TTSEngineActor.swift"
      provides: "Public actor (default serial executor) with `synthesize(_:tier:into:) async throws`, `cancel() async`, `ttsEventStream`. Single FIFO queue across both tiers."
      min_lines: 100
    - path: "packages/Voice/Sources/Voice/TTS/AVSpeechSynth.swift"
      provides: "Tier-1 wrapper: `speak(_:voice:into:) async`. Holds AVSpeechSynthesizer as a stored property (avoids the deinit-leak gotcha — Pitfall in §5)."
      min_lines: 60
    - path: "packages/Voice/Sources/Voice/TTS/OrpheusTTS.swift"
      provides: "Tier-2 actor wrapping LlamaTTSModel; `synthesize(_:voice:into:) async throws` invokes `generateStream`; cancellation cooperative."
      min_lines: 100
    - path: "packages/Voice/Sources/Voice/TTS/TTSKitFallback.swift"
      provides: "Tier-2 fallback wrapping argmax-oss-swift TTSKit `play(strategy: .auto)`."
      min_lines: 60
    - path: "packages/Voice/Sources/Voice/TTS/TTSInterrupt.swift"
      provides: "`InterruptSequence.run(engine:sink:eventBus:) async` implements the atomic 5-step sequence."
      min_lines: 60
    - path: "packages/Voice/Sources/Voice/TTS/AudioSink.swift"
      provides: "Wrapper around `AVAudioPlayerNode` with `enqueue(_:)`, `stop()`, `cosineFadeOut(duration:)`, `awaitCompletion(timeout:)`."
      min_lines: 80
    - path: "packages/Voice/Sources/Voice/TTS/TTSEvent.swift"
      provides: "Event enum: `.started`, `.firstAudio(at:)`, `.finished` (producer done), `.ttsStopped` (sink drained)."
  key_links:
    - from: "packages/Voice/Sources/Voice/TTS/TTSEngineActor.swift"
      to: "OrpheusTTS / AVSpeechSynth"
      via: "tier dispatch on the actor's serial executor"
      pattern: "actor TTSEngineActor"
    - from: "packages/Voice/Sources/Voice/TTS/TTSInterrupt.swift"
      to: "AudioSink.cosineFadeOut + playerNode.stop"
      via: "5-step atomic sequence"
      pattern: "cosineFadeOut|playerNode\\.stop"
    - from: "packages/Voice/Sources/Voice/TTS/AudioSink.swift"
      to: "ducking-release gate"
      via: ".ttsStopped emitted from sink-drain completion handler"
      pattern: "\\.ttsStopped"
---

<objective>
Land both TTS tiers + the atomic interrupt sequence behind a single `TTSEngineActor` so synthesis is serialized (no Metal-buffer deadlock) and barge-in is atomic (no clicks, no clipped tails, no ducking-release races).

Three locked invariants:

1. **VOICE-05 — AVSpeechSynthesizer tier 1.** Free, instant, OS-provided. Used for sub-1-sentence confirmations and think-aloud while tier 2 warms. Always `stopSpeaking(at: .immediate)` before the next utterance to prevent queue buildup. Synthesizer held as a stored property (Pitfall in §5: weak/local synthesizers leak via mid-utterance deinit).
2. **VOICE-06 — Orpheus tier 2 with serial executor.** `mlx-community/orpheus-3b-0.1-ft-bf16` via `mlx-audio-swift v0.1.2` `LlamaTTSModel`. The `TTSEngineActor` is a Swift actor — its default serial executor IS the synchronization primitive against the Metal command-buffer deadlock (Pitfall #1). Test simulates rapid-fire calls and asserts FIFO ordering with no deadlock. Empirical TTFA scaffold probe targets 150–250 ms; >250 ms logs a remediation note (flip to TTSKit). TTSKit fallback (`argmax-oss-swift v0.18.0`) is wired but defaulted off.
3. **VOICE-11 — Atomic interrupt sequence.** Five steps in order: (1) cancel Orpheus producer, (2) 10 ms cosine fade-out on the audio sink, (3) `AVAudioPlayerNode.stop()`, (4) await completion handler ≤20 ms, (5) emit `.ttsStopped`. Ducking lowers ONLY on `.ttsStopped` — never on `TTSEvent.finished` alone (Pitfall #6: producer done ≠ sink empty; 100–200 ms tail can clip).

This plan does NOT do barge-in routing through `cancelAndSubmit` — that's Plan 06-05's job. This plan provides the `InterruptSequence.run(...)` primitive that 06-05 will call from inside the orchestrator's `cancelAndSubmit` path.

Output: a complete TTS subsystem with `TTSEngineActor`, both tier wrappers, the atomic interrupt sequence, and four RED→GREEN test files including the scaffold-time TTFA perf probe.
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
@.planning/phases/06-voice/06-01-SUMMARY.md
@.planning/research/RESEARCH-DELTAS.md
@CLAUDE.md
@packages/Voice/Package.swift
@packages/Voice/Sources/Voice/AudioGraph/AudioGraphOwner.swift

<interfaces>
<!--
  Contracts the executor needs verbatim. The exact mlx-audio-swift / TTSKit
  surface MUST be confirmed via Context7 at impl time — what's below is the
  RESEARCH-derived best-known shape.
-->

From `mlx-audio-swift` v0.1.2 (RESEARCH-derived; verify at impl):

```swift
import MLXAudio

public final class LlamaTTSModel {
    public static func fromPretrained(_ name: String) async throws -> LlamaTTSModel
    public func generateStream(_ text: String, voice: String) -> AsyncThrowingStream<GenerateEvent, Error>
}

public enum GenerateEvent: Sendable {
    case token(Token)
    case audio(AudioChunk)   // PCM samples ready for playback
    case info(InfoMessage)
}

public struct AudioChunk: Sendable {
    public let samples: [Float]
    public let sampleRate: Int    // Orpheus emits 24 kHz mono per RESEARCH-DELTAS
}
```

If `LlamaTTSModel.generateStream` is not a public surface in v0.1.2, the executor MUST consult Context7 (`mcp__context7__resolve-library-id` for `Blaizzy/mlx-audio-swift`) and adapt — the test seam pattern (`init(modelFactory:)`) makes the production type swappable.

From `argmax-oss-swift` v0.18.0 (target: `TTSKit`):

```swift
import TTSKit

public final class TTSKit {
    public init(modelName: String) async throws
    public func play(_ text: String, strategy: PlaybackStrategy = .auto) async throws
}
public enum PlaybackStrategy { case auto, chunked, full }
```

From `AVFoundation` (macOS 26):

```swift
public final class AVSpeechSynthesizer {
    public init()
    public func speak(_ utterance: AVSpeechUtterance)
    public func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool
    public weak var delegate: AVSpeechSynthesizerDelegate?
}

public final class AVAudioPlayerNode: AVAudioNode {
    public func scheduleBuffer(_ buffer: AVAudioPCMBuffer, completionHandler: AVAudioNodeCompletionHandler? = nil)
    public func play()
    public func stop()
}
```

From Plan 06-01 (already shipped):

```swift
public actor AudioGraphOwner {
    public func setCancelInFlight(_ closure: @escaping @Sendable () async -> Void)
}
```

New surface introduced by this plan:

```swift
public enum TTSTier: Sendable, Equatable { case tier1, tier2 }

public enum TTSEvent: Sendable, Equatable {
    case started
    case firstAudio(at: Date)   // emitted on first .audio chunk — used for TTFA measurement
    case finished               // producer done
    case ttsStopped             // sink drained — THIS is the ducking-release gate
}

public actor TTSEngineActor {
    public init(orpheus: OrpheusTTS, tier1: AVSpeechSynth, fallback: TTSKitFallback?)
    public nonisolated var ttsEventStream: AsyncStream<TTSEvent> { get }
    public func synthesize(_ text: String, tier: TTSTier, voice: String) async throws
    public func cancel() async
}

public actor OrpheusTTS {
    public init(modelName: String = "mlx-community/orpheus-3b-0.1-ft-bf16") async throws
    public func synthesize(_ text: String, voice: String, into sink: AudioSink) async throws
    public func cancel() async
}

public final class AVSpeechSynth: @unchecked Sendable {
    public init()
    public func speak(_ text: String, voice: AVSpeechSynthesisVoice?) async
    public func stop()
}

public actor TTSKitFallback {
    public init(modelName: String) async throws
    public func synthesize(_ text: String, into sink: AudioSink) async throws
    public func cancel() async
}

public final class AudioSink: @unchecked Sendable {
    public init(playerNode: AVAudioPlayerNode, format: AVAudioFormat)
    public func enqueue(_ chunk: AudioChunk) async
    public func cosineFadeOut(duration: Duration) async
    public func stop()
    public func awaitCompletion(timeout: Duration) async
}

public enum InterruptSequence {
    public static func run(engine: TTSEngineActor,
                           sink: AudioSink,
                           eventBus: AsyncStream<TTSEvent>.Continuation) async
}

public enum TTSError: Error, Sendable {
    case modelLoadFailed(underlying: Error)
    case synthesisFailed(underlying: Error)
    case cancelled
    case sinkUnavailable
}
```
</interfaces>
</context>

<tasks>

<task type="auto" tdd="true">
  <name>Task 1: AVSpeechSynth (tier 1) + AudioSink + TTSEvent surface</name>
  <files>packages/Voice/Sources/Voice/TTS/AVSpeechSynth.swift, packages/Voice/Sources/Voice/TTS/AudioSink.swift, packages/Voice/Sources/Voice/TTS/TTSEvent.swift, packages/Voice/Sources/Voice/TTS/TTSError.swift, packages/Voice/Tests/VoiceTests/AVSpeechSmokeTests.swift</files>
  <behavior>
    - AVSpeechSmokeTests A1: speaking "OK" with default voice resolves the `speak(...)` async call within 2 seconds. The synthesizer property is HELD across utterances (not re-created — Pitfall in §5).
    - AVSpeechSmokeTests A2: rapid-fire `speak("first"); speak("second")` calls — the implementation calls `stopSpeaking(at: .immediate)` BEFORE each speak, so "first" is interrupted by "second". Verify via a test delegate that records `didStart`/`didCancel`/`didFinish` events.
    - AVSpeechSmokeTests A3 (AudioSink): enqueue a 100 ms PCM buffer, call `awaitCompletion(timeout: .seconds(1))` — completes within ~150 ms. The completion handler fires AFTER the buffer drains (not at enqueue time).
    - AVSpeechSmokeTests A4 (cosine fade): a 1-second buffer of constant amplitude 0.5 → after `cosineFadeOut(duration: .milliseconds(10))` is called at the 500 ms mark, samples 5000-5160 (10 ms @ 16 kHz) decay smoothly from 0.5 to 0; subsequent samples are 0.
  </behavior>
  <action>
Replace the placeholder `AVSpeechSmokeTests.swift` from Plan 06-03 with real tests per `<behavior>`.

Implement `TTSEvent.swift` and `TTSError.swift` per `<interfaces>`.

Implement `AVSpeechSynth.swift`:
- `private let synth = AVSpeechSynthesizer()` — STORED PROPERTY (Pitfall §5).
- `private let delegate: SpeechSynthDelegate` — also stored, owns the AVSpeechSynthesizerDelegate-conforming object so it isn't deallocated mid-utterance.
- `func speak(_ text: String, voice: AVSpeechSynthesisVoice?) async`: calls `synth.stopSpeaking(at: .immediate)` BEFORE creating + queueing a new `AVSpeechUtterance`. Awaits completion via continuation hooked to the delegate's `didFinish`/`didCancel`.
- `func stop()`: synchronous `synth.stopSpeaking(at: .immediate)`.

Implement `AudioSink.swift`:
- Owns an `AVAudioPlayerNode` (caller-supplied) + format.
- `enqueue(_ chunk:)`: builds an `AVAudioPCMBuffer` from `[Float]` samples, calls `playerNode.scheduleBuffer(...)` with a completion handler that yields `.ttsStopped` IF this was the LAST buffer (test for `playerNode.isPlaying == false` post-completion).
- `cosineFadeOut(duration:)`: schedules a synthetic fade buffer of the requested duration containing samples that follow `cos(πt / 2duration)` from amplitude=1 to amplitude=0; this fade buffer is enqueued in front of any pending audio. NOTE: the executor MUST verify whether AVAudioPlayerNode supports inline buffer-mutation; if not, the fade-out must apply to a NEW buffer that's prepended to the queue. Either way, the fade is real audio, not a `volume` ramp on the node.
- `awaitCompletion(timeout:)`: uses `withCheckedContinuation` + `playerNode.lastRenderTime` polling at 5 ms granularity; falls back to timeout if the node doesn't drain within `timeout`.
- `stop()`: synchronous `playerNode.stop()`.

Implement `TTSError.swift` per `<interfaces>`.

Verify: A1..A4 pass.
  </action>
  <verify>
    <automated>swift test --package-path packages/Voice --filter VoiceTests.AVSpeechSmokeTests</automated>
  </verify>
  <done>AVSpeechSmokeTests (4 cases — A1..A4) pass. `AVSpeechSynth.swift` ≥ 60 lines with stored-property + stored-delegate guards. `AudioSink.swift` ≥ 80 lines with cosine-fade math anchored inline. The cosine-fade test asserts smooth decay (not just final-amplitude=0).</done>
</task>

<task type="auto" tdd="true">
  <name>Task 2: OrpheusTTS + serial-executor TTSEngineActor + rapid-fire deadlock test</name>
  <files>packages/Voice/Sources/Voice/TTS/OrpheusTTS.swift, packages/Voice/Sources/Voice/TTS/TTSEngineActor.swift, packages/Voice/Sources/Voice/TTS/TTSKitFallback.swift, packages/Voice/Tests/VoiceTests/OrpheusSerializationTests.swift, packages/Voice/Tests/VoiceTests/OrpheusTTFATests.swift</files>
  <behavior>
    - OrpheusSerializationTests O1 (FIFO ordering): submit `synthesize("first"); synthesize("second"); synthesize("third")` from three concurrent Tasks; assert audio samples reach the sink in the order first→second→third (test seam: scripted `LlamaTTSModel` emits a per-call sentinel sample value).
    - OrpheusSerializationTests O2 (no deadlock under rapid fire): 10 concurrent `synthesize` calls all complete within 30 seconds (would deadlock indefinitely without the serial executor — Pitfall #1).
    - OrpheusSerializationTests O3 (cancellation propagates): start a synthesis, call `engine.cancel()` 100 ms in; the in-flight Task throws `CancellationError`; subsequent `synthesize` calls work normally (no stuck state).
    - OrpheusTTFATests T1 (scaffold perf probe): with a real Orpheus model loaded, measure time from `synthesize("Hello, this is Jarvis.")` start to first `.firstAudio(at:)` event. Log the measured value. If > 250 ms, log a clear remediation note recommending `features.tts.tier2 = "ttskit"`. Does NOT hard-fail the test — this is a measurement, not a gate.
    - OrpheusTTFATests T2 (TTSKit fallback functional): with a real TTSKit model loaded, `synthesize("Hello.")` produces audio and completes. Smoke-only, not a perf probe.

      Note: Both T1 and T2 require real model weights and Apple Silicon; gated by `#if !TEST_SKIP_REAL_MODELS` and skipped in CI containers via an environment variable.
  </behavior>
  <action>
Implement `OrpheusTTS.swift` as an actor:
- `private let model: LlamaTTSModel` — stored after `fromPretrained`.
- Internal `init(model: LlamaTTSModel)` test seam.
- `synthesize(_ text: String, voice: String, into sink: AudioSink) async throws`:
  ```swift
  for try await event in model.generateStream(text, voice: voice) {
    try Task.checkCancellation()
    switch event {
    case .audio(let chunk): await sink.enqueue(chunk)
    case .token, .info: break
    }
  }
  ```
- `cancel()` cancels the current Task. Implementation note: actor isolation makes "current Task" tractable — store the running Task as `private var currentTask: Task<Void, Error>?` and cancel it.

Implement `TTSEngineActor.swift`:
- Public actor; the actor's default serial executor IS the Pitfall #1 mitigation.
- `synthesize(_ text: String, tier: TTSTier, voice: String) async throws`:
  - Cancel any previously-running task before starting (`currentTask?.cancel(); _ = await currentTask?.value`) — same actor-reentrancy guard pattern as Phase 4's AgentOrchestrator.
  - Dispatch on tier: tier1 → `tier1.speak(text, voice:)`; tier2 → `orpheus.synthesize(text, voice:, into: sink)`.
  - Yield `.started` at entry, `.firstAudio(at: Date())` on first `.audio` event (track via flag in the loop), `.finished` on completion.
- `ttsEventStream`: `nonisolated let` AsyncStream populated via internal continuation.
- `cancel()`: cancels currentTask + propagates to Orpheus/AVSpeech.

Implement `TTSKitFallback.swift`:
- Mirror `OrpheusTTS` shape but call `kit.play(text, strategy: .auto)`.
- Test seam: `init(kitFactory:)`.

For TTFA tests (T1/T2):
- Use `ContinuousClock.now` deltas.
- Wrap in `XCTSkipUnless(ProcessInfo.processInfo.environment["JARVIS_REAL_MODELS"] == "1", "Set JARVIS_REAL_MODELS=1 to run TTFA probes")` — this keeps CI green while letting the user run on real hardware.

For O1/O2/O3 (deadlock + ordering):
- Use the test-seam factory to inject a scripted `LlamaTTSModel` whose `generateStream` is a deterministic AsyncThrowingStream — no real model needed.
- O2's "no deadlock" assertion uses `Task.timeout` or a `withTimeout` helper to fail-fast if a deadlock is hit.

Verify: O1..O3 + T1/T2 (with skip-unless) pass.
  </action>
  <verify>
    <automated>swift test --package-path packages/Voice --filter VoiceTests.OrpheusSerializationTests</automated>
  </verify>
  <done>OrpheusSerializationTests (3 cases — O1..O3) pass with scripted model. OrpheusTTFATests (2 cases — T1/T2) skip-unless when env var unset; pass with weights present. The serial-executor invariant is documented inline in `TTSEngineActor.swift` with reference to Pitfall #1. The cancel-before-start guard mirrors AgentOrchestrator's pattern.</done>
</task>

<task type="auto" tdd="true">
  <name>Task 3: TTSInterrupt atomic 5-step sequence + ducking-release gate</name>
  <files>packages/Voice/Sources/Voice/TTS/TTSInterrupt.swift, packages/Voice/Tests/VoiceTests/TTSInterruptTests.swift</files>
  <behavior>
    - TTSInterruptTests I1 (5-step ordering): inject a recorder for each step (cancel / fade / stop / awaitCompletion / emit); call `InterruptSequence.run(...)`; assert the recorder shows steps in order 1,2,3,4,5 with no skips and no reorders.
    - TTSInterruptTests I2 (10 ms cosine fade duration): the fade buffer enqueued during step 2 is exactly 10 ms (160 samples @ 16 kHz, or proportional at the actual sink format). Verify via inspecting the AudioSink call.
    - TTSInterruptTests I3 (≤20 ms completion timeout): if `playerNode.stop()` doesn't drain within 20 ms, step 4 returns anyway and step 5 fires. Test: stub `awaitCompletion(timeout:)` to delay 100 ms; assert `.ttsStopped` fires at ~20 ms ± 5 ms — proving the timeout.
    - TTSInterruptTests I4 (ducking gate): set up a duck observer that lowers volume on `.ttsStopped`. Inject a `.finished` event into the stream — observer remains UP. Then inject `.ttsStopped` — observer fires. Assertion: ducking lowers EXACTLY ONCE, on `.ttsStopped`. (Pitfall #6 / VOICE-11 spec.)
    - TTSInterruptTests I5 (idempotency): calling `InterruptSequence.run(...)` twice in succession does not emit two `.ttsStopped` events (the second call is a no-op when no synth is in flight).
  </behavior>
  <action>
Implement `TTSInterrupt.swift`:
```swift
public enum InterruptSequence {
    public static func run(engine: TTSEngineActor,
                           sink: AudioSink,
                           eventBus: AsyncStream<TTSEvent>.Continuation) async {
        // STEP 1: cancel producer (idempotent if no synth in flight)
        await engine.cancel()

        // STEP 2: 10 ms cosine fade-out (prevents click/pop tail — VOICE-11)
        await sink.cosineFadeOut(duration: .milliseconds(10))

        // STEP 3: stop the player node (drains scheduled buffers; the fade is the last one)
        sink.stop()

        // STEP 4: await completion, bounded ≤ 20 ms (VOICE-11 spec)
        await sink.awaitCompletion(timeout: .milliseconds(20))

        // STEP 5: emit .ttsStopped — THIS is the ducking-release gate
        eventBus.yield(.ttsStopped)
    }
}
```

The function is a free function (in an enum namespace) so test recorder injection is via the *parameters*, not internal mocking — the test passes a real `TTSEngineActor` constructed with stubs and a real `AudioSink` constructed with a stub `AVAudioPlayerNode`. The parameter pattern + the ordered sequence in code IS the testable contract.

For I4 (ducking gate): the test wires up a small observer:
```swift
var duckLowered = 0
let observer = Task {
  for await event in stream {
    if case .ttsStopped = event { duckLowered += 1 }
  }
}
continuation.yield(.finished)        // should NOT trigger
continuation.yield(.ttsStopped)      // should trigger
// ... assert duckLowered == 1
```

For I5 (idempotency): the second call to `run(...)` calls `engine.cancel()` (no-op), `sink.cosineFadeOut()` on an empty sink (no-op or short fade buffer), `sink.stop()` (no-op), `awaitCompletion(timeout:)` (returns immediately), and yields `.ttsStopped` AGAIN. So the implementation needs a guard: track an `isStopping` flag in the AudioSink and return early from `cosineFadeOut`/`stop` if already stopped, OR check `engine.currentTask == nil` at the start of `run` and return early.

Decision: Implement the early-return at the start of `run`:
```swift
guard await engine.hasSynthInFlight else { return }
```
Document: "Idempotency: if no synth is in flight, the interrupt sequence is a no-op. Plan 06-05's barge-in path may call this defensively even when `.idle` — the early return is the safety net."

Verify: I1..I5 pass. The ordering recorder asserts exact sequence.
  </action>
  <verify>
    <automated>swift test --package-path packages/Voice --filter VoiceTests.TTSInterruptTests</automated>
  </verify>
  <done>TTSInterruptTests (5 cases — I1..I5) pass. The 5-step sequence is in `TTSInterrupt.swift` with inline comments referencing VOICE-11 step numbers. Ducking-gate test proves `.finished` does NOT release ducking (Pitfall #6). Idempotency test proves repeated calls don't double-emit `.ttsStopped`.</done>
</task>

</tasks>

<threat_model>
## Trust Boundaries

| Boundary | Description |
|----------|-------------|
| LLM-generated text → TTS synthesis | Untrusted text content fed to AVSpeechSynthesizer / Orpheus / TTSKit. Prompt-injection of TTS pronunciation directives or SSML is a v2 concern (none of the three engines parse SSML by default). |
| Orpheus model weights → in-process Metal kernels | First-party MLX runtime; trust same as Apple's MLX framework. No network. |
| AVAudioPlayerNode → speaker | OS-mediated; cosine fade is a defense against click/pop UX regressions, not a security boundary. |

## STRIDE Threat Register

| Threat ID | Category | Component | Disposition | Mitigation Plan |
|-----------|----------|-----------|-------------|-----------------|
| T-06-04-01 | Denial of Service | Metal command-buffer deadlock under concurrent synthesis | mitigate | TTSEngineActor's serial executor; OrpheusSerializationTests O2 exercises 10-concurrent rapid-fire and asserts no deadlock within 30 s budget. |
| T-06-04-02 | Information Disclosure | TTS engine receives sensitive text (e.g. clipboard content fed verbatim) | accept | Phase 5's `mcp-clipboard` already gates clipboard reads; Plan 05-04's sanitize pipeline strips control characters. TTS audio output is local-only — no exfiltration vector. |
| T-06-04-03 | Tampering | Adversarial text triggers crash via Orpheus tokenizer | mitigate | Tokenizer is in MLX kernel space; crash terminates the synthesize task only, not the actor. Cancellation guard reset + actor reentrancy prevents stuck state across the failure boundary. |
| T-06-04-04 | Denial of Service | Stalled `.audio` chunk consumer blocks Orpheus producer | accept | AudioSink is bounded (AVAudioPlayerNode has its own internal queue); back-pressure from the sink is acceptable in v1. Plan 06-05 monitors stream lag. |
| T-06-04-05 | Repudiation | TTS interrupt without `.ttsStopped` confuses ducking | mitigate | TTSInterruptTests I4 proves ducking releases ONLY on `.ttsStopped`; production code path emits `.ttsStopped` at step 5 of `InterruptSequence.run` — the ONLY emission site (single source of truth). |
| T-06-04-06 | Tampering | Python sidecar reintroduced for Orpheus | mitigate | Project hard rule (CLAUDE.md voice stack): no Python sidecar. Grep gate at Phase 8: `grep -rE 'subprocess|Process\\(\\).*python' packages/Voice/Sources/` — 0 matches. |
</threat_model>

<verification>
- `swift test --package-path packages/Voice` — all VoiceTests green (Plans 06-01 + 06-02 + 06-03 + this plan = ~46 net cases).
- `swift build --package-path packages/Voice` — clean Debug + Release.
- Grep gates:
  - `grep -nE 'stopSpeaking\\(at: \\.immediate\\)' packages/Voice/Sources/Voice/TTS/AVSpeechSynth.swift` — at least 1 (rapid-fire guard).
  - `grep -nE 'cosineFadeOut|cosineFade' packages/Voice/Sources/Voice/TTS/TTSInterrupt.swift` — exactly 1 production call site.
  - `grep -nE '\\.ttsStopped' packages/Voice/Sources/Voice/TTS/TTSInterrupt.swift | grep -v '^[[:space:]]*//' | wc -l` — exactly 1 (single emission site).
  - `grep -nE 'orpheus-3b-0.1-ft-bf16' packages/Voice/Sources/Voice/TTS/OrpheusTTS.swift` — exactly 1 (model-name anchor).
  - `grep -rnE 'subprocess|Process\\(\\)' packages/Voice/Sources/Voice/TTS/` — 0 matches (no Python sidecar).
- TTFA probe (env-gated): on the user's Apple Silicon host, `JARVIS_REAL_MODELS=1 swift test --filter VoiceTests.OrpheusTTFATests` measures real TTFA; result logged in SUMMARY.md.
- `Package.swift` is unchanged from Plan 06-01.
</verification>

<success_criteria>
- VOICE-05 closed at the unit-test level: AVSpeechSynth wraps `AVSpeechSynthesizer` correctly with stored synth + stored delegate; rapid-fire guard via `stopSpeaking(.immediate)`.
- VOICE-06 closed at the unit-test level: OrpheusTTS + TTSEngineActor with serial executor proves rapid-fire FIFO + no deadlock; TTSKit fallback wired; TTFA scaffold probe runs under env gate.
- VOICE-11 closed at the unit-test level: 5-step interrupt sequence in exact order; ducking releases ONLY on `.ttsStopped`; idempotency safe.
- The `InterruptSequence.run(...)` primitive is ready for Plan 06-05's `cancelAndSubmit` integration.
- Wave-3 file ownership disjoint from 06-02 (`WakeWord/*`) and 06-03 (`VAD/*` + `STT/*`).
</success_criteria>

<output>
After completion, create `.planning/phases/06-voice/06-04-SUMMARY.md` documenting:
- The serial-executor invariant (TTSEngineActor's default serial executor IS the deadlock guard).
- The 5-step interrupt sequence with line numbers in `TTSInterrupt.swift`.
- The ducking gate decision (only on `.ttsStopped`, never on `.finished`).
- The TTFA probe result (real value, environment, remediation if > 250 ms).
- The Python-sidecar grep gate result.
- Test count: ~14 (4 AVSpeech + 5 Orpheus + 5 Interrupt).
</output>
