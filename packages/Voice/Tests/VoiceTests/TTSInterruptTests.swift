import XCTest
@testable import Voice
import AVFoundation
import MLXAudioCore

// MARK: - TTSInterruptTests
//
// Tests for TTSInterrupt atomic 5-step sequence (Plan 06-04 / VOICE-11).
//
// I1: 5-step ordering — steps fire in order: cancel→fade→stop→awaitCompletion→ttsStopped.
// I2: 10 ms cosine fade duration — fade buffer is exactly 160 samples @ 16 kHz.
// I3: ≤20 ms completion timeout — .ttsStopped fires even if awaitCompletion stalls.
// I4: Ducking gate — .finished does NOT release ducking; .ttsStopped does.
// I5: Idempotency — second InterruptSequence.run() on idle engine is a no-op.

final class TTSInterruptTests: XCTestCase {

    // MARK: I1 — 5-step ordering

    func testI1_fiveStepOrdering() async throws {
        let stepLog = StepLog()
        let orpheus = OrpheusTTS(model: NullSpeechModel())
        let tier1 = AVSpeechSynth()
        let engine = TTSEngineActor(orpheus: orpheus, tier1: tier1, fallback: nil)

        let (stream, cont) = AsyncStream<TTSEvent>.makeStream()
        let (avEngine, playerNode, format) = makeAudioComponents()

        // Start a synthesis to set hasSynthInFlight = true
        let slowModel = ScriptedSpeechModel(tokenCount: 100, delay: .milliseconds(100))
        let slowOrpheus = OrpheusTTS(model: slowModel)
        let slowEngine = TTSEngineActor(orpheus: slowOrpheus, tier1: AVSpeechSynth(), fallback: nil)
        let synthTask = Task<Void, Error> {
            try await slowEngine.synthesize("long", tier: TTSTier.tier2, voice: "tara")
        }
        // Give synthesis a moment to start
        try await Task.sleep(for: .milliseconds(20))

        let sink = RecordingAudioSink(
            playerNode: playerNode,
            format: format,
            stepLog: stepLog
        )
        try avEngine.start()
        playerNode.play()

        // Run the interrupt sequence
        await InterruptSequence.run(
            engine: slowEngine,
            sink: sink,
            eventBus: cont,
            stepLog: stepLog
        )

        synthTask.cancel()
        cont.finish()
        var events: [TTSEvent] = []
        for await e in stream { events.append(e) }

        // Verify 5-step sequence in order
        let steps = stepLog.steps
        XCTAssertEqual(
            steps,
            ["1-cancel", "2-fade", "3-stop", "4-await", "5-ttsStopped"],
            "InterruptSequence must fire steps in exact order: 1-cancel→2-fade→3-stop→4-await→5-ttsStopped"
        )
        XCTAssertTrue(events.contains(.ttsStopped), "InterruptSequence must emit .ttsStopped (step 5)")

        avEngine.stop()
    }

    // MARK: I2 — 10 ms cosine fade duration

    func testI2_tenMillisecondCosineFadeDuration() async throws {
        let slowModel = ScriptedSpeechModel(tokenCount: 100, delay: .milliseconds(100))
        let orpheus = OrpheusTTS(model: slowModel)
        let tier1 = AVSpeechSynth()
        let engine = TTSEngineActor(orpheus: orpheus, tier1: tier1, fallback: nil)
        let (_, cont) = AsyncStream<TTSEvent>.makeStream()

        let (avEngine, playerNode, format) = makeAudioComponents()
        let sink = AudioSink(playerNode: playerNode, format: format)
        try avEngine.start()
        playerNode.play()

        // Start synthesis to activate hasSynthInFlight
        let synthTask = Task<Void, Error> {
            try await engine.synthesize("long", tier: TTSTier.tier2, voice: "tara")
        }
        try await Task.sleep(for: .milliseconds(20))

        await InterruptSequence.run(engine: engine, sink: sink, eventBus: cont, stepLog: nil)
        synthTask.cancel()
        cont.finish()

        // At 16 kHz, 10 ms = 160 samples
        let fadeSamples = sink.lastFadeSamples
        XCTAssertEqual(
            fadeSamples.count,
            160,
            "10 ms cosine fade at 16 kHz must produce 160 samples"
        )

        avEngine.stop()
    }

    // MARK: I3 — ≤20 ms completion timeout

