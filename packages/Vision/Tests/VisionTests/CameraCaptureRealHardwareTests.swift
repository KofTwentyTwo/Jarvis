import XCTest
import AVFoundation
@testable import JarvisVision

/// Track-C 6 — real-hardware vision integration test.
///
/// Exercises the full Track-C 1..2 path on a host with a real camera and
/// pre-granted Camera TCC: open() → capturePhoto delegate → frameStream
/// receives video samples → both producers yield real bytes.
///
/// **Gating:** the test skips unless ALL of the following hold:
///   1. `JARVIS_REAL_CAMERA=1` is set in the environment (matches the
///      `JARVIS_REAL_MODELS` convention used elsewhere in the test suite).
///   2. `AVCaptureDevice.default(for: .video)` is non-nil.
///   3. `AVCaptureDevice.authorizationStatus(for: .video) == .authorized`
///      — we deliberately do NOT call `requestAccess(for:)` from a test
///      so headless / first-launch test runs never block on a TCC prompt.
///
/// Run interactively after granting Camera TCC to the test host:
///   JARVIS_REAL_CAMERA=1 swift test --package-path packages/Vision \
///     --filter CameraCaptureRealHardwareTests
final class CameraCaptureRealHardwareTests: XCTestCase {

    func testRealCameraCaptureProducesNonTrivialJPEG() async throws {
        try Self.skipUnlessRealCameraAvailable()

        let (degStream, degCont) = AsyncStream<VisionDegradationReason>.makeStream()
        let capture = CameraCapture(degradationContinuation: degCont, degradationStream: degStream)
        try await capture.open()
        defer { Task { await capture.shutdown() } }

        // Capture a frame via the real photoOutput delegate path.
        let frame = try await capture.captureFrame()

        // Real JPEG: at minimum a 4-byte SOI + APP0 marker prefix and a
        // body more than the 1×1 stub's 125-byte payload.
        XCTAssertGreaterThan(frame.jpegData.count, 1000,
            "real camera frame must be larger than the historical 125-byte stub")
        XCTAssertEqual(frame.jpegData.prefix(2), Data([0xFF, 0xD8]),
            "real frame must carry the JPEG SOI marker")
        XCTAssertGreaterThan(frame.width, 1,
            "real camera frame width must exceed the 1×1 stub")
        XCTAssertGreaterThan(frame.height, 1,
            "real camera frame height must exceed the 1×1 stub")

        _ = degStream
    }

    func testRealCameraFrameStreamYieldsSamplesWithinTimeout() async throws {
        try Self.skipUnlessRealCameraAvailable()

        let (degStream, degCont) = AsyncStream<VisionDegradationReason>.makeStream()
        let capture = CameraCapture(degradationContinuation: degCont, degradationStream: degStream)
        try await capture.open()
        defer { Task { await capture.shutdown() } }

        // Subscribe and wait up to 2s for the first sample buffer to arrive
        // through the AVCaptureVideoDataOutput delegate fan-out.
        let stream = capture.frameStream(forPresence: true)

        let sample = await Self.firstSample(from: stream, timeout: 2.0)
        XCTAssertNotNil(sample, "real camera must emit a video sample within 2s")
        if let sample {
            switch sample {
            case .sampleBuffer:
                break    // expected production shape
            case .cgImage, .syntheticDetection:
                XCTFail("real camera must yield .sampleBuffer, not \(sample)")
            }
        }
        _ = degStream
    }

    // MARK: - Gating helper

    static func skipUnlessRealCameraAvailable() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["JARVIS_REAL_CAMERA"] == "1",
            "Set JARVIS_REAL_CAMERA=1 to run hardware vision tests (requires a real camera and pre-granted Camera TCC)"
        )
        try XCTSkipIf(
            AVCaptureDevice.default(for: .video) == nil,
            "no camera device — skipping hardware test"
        )
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        try XCTSkipUnless(
            status == .authorized,
            "Camera TCC not granted (status=\(status.rawValue)); the test does NOT prompt — grant manually before running"
        )
    }

    private static func firstSample(
        from stream: AsyncStream<PresenceFrameSample>,
        timeout: TimeInterval
    ) async -> PresenceFrameSample? {
        let collector = Task<PresenceFrameSample?, Never> {
            for await sample in stream { return sample }
            return nil
        }
        let timer = Task<PresenceFrameSample?, Never> {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            collector.cancel()
            return nil
        }
        let result = await collector.value
        timer.cancel()
        return result
    }
}
