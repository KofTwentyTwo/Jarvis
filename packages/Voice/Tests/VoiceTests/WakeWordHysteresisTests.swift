import XCTest
import Foundation
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

    // MARK: - Helpers

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
