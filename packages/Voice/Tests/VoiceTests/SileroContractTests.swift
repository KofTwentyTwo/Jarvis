import XCTest
@testable import Voice

// MARK: - SileroContractTests
//
// TDD RED phase: these tests validate the SileroVAD chunk-contract, state machine,
// opset fallback, and scaffold-time parity probe.
//
// RESEARCH-DELTAS Assumption A1: Silero v6.2.1 preserves the 512-sample / 32 ms / 16 kHz
// chunk contract from v5. Tests S1..S6 verify the contract at the unit-test level.
// The ContractParityProbe (S5) is the scaffold-time evidence gate.

final class SileroContractTests: XCTestCase {

    // MARK: - S1: Chunk size enforcement

    func testS1_feedWithExactly512SamplesSucceeds() throws {
        let vad = SileroVAD(engine: MockVADEngine())
        let samples = [Float](repeating: 0, count: 512)
        XCTAssertNoThrow(try samples.withUnsafeBufferPointer { buf in
            _ = try vad.feed(buf)
        })
    }

    func testS1_feedWith511SamplesThrowsInvalidChunkSize() throws {
        let vad = SileroVAD(engine: MockVADEngine())
        let samples = [Float](repeating: 0, count: 511)
        XCTAssertThrowsError(try samples.withUnsafeBufferPointer { buf in
            _ = try vad.feed(buf)
        }) { error in
            guard case VADError.invalidChunkSize(got: 511, expected: 512) = error else {
                XCTFail("Expected VADError.invalidChunkSize, got \(error)")
                return
            }
        }
    }

    func testS1_feedWith513SamplesThrowsInvalidChunkSize() throws {
        let vad = SileroVAD(engine: MockVADEngine())
        let samples = [Float](repeating: 0, count: 513)
        XCTAssertThrowsError(try samples.withUnsafeBufferPointer { buf in
            _ = try vad.feed(buf)
        }) { error in
            guard case VADError.invalidChunkSize(got: 513, expected: 512) = error else {
                XCTFail("Expected VADError.invalidChunkSize, got \(error)")
                return
            }
        }
    }

    // MARK: - S2: State preserved across calls

    func testS2_silenceThenSpeechEmitsSpeechStart() throws {
        // Feed 4 silence chunks → VAD output is .silence
        // Feed 1 speech chunk → output is .speechStart (transition)
        // Feed another speech chunk → .speech (not .speechStart again — state held)
        let engine = MockVADEngine(probabilities: [0.1, 0.1, 0.1, 0.1, 0.9, 0.9])
        let vad = SileroVAD(engine: engine)
        let silence = [Float](repeating: 0, count: 512)

        var results: [VADDecision] = []
        for _ in 0..<6 {
            let decision = try silence.withUnsafeBufferPointer { try vad.feed($0) }
            results.append(decision)
        }

        XCTAssertEqual(results[0], .silence)
        XCTAssertEqual(results[1], .silence)
        XCTAssertEqual(results[2], .silence)
        XCTAssertEqual(results[3], .silence)
        XCTAssertEqual(results[4], .speechStart)  // transition
        XCTAssertEqual(results[5], .speech)        // steady speech
    }

    // MARK: - S3: Transition sequence

    func testS3_silenceThenSpeechThenSilenceTransitionSequence() throws {
        // 3 silence → 3 speech → 3 silence yields:
        // silence, silence, silence, speechStart, speech, speech, speechEnd, silence, silence
        let probs: [Float] = [0.1, 0.1, 0.1,  // silence
                              0.9, 0.9, 0.9,  // speech
                              0.1, 0.1, 0.1]  // silence
        let engine = MockVADEngine(probabilities: probs)
        let vad = SileroVAD(engine: engine)
        let buf = [Float](repeating: 0, count: 512)

        var results: [VADDecision] = []
        for _ in 0..<9 {
            let d = try buf.withUnsafeBufferPointer { try vad.feed($0) }
            results.append(d)
        }

        let expected: [VADDecision] = [
            .silence, .silence, .silence,
            .speechStart, .speech, .speech,
            .speechEnd, .silence, .silence
        ]
        XCTAssertEqual(results, expected,
                       "Transition sequence mismatch: \(results)")
    }

    // MARK: - S4: Opset fallback

    func testS4_opset16SuccessUsesOpset16() throws {
        let engine = MockVADEngine()
        let vad = SileroVAD(engine: engine)
        XCTAssertEqual(vad.loadedOpset, 16)
    }

