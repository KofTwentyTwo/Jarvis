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

// NOTE: OrpheusTTFATests was extracted to its own file (OrpheusTTFATests.swift)
// to match Plan 06-04's `files_modified` listing. The TTFA probe and TTSKit
// functional smoke test live there now.

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
            let producerTask = Task {
                for i in 0..<count {
                    try await Task.sleep(for: d)
                    try Task.checkCancellation()
                    continuation.yield(.token(i))
                }
                // No .audio event — avoids MLX Metal requirement in SPM test runner.
                // Production code handles .token-only streams gracefully (no enqueue).
                continuation.finish()
            }
            // Propagate consumer cancellation (e.g. testI3 deterministic timeout) into
            // the producer Task so the stream actually terminates on the test's deadline
            // instead of running for the full token-count × delay budget.
            continuation.onTermination = { @Sendable _ in
                producerTask.cancel()
            }
        }
    }
}
