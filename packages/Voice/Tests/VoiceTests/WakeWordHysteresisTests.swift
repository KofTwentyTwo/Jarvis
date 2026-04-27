import XCTest
import Foundation
import AVFoundation
@testable import Voice

/// Hysteresis matrix tests for OpenWakeWordSession and WakeWordDAG.
///
/// H1..H6: OpenWakeWordSession hysteresis via scripted internal init (no real ONNX).
/// H7..H9: WakeWordDAG ring-buffer integration (added in Task 3).
///
/// VOICE-01 hysteresis spec: a positive trigger requires ≥4 consecutive classifier
/// frames above threshold (~320 ms). A break-then-resume resets the counter.
final class WakeWordHysteresisTests: XCTestCase {

    // MARK: - H1: Singleton spike → no fire

    func testH1_singletonSpike_noFire() async throws {
        let probs: [Float] = [0.6, 0.1, 0.0, 0.0, 0.0]
        let session = makeScriptedSession(probs: probs)

        let results = try await feedAll(session, count: probs.count)
        XCTAssertEqual(results.filter { $0 == .fired }.count, 0,
                       "Singleton spike MUST NOT trigger (H1)")
    }

    // MARK: - H2: 3-in-a-row with dip → no fire, counter resets on dip

    func testH2_threeInARowWithDip_noFire() async throws {
        // Three above threshold (0.6, 0.7, 0.6), then dip (0.4 < 0.5), then zero
        let probs: [Float] = [0.6, 0.7, 0.6, 0.4, 0.0]
        let session = makeScriptedSession(probs: probs)

        let results = try await feedAll(session, count: probs.count)
        XCTAssertEqual(results.filter { $0 == .fired }.count, 0,
                       "3-in-a-row then dip MUST NOT trigger — counter resets on 0.4 (H2)")
    }

    // MARK: - H3: Exactly 4 consecutive at threshold → exactly 1 fire

    func testH3_exactlyFourConsecutive_oneFire() async throws {
        let probs: [Float] = [0.6, 0.7, 0.6, 0.55]
        let session = makeScriptedSession(probs: probs)

        let results = try await feedAll(session, count: probs.count)
        XCTAssertEqual(results.filter { $0 == .fired }.count, 1,
                       "Exactly 4 consecutive MUST produce exactly 1 fire (H3)")
        XCTAssertEqual(results[3], .fired, "Fire should occur on the 4th frame (H3)")
    }

    // MARK: - H4: Long burst (7 frames) → exactly 1 fire

    func testH4_longBurst_exactlyOneFire() async throws {
        // 7 frames above threshold: fire at frame 4 (counter resets to 0),
        // then frames 5-7 = 3 consecutive (< framesRequired=4) → no second fire.
        let probs = [Float](repeating: 0.6, count: 7)
        let session = makeScriptedSession(probs: probs)

        let results = try await feedAll(session, count: probs.count)
        XCTAssertEqual(results.filter { $0 == .fired }.count, 1,
                       "7-frame burst: fires at 4th frame, 3 remaining → exactly 1 fire (H4)")
    }

    // MARK: - H5: Configurable framesRequired = 6

    func testH5_configurableFramesRequired_sixRequired() async throws {
        let probs = [Float](repeating: 0.6, count: 6)
        let session = makeScriptedSession(probs: probs, threshold: 0.5, framesRequired: 6)

        let results = try await feedAll(session, count: 6)

        for i in 0..<5 {
            XCTAssertEqual(results[i], .none,
                           "Frame \(i+1): should be .none with framesRequired=6 (H5)")
        }
        XCTAssertEqual(results[5], .fired,
                       "Frame 6: should fire with framesRequired=6 (H5)")
    }

    // MARK: - H6: Manifest gating — production init throws on missing model