    func testI3_completionTimeoutRespected() async throws {
        let slowModel = ScriptedSpeechModel(tokenCount: 100, delay: .milliseconds(100))
        let orpheus = OrpheusTTS(model: slowModel)
        let tier1 = AVSpeechSynth()
        let engine = TTSEngineActor(orpheus: orpheus, tier1: tier1, fallback: nil)
        let (stream, cont) = AsyncStream<TTSEvent>.makeStream()

        let (avEngine, playerNode, format) = makeAudioComponents()
        // Stall widened from 100ms → 400ms (CI-jitter buffer). The semantic
        // under test is "InterruptSequence's 20ms completion timeout fires
        // before the sink stall would have completed on its own" — measured
        // by `elapsed < stallDuration`. The previous 100ms stall + 80ms
        // budget was too tight for macos-15 GitHub Actions runners; CI run
        // 25801448991 observed elapsed=108ms (already past the 100ms stall),
        // meaning the assertion was self-defeating under CI load. Widening
        // the stall to 400ms gives the 20ms timeout ample headroom while
        // keeping the semantic intact.
        let sink = StallingSink(
            playerNode: playerNode,
            format: format,
            stallDuration: .milliseconds(400)
        )
        try avEngine.start()
        playerNode.play()

        // Start synthesis to activate hasSynthInFlight
        let synthTask = Task<Void, Error> {
            try await engine.synthesize("long", tier: TTSTier.tier2, voice: "tara")
        }
        // Wait for OrpheusTTS.synthesize to actually start producing (inner task
        // running) before triggering the interrupt — otherwise OrpheusTTS.cancel()
        // is a no-op (currentTask still nil) and the inner stream runs to
        // completion. 200 ms gives engine.start()+actor hop+first .token yield
        // a comfortable margin.
        try await Task.sleep(for: .milliseconds(200))

        let start = Date()
        await InterruptSequence.run(engine: engine, sink: sink, eventBus: cont, stepLog: nil)
        let elapsed = Date().timeIntervalSince(start)

        synthTask.cancel()
        cont.finish()
        var events: [TTSEvent] = []
        for await e in stream { events.append(e) }

        // .ttsStopped must fire before the 400 ms stall completes (20 ms timeout
        // + CI overhead). Budget = 250 ms: 20 ms timeout + ~230 ms of allowable
        // actor-hop / scheduling overhead on a cold CI runner, still well
        // under the 400 ms stall ceiling that would invalidate the semantic.
        XCTAssertLessThan(
            elapsed,
            0.250,
            "InterruptSequence must complete within ~250 ms (20 ms timeout + CI overhead), got \(elapsed * 1000) ms"
        )
        XCTAssertTrue(events.contains(.ttsStopped), ".ttsStopped must fire on timeout")

        avEngine.stop()
    }

    // MARK: I4 — Ducking gate: .finished does NOT release ducking

    func testI4_duckingGateOnlyOnTtsStopped() async throws {
        let (stream, cont) = AsyncStream<TTSEvent>.makeStream()
        let duckCounter = DuckCounter()

        let observerTask = Task {
            for await event in stream {
                if case .ttsStopped = event {
                    duckCounter.increment()
                }
                // .finished must NOT increment — that is the Pitfall #6 guard.
            }
        }

        // Inject .finished first — ducking must NOT fire
        cont.yield(.finished)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(
            duckCounter.value,
            0,
            "Ducking must NOT be released on .finished alone (Pitfall #6 / VOICE-11)"
        )

        // Inject .ttsStopped — ducking MUST fire exactly once
        cont.yield(.ttsStopped)
        cont.finish()
        try await Task.sleep(for: .milliseconds(20))
        await observerTask.value

        XCTAssertEqual(
            duckCounter.value,
            1,
            "Ducking must be released EXACTLY ONCE on .ttsStopped"
        )
    }

    // MARK: I5 — Idempotency: second call when idle is a no-op

