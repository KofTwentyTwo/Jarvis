import XCTest
@testable import Voice

/// Coverage for the rolling-window trim of `OpenWakeWordSession`'s
/// streaming buffers (audit-2026-05-12 P1-1 / Issue #32).
///
/// Pre-fix: `melFrameBuffer` and `embeddingBuffer` were append-only.
/// At production cadence (1 mel frame per 80 ms `feed`), 24 h of
/// always-on listening accumulated ~130 MB of mel frames + ~50 MB of
/// embeddings retained forever. The leak was masked because
/// `WakeWordDAG` cancelled on every audio-graph rebuild; closing
/// #28 (rebuild no longer kills wake-word) makes the leak visible.
///
/// Post-fix invariants:
///   - `melFrameBuffer.count <= 76 + embStride` (= 84)
///   - `embeddingBuffer.count <= 16`
///   - `nextEmbStart` never points past `melFrameBuffer.count`
///     (it is shifted left when frames are trimmed)
final class OpenWakeWordBufferBoundsTests: XCTestCase {

    /// Construct a session with the scripted-classifier init so we can
    /// inject frames without requiring ORT model files.
    private func makeSession() -> OpenWakeWordSession {
        return OpenWakeWordSession(scriptedClassifier: { _ in 0.0 })
    }

    /// Synthetic mel frame: 32 floats (correct band count for the
    /// openWakeWord mel stage). Value content is irrelevant for the
    /// trim — only counts and indices matter.
    private func makeFrame() -> [Float] {
        return [Float](repeating: 0.0, count: 32)
    }

    /// Synthetic 96-dim embedding (matches the embedding stage output).
    private func makeEmbedding() -> [Float] {
        return [Float](repeating: 0.0, count: 96)
    }

    /// B1: 10 000 simulated frames must leave both buffers bounded.
    /// Pre-fix this would have stored all 10 000 mel frames + ~10 000
    /// embeddings.
    func test_B1_streamingBuffersStayBoundedUnderHeavyLoad() async {
        let session = makeSession()

        // Inject 10 000 single-frame batches with one embedding each.
        for _ in 0..<10_000 {
            await session._testInjectFrame(
                mels: [makeFrame()],
                embeddingsToAppend: [makeEmbedding()]
            )
        }

        let sizes = await session._testBufferSizes
        XCTAssertLessThanOrEqual(
            sizes.melFrames, 76 + 8,
            "melFrameBuffer must be bounded at 76 + embStride (= 84) after rolling-window trim"
        )
        XCTAssertLessThanOrEqual(
            sizes.embeddings, 16,
            "embeddingBuffer must be bounded at 16 after rolling-window trim"
        )
        XCTAssertGreaterThanOrEqual(
            sizes.nextEmbStart, 0,
            "nextEmbStart must remain non-negative after trim"
        )
        XCTAssertLessThanOrEqual(
            sizes.nextEmbStart, sizes.melFrames,
            "nextEmbStart must remain a valid index into the trimmed melFrameBuffer"
        )
    }

    /// B2: short-stream case (fewer than the trim threshold) must keep
    /// every frame — the trim must only kick in once we exceed the
    /// rolling-window bound. This pins the contract that the trim
    /// preserves classifier context.
    func test_B2_shortStreamRetainsAllFrames() async {
        let session = makeSession()

        // Inject 10 mel frames + 5 embeddings — well below the trim
        // thresholds (84 / 16). Expect both to be retained verbatim.
        for _ in 0..<10 {
            await session._testInjectFrame(mels: [makeFrame()])
        }
        for _ in 0..<5 {
            await session._testInjectFrame(mels: [], embeddingsToAppend: [makeEmbedding()])
        }

        let sizes = await session._testBufferSizes
        XCTAssertEqual(
            sizes.melFrames, 10,
            "short streams below the trim threshold must keep every mel frame"
        )
        XCTAssertEqual(
            sizes.embeddings, 5,
            "short streams below the trim threshold must keep every embedding"
        )
    }
}