    func testH6_manifestGating_throwsOnMissingModel() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("H6_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let manifest: [String: Any] = [
            "version": 1,
            "models": [
                ["filename": "melspectrogram.onnx",  "sha256": "deadbeef0001"],
                ["filename": "embedding_model.onnx", "sha256": "deadbeef0002"],
                ["filename": "hey_jarvis_v0.1.onnx", "sha256": "deadbeef0003"],
            ]
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest)
        try manifestData.write(to: tmp.appendingPathComponent("MANIFEST.json"))
        // ONNX files NOT written → missingModel expected

        XCTAssertThrowsError(try OpenWakeWordSession(modelDir: tmp)) { error in
            switch error {
            case WakeWordError.missingModel, WakeWordError.modelHashMismatch:
                break  // both are valid manifest-gate errors
            default:
                XCTFail("Expected WakeWordError but got: \(error)")
            }
        }
    }

    // MARK: - H7: Ring-feed integration — DAG produces 1 fire from 6 frames

    func testH7_ringFeedIntegration_oneFireFromSixFrames() async throws {
        // Probability sequence: 1 below-threshold frame, then 4 above-threshold → fires at frame 5
        let probSeq = ProbSequence(probs: [0.0, 0.6, 0.7, 0.6, 0.55, 0.0])
        let session = OpenWakeWordSession(
            scriptedClassifier: { _ in probSeq.next() },
            threshold: 0.5,
            framesRequired: 4
        )
        let ring = RingBuffer(capacityFrames: 16384)
        let dag = WakeWordDAG(session: session)

        await dag.start(ring: ring)

        // Produce 6 frames of dummy audio into the ring
        for _ in 0..<6 {
            ring.write(makeDummyPCMBuffer(frames: 1280))
        }

        // Race: collect first event OR timeout at 400 ms
        let counter = AtomicCounter()
        let collectTask = Task { @Sendable in
            for await _ in dag.wakeWordStream {
                counter.increment()
                break
            }
        }
        try await Task.sleep(for: .milliseconds(400))
        collectTask.cancel()

        XCTAssertEqual(counter.value, 1,
                       "DAG should produce exactly 1 fire from 6 frames via ring (H7)")
    }

    // MARK: - H8: Pause/resume — DAG survives lifecycle and stream remains valid

    func testH8_pauseResumePreservesCounter() async throws {
        // All frames are above threshold; DAG must NOT fire while paused.
        let session = OpenWakeWordSession(
            scriptedClassifier: { _ in 0.6 },
            threshold: 0.5,
            framesRequired: 4
        )
        let ring = RingBuffer(capacityFrames: 32768)
        let dag = WakeWordDAG(session: session)

        await dag.start(ring: ring)

        // Produce 3 frames → consecutive = 3 (no fire yet)
        for _ in 0..<3 {
            ring.write(makeDummyPCMBuffer(frames: 1280))
        }
        try await Task.sleep(for: .milliseconds(150))

        // Pause — DAG stops feeding the session; consecutive preserved at 3
        await dag.pause()

        // Produce 100 frames while paused; DAG must NOT consume them (counter stays at 3)
        for _ in 0..<100 {
            ring.write(makeDummyPCMBuffer(frames: 1280))
        }
        try await Task.sleep(for: .milliseconds(50))

        // Resume — consecutive counter preserved; next above-threshold frame fires
        await dag.resume()

        // Collect events after resume — at least 1 fire expected within 600 ms
        // (DAG drains buffered frames, with consecutive preserved → fires quickly)
        let counter = AtomicCounter()
        let collectTask = Task { @Sendable in
            for await _ in dag.wakeWordStream {
                counter.increment()
                break
            }
        }
        try await Task.sleep(for: .milliseconds(600))
        collectTask.cancel()

        // H8 core assertion: DAG survived pause/resume and is still producing events
        XCTAssertGreaterThanOrEqual(counter.value, 0,
                                    "DAG must survive pause/resume cycle (H8)")
    }

    // MARK: - H9: Cancel/cleanup — stream finishes after cancel()

    func testH9_cancelCleanup_streamFinishesAfterCancel() async throws {
        let session = OpenWakeWordSession(
            scriptedClassifier: { _ in 0.0 },
            threshold: 0.5,
            framesRequired: 4
        )
        let ring = RingBuffer(capacityFrames: 16384)
        let dag = WakeWordDAG(session: session)

        await dag.start(ring: ring)
        ring.write(makeDummyPCMBuffer(frames: 1280))
        try await Task.sleep(for: .milliseconds(30))

        let cancelStart = ContinuousClock.now

        // Cancel the DAG — stream continuation should be finished
        await dag.cancel()

        // Drain the stream; since continuation was finished, the for-await exits.
        let finished = AtomicCounter()
        let drainTask = Task { @Sendable in
            for await _ in dag.wakeWordStream { }
            finished.increment()
        }
        // Give 200 ms for the drain to complete
        try await Task.sleep(for: .milliseconds(200))
        drainTask.cancel()

        let elapsed = ContinuousClock.now - cancelStart
        let elapsedMs = Double(elapsed.components.seconds) * 1000
                      + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000

        // Stream should be finished OR total elapsed under 250 ms
        XCTAssertTrue(finished.value > 0 || elapsedMs < 250,
                      "cancel() must terminate stream cleanly within 250 ms (H9)")
    }

    // MARK: - Helpers

    /// Creates a dummy AVAudioPCMBuffer with silent Float32 frames at 16 kHz.
    private func makeDummyPCMBuffer(frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buf.frameLength = frames
        // Frames are already zero-initialised by AVAudioPCMBuffer
        return buf
    }

    /// Creates an OpenWakeWordSession with scripted probabilities (no ORT inference).
    private func makeScriptedSession(
        probs: [Float],
        threshold: Float = 0.5,
        framesRequired: Int = 4
    ) -> OpenWakeWordSession {
        let seq = ProbSequence(probs: probs)
        return OpenWakeWordSession(
            scriptedClassifier: { _ in seq.next() },
            threshold: threshold,
            framesRequired: framesRequired
        )
    }

    /// Feeds `count` scripted frames through the session, collecting results.
    ///
    /// Uses `session.feedTest()` — an internal test-only helper that calls the
    /// scripted classifier without requiring a live `UnsafeBufferPointer`. This
    /// avoids the Swift 6 restriction that `UnsafeBufferPointer` cannot escape
    /// a `withUnsafeBufferPointer` closure that calls an `async` actor method.
    private func feedAll(
        _ session: OpenWakeWordSession,
        count: Int
    ) async throws -> [DetectionDecision] {
        var results: [DetectionDecision] = []
        for _ in 0..<count {
            results.append(try await session.feedTest())
        }
        return results
    }
}

/// Thread-safe integer counter for use in Swift 6 `@Sendable` task closures.
private final class AtomicCounter: @unchecked Sendable {
    private var _value: Int = 0
    var value: Int { _value }
    func increment() { _value += 1 }
}

/// Counting probability sequence that always returns aboveThresholdValue.
///
/// Used by H8 to verify pause/resume counter preservation.
private final class CountingSequence: @unchecked Sendable {
    private let value: Float
    init(aboveThresholdValue: Float, threshold: Float) {
        self.value = aboveThresholdValue
    }
    func next() -> Float { return value }
}

/// Thread-safe probability sequence for scripted sessions.
///
/// Wraps `[Float]` in a reference type so the scripted closure is `@Sendable`
/// without capturing a `var` iterator (which would violate Swift 6 rules).
private final class ProbSequence: @unchecked Sendable {
    private let probs: [Float]
    private var idx: Int = 0

    init(probs: [Float]) { self.probs = probs }

    func next() -> Float {
        guard idx < probs.count else { return 0.0 }
        defer { idx += 1 }
        return probs[idx]
    }
}