    func testI5_idempotencyNoDoubleTtsStopped() async throws {
        let orpheus = OrpheusTTS(model: NullSpeechModel())
        let tier1 = AVSpeechSynth()
        let engine = TTSEngineActor(orpheus: orpheus, tier1: tier1, fallback: nil)
        let (stream, cont) = AsyncStream<TTSEvent>.makeStream()

        let (avEngine, playerNode, format) = makeAudioComponents()
        let sink = AudioSink(playerNode: playerNode, format: format)
        try avEngine.start()
        playerNode.play()

        // engine.hasSynthInFlight == false → both calls should be no-ops
        await InterruptSequence.run(engine: engine, sink: sink, eventBus: cont, stepLog: nil)
        await InterruptSequence.run(engine: engine, sink: sink, eventBus: cont, stepLog: nil)

        cont.finish()
        var events: [TTSEvent] = []
        for await e in stream { events.append(e) }

        let stoppedCount = events.filter { $0 == .ttsStopped }.count
        XCTAssertEqual(
            stoppedCount,
            0,
            "Idempotent calls when idle must emit 0 .ttsStopped (no synth in flight — no-op)"
        )

        avEngine.stop()
    }

    // MARK: - Helpers

    private func makeAudioComponents() -> (AVAudioEngine, AVAudioPlayerNode, AVAudioFormat) {
        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()
        engine.attach(playerNode)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        return (engine, playerNode, format)
    }
}

// MARK: - NullSpeechModel (test seam)

/// A model that emits zero events — used when we need an OrpheusTTS with nothing in flight.
final class NullSpeechModel: SpeechGenerationModelProtocol, @unchecked Sendable {
    let sampleRate: Int = 24000
    func makeStream(text: String, voice: String) -> AsyncThrowingStream<AudioGeneration, Error> {
        AsyncThrowingStream { continuation in continuation.finish() }
    }
}

// MARK: - StepLog (thread-safe ordered step recorder for I1)
//
// Conforms to `InterruptStepRecorder` (defined in Voice module) for injection
// into `InterruptSequence.run(stepLog:)`.

final class StepLog: InterruptStepRecorder, @unchecked Sendable {
    private let queue = DispatchQueue(label: "StepLog")
    private var _steps: [String] = []

    public func record(_ step: String) { queue.sync { _steps.append(step) } }
    var steps: [String] { queue.sync { _steps } }
}

// MARK: - RecordingAudioSink (wraps AudioSink for I1 — delegates only, no step recording)
//
// Conforms to `InterruptibleAudioSink` (from Voice module).
// Step recording is done by InterruptSequence.run via the stepLog parameter —
// RecordingAudioSink simply delegates to the real AudioSink.

final class RecordingAudioSink: InterruptibleAudioSink, @unchecked Sendable {
    private let real: AudioSink

    var lastFadeSamples: [Float] { real.lastFadeSamples }

    init(playerNode: AVAudioPlayerNode, format: AVAudioFormat, stepLog: StepLog) {
        self.real = AudioSink(playerNode: playerNode, format: format)
    }

    func cosineFadeOut(duration: Duration) async {
        await real.cosineFadeOut(duration: duration)
    }

    func stop() {
        real.stop()
    }

    func awaitCompletion(timeout: Duration) async {
        await real.awaitCompletion(timeout: timeout)
    }
}

// MARK: - StallingSink (simulates slow drain for I3)
//
// Conforms to `InterruptibleAudioSink`.

final class StallingSink: InterruptibleAudioSink, @unchecked Sendable {
    private let playerNode: AVAudioPlayerNode
    private let format: AVAudioFormat
    private let stallDuration: Duration
    nonisolated(unsafe) var lastFadeSamples: [Float] = []

    init(playerNode: AVAudioPlayerNode, format: AVAudioFormat, stallDuration: Duration) {
        self.playerNode = playerNode
        self.format = format
        self.stallDuration = stallDuration
    }

    func cosineFadeOut(duration: Duration) async {
        let sampleRate = format.sampleRate
        let seconds = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) * 1e-18
        let frameCount = max(1, Int(sampleRate * seconds))
        lastFadeSamples = (0..<frameCount).map { i in
            cos(Float.pi * Float(i) / (2.0 * Float(frameCount)))
        }
    }

    func stop() {
        playerNode.stop()
    }

    func awaitCompletion(timeout: Duration) async {
        // Stall longer than the InterruptSequence's 20 ms timeout (I3 test)
        try? await Task.sleep(for: stallDuration)
    }
}

// MARK: - DuckCounter (for I4 ducking gate assertion)

final class DuckCounter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "DuckCounter")
    private var _value = 0
    func increment() { queue.sync { _value += 1 } }
    var value: Int { queue.sync { _value } }
}