    func testS4_opset16FailureFallsBackToOpset15() throws {
        let engine = MockVADEngine(failOpset16: true)
        // When opset-16 fails, the actor falls back to opset-15
        let vad = SileroVAD(engine: engine)
        XCTAssertEqual(vad.loadedOpset, 15)
    }

    // MARK: - S5: Contract parity probe (scaffold gate, synthetic waveform)

    #if DEBUG
    func testS5_contractParityProbeWithSyntheticWaveform() async throws {
        // ContractParityProbe generates a synthetic 5-second waveform:
        //   0.0–1.0 s: silence
        //   1.0–2.0 s: 440 Hz sine (speech)
        //   2.0–3.0 s: silence
        //   3.0–4.0 s: 880 Hz sine (speech)
        //   4.0–5.0 s: silence
        //
        // Expected speech boundaries within ±32 ms:
        //   speechStart @ ~1.0 s, speechEnd @ ~2.0 s
        //   speechStart @ ~3.0 s, speechEnd @ ~4.0 s
        //
        // The probe validates the chunk contract is preserved in v6.2.1.
        // NOTE: This test requires the real SileroVAD ONNX models in Resources/models/silero/.
        //       If models are absent, the probe is skipped (not a failure — models are gitignored).

        // Find models relative to #file (package-level path)
        let thisFile = URL(fileURLWithPath: #file)
        // thisFile: .../packages/Voice/Tests/VoiceTests/SileroContractTests.swift
        let packageRoot = thisFile
            .deletingLastPathComponent()  // VoiceTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // Voice package
            .deletingLastPathComponent()  // packages
            .deletingLastPathComponent()  // repo root
        let sileroDir = packageRoot.appendingPathComponent("Resources/models/silero")

        guard FileManager.default.fileExists(atPath: sileroDir.appendingPathComponent("silero_vad.onnx").path)
              || FileManager.default.fileExists(atPath: sileroDir.appendingPathComponent("silero_vad_16k_op15.onnx").path) else {
            // Skip — models not downloaded. Run `scripts/fetch-silero-models.sh` first.
            throw XCTSkip("Silero ONNX models not present in Resources/models/silero/; run scripts/fetch-silero-models.sh")
        }

        try await ContractParityProbe.run(modelDir: sileroDir)
    }
    #endif

    // MARK: - S6: Reset clears hidden state

    func testS6_resetAfterSpeechRunProducesSpeechStartOnNextSpeech() throws {
        // Run speech-then-silence to put the VAD into "was silence" state
        let probs1: [Float] = [0.9, 0.9, 0.1]  // speech, speech, silence → state is .silence
        let engine = MockVADEngine(probabilities: probs1)
        let vad = SileroVAD(engine: engine)
        let buf = [Float](repeating: 0, count: 512)

        for _ in 0..<3 {
            _ = try buf.withUnsafeBufferPointer { try vad.feed($0) }
        }

        // Now reset — hidden state and wasSpeech cleared
        vad.reset()

        // Inject a new speech probability — should emit .speechStart (not .speech)
        // since wasSpeech was cleared by reset()
        engine.setProbabilities([0.9])
        let result = try buf.withUnsafeBufferPointer { try vad.feed($0) }
        XCTAssertEqual(result, .speechStart,
                       "After reset(), first speech chunk should be .speechStart")
    }
}

// MARK: - MockVADEngine

/// Test seam for SileroVAD — provides probabilities without real ONNX models.
/// Thread-safe via nonisolated(unsafe) + caller-side test serialization.
final class MockVADEngine: VADInferenceEngine, @unchecked Sendable {
    nonisolated(unsafe) private var probabilities: [Float]
    nonisolated(unsafe) private var index: Int = 0
    nonisolated(unsafe) private var _failOpset16: Bool
    nonisolated(unsafe) var opsetUsed: Int

    init(probabilities: [Float] = [], failOpset16: Bool = false) {
        self.probabilities = probabilities
        self._failOpset16 = failOpset16
        // If opset-16 fails, report opset-15; otherwise opset-16
        self.opsetUsed = failOpset16 ? 15 : 16
    }

    func setProbabilities(_ probs: [Float]) {
        probabilities = probs
        index = 0
    }

    // VADInferenceEngine conformance
    func runInference(pcm: UnsafeBufferPointer<Float>) throws -> Float {
        guard index < probabilities.count else { return 0.1 }  // default silence
        let prob = probabilities[index]
        index += 1
        return prob
    }
}
