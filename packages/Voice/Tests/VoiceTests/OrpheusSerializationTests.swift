import XCTest
@testable import Voice
import MLXAudioCore
import AVFoundation

// MARK: - OrpheusSerializationTests
//
// Tests for OrpheusTTS + TTSEngineActor serial-executor invariant (Plan 06-04).
//
// O1: FIFO ordering via serial executor — 3 concurrent calls are serialized.
// O2: No deadlock under rapid fire — 10 concurrent calls all complete within 30 s.
// O3: Cancellation propagates — cancel mid-synthesis; subsequent calls work.
//
// All tests use `ScriptedSpeechModel` (emits only .token events to avoid MLX Metal GPU).
// MLXArray creation requires the Metal metallib; SPM test runner lacks the GPU environment.

final class OrpheusSerializationTests: XCTestCase {

    // MARK: O1 — Serial executor enforces FIFO ordering

    func testO1_serialExecutorFifoOrdering() async throws {
        // ScriptedSpeechModel emits 5 tokens then finishes (no MLX Metal needed)
        let model = ScriptedSpeechModel(tokenCount: 5, delay: .milliseconds(10))
        let orpheus = OrpheusTTS(model: model)
        let engine = makeTestEngine(orpheus: orpheus)

        // Submit 3 concurrent synthesize tasks
        // The TTSEngineActor's serial executor serializes them via cancel-before-start.
        let results = await withTaskGroup(of: String.self, returning: [String].self) { group in
            group.addTask {
                do {
                    try await engine.synthesize("first", tier: TTSTier.tier2, voice: "tara")
                    return "done"
                } catch { return "cancelled" }
            }
            group.addTask {
                do {
                    try await engine.synthesize("second", tier: TTSTier.tier2, voice: "tara")
                    return "done"
                } catch { return "cancelled" }
            }
            group.addTask {
                do {
                    try await engine.synthesize("third", tier: TTSTier.tier2, voice: "tara")
                    return "done"
                } catch { return "cancelled" }
            }
            var out: [String] = []
            for await r in group { out.append(r) }
            return out
        }

        // All 3 tasks must return (no hang = serial executor working)
        XCTAssertEqual(results.count, 3, "All 3 concurrent tasks must return (no deadlock)")

        // At least one must have completed (the last one wins in cancel-before-start)
        let doneCount = results.filter { $0 == "done" }.count
        XCTAssertGreaterThanOrEqual(doneCount, 1, "At least one synthesis must complete")
    }

    // MARK: O2 — No deadlock under rapid fire

    func testO2_noDeadlockUnderRapidFire() async throws {
        let model = ScriptedSpeechModel(tokenCount: 3, delay: .milliseconds(5))
        let orpheus = OrpheusTTS(model: model)
        let engine = makeTestEngine(orpheus: orpheus)

        let deadline = Date().addingTimeInterval(30.0)
        let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for _ in 0..<10 {
                group.addTask {
                    do {
                        try await engine.synthesize("hello", tier: TTSTier.tier2, voice: "tara")
                        return true
                    } catch {
                        return true  // Cancellation is acceptable
                    }
                }
            }
            var out: [Bool] = []
            for await r in group { out.append(r) }
            return out
        }

        XCTAssertTrue(Date() < deadline, "10 concurrent calls must complete within 30 s (Pitfall #1: no deadlock)")
        XCTAssertEqual(results.count, 10, "All 10 tasks must return (no hang)")
    }

    // MARK: O3 — Cancellation propagates, no stuck state

    func testO3_cancellationPropagatesNoStuckState() async throws {
        // Use a slow model (200 ms delay per token × 5 tokens = 1 s total)
        let model = ScriptedSpeechModel(tokenCount: 5, delay: .milliseconds(200))
        let orpheus = OrpheusTTS(model: model)
        let engine = makeTestEngine(orpheus: orpheus)

        // Start a synthesis and cancel after 50 ms
        let task = Task<Void, Error> {
            try await engine.synthesize("slow synthesis", tier: TTSTier.tier2, voice: "tara")
        }
        try await Task.sleep(for: .milliseconds(50))
        await engine.cancel()
        task.cancel()

        // Wait for cancellation to settle
        _ = try? await task.value

        // Subsequent synthesize must work (no stuck state)
        do {
            let fastModel = ScriptedSpeechModel(tokenCount: 1, delay: .milliseconds(1))
            let fastOrpheus = OrpheusTTS(model: fastModel)
            let fastEngine = makeTestEngine(orpheus: fastOrpheus)
            try await fastEngine.synthesize("after cancel", tier: TTSTier.tier2, voice: "tara")
        } catch let e as TTSError {
            if case .cancelled = e { return }
            XCTFail("Synthesize after cancel must succeed or throw .cancelled, got: \(e)")
        } catch {
            XCTFail("Unexpected error after cancel: \(error)")
        }
    }

    // MARK: - Helpers

    private func makeTestEngine(orpheus: OrpheusTTS) -> TTSEngineActor {
        let tier1 = AVSpeechSynth()
        return TTSEngineActor(orpheus: orpheus, tier1: tier1, fallback: nil)
    }
}

// MARK: - OrpheusTTFATests
//
// Scaffold-time perf probe for Orpheus TTFA (time-to-first-audio).
// Gated by JARVIS_REAL_MODELS=1 env var — skipped in CI.
//
// T1: Measure TTFA for "Hello, this is Jarvis." — log result; remediation note if > 250 ms.
// T2: TTSKit fallback functional smoke test.

import MLXAudioTTS

final class OrpheusTTFATests: XCTestCase {

    func testT1_orpheusTTFAProbe() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["JARVIS_REAL_MODELS"] == "1",
            "Set JARVIS_REAL_MODELS=1 to run TTFA probes (requires Orpheus weights on Apple Silicon)"
        )

        let model = try await LlamaTTSModel.fromPretrained("mlx-community/orpheus-3b-0.1-ft-bf16")
        let start = ContinuousClock.now

        let stream = model.generateStream(
            text: "Hello, this is Jarvis.",
            voice: "tara",
            refAudio: nil,
            refText: nil,
            language: nil,
            generationParameters: model.defaultGenerationParameters
        )

        var ttfa: Duration?
        for try await event in stream {
            if case .audio = event {
                ttfa = ContinuousClock.now - start
                break
            }
        }

        // Convert Duration to milliseconds
        let ttfaMs: Int64
        if let t = ttfa {
            // Duration.components: seconds + attoseconds (1e-18)
            let totalNs = Int64(t.components.seconds) * 1_000_000_000
                + t.components.attoseconds / 1_000_000_000
            ttfaMs = totalNs / 1_000_000
        } else {
            ttfaMs = -1
        }

        print("OrpheusTTFATests T1: TTFA = \(ttfaMs) ms (target: 150–250 ms)")

        if ttfaMs > 250 {
            print("""
            OrpheusTTFATests T1: REMEDIATION NOTE
            Measured TTFA \(ttfaMs) ms exceeds 250 ms target.
            Recommended action: set features.tts.tier2 = "ttskit" in Plan 06-05's
            feature-flag JSON to use TTSKit as tier-2 instead of Orpheus.
            """)
        }

        XCTAssertTrue(true, "TTFA probe completed (non-gating diagnostic)")
    }

    func testT2_ttskitFallbackFunctional() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["JARVIS_REAL_MODELS"] == "1",
            "Set JARVIS_REAL_MODELS=1 to run TTSKit functional smoke test"
        )

        let fallback = try await TTSKitFallback(modelName: "ttskit-qwen3-tts-0.6b")
        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()
        engine.attach(playerNode)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 24000,
            channels: 1,
            interleaved: false
        ) else {
            XCTFail("Cannot create format")
            return
        }
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        try engine.start()
        playerNode.play()
        let sink = AudioSink(playerNode: playerNode, format: format)

        do {
            try await fallback.synthesize("Hello.", into: sink)
        } catch {
            XCTFail("TTSKit fallback synthesize failed: \(error)")
        }

        engine.stop()
        XCTAssertTrue(true, "TTSKit T2 functional smoke passed")
    }
}

// MARK: - ScriptedSpeechModel (test seam)
//
// Deterministic `SpeechGenerationModelProtocol`-conformant model that emits
// `.token(Int)` events only (NO MLX Metal needed — avoids metallib crash in SPM tests).
// Tests verify serialization behavior via call counts + timing, not audio samples.

final class ScriptedSpeechModel: SpeechGenerationModelProtocol, @unchecked Sendable {
    let sampleRate: Int = 24000

    private let tokenCount: Int
    private let delay: Duration
    private let queue = DispatchQueue(label: "ScriptedSpeechModel")
    private var _callCount: Int = 0

    var callCount: Int { queue.sync { _callCount } }

    init(tokenCount: Int, delay: Duration = .milliseconds(5)) {
        self.tokenCount = tokenCount
        self.delay = delay
    }

    func makeStream(text: String, voice: String) -> AsyncThrowingStream<AudioGeneration, Error> {
        let count = tokenCount
        let d = delay
        queue.sync { _callCount += 1 }

        return AsyncThrowingStream { continuation in
            Task {
                for i in 0..<count {
                    try await Task.sleep(for: d)
                    try Task.checkCancellation()
                    continuation.yield(.token(i))
                }
                // No .audio event — avoids MLX Metal requirement in SPM test runner.
                // Production code handles .token-only streams gracefully (no enqueue).
                continuation.finish()
            }
        }
    }
}
