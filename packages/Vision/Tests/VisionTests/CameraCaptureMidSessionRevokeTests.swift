import XCTest
import AVFoundation
@testable import JarvisVision

/// Audit 2026-05-12 F-V3 — mid-session TCC revoke observation.
///
/// Before the fix, `CameraCapture.startWatchers()` only observed
/// `AVCaptureSessionRuntimeError`. macOS Sequoia / 26 Tahoe surface
/// mid-session Camera TCC revoke via `AVCaptureSessionWasInterrupted`,
/// not `RuntimeError`. Without an interruption observer, a user revoking
/// camera access via System Settings while the app was running never
/// drove the `cameraRevoked` HUD banner — the producer signal never fired.
///
/// **macOS quirk:** `AVCaptureSessionInterruptionReasonKey` and the
/// associated `InterruptionReason` enum are `API_UNAVAILABLE(macos)` per
/// AVFoundation headers (iOS / macCatalyst / tvOS / visionOS only). So
/// on macOS the observer cannot discriminate reasons; any interruption
/// means we can't capture, and the user should see the revoked banner.
final class CameraCaptureMidSessionRevokeTests: XCTestCase {

    /// Posting an `AVCaptureSessionWasInterrupted` against the live session
    /// must drive the degradation stream to yield `.midSessionRevoked`.
    /// Without the observer this notification would arrive silently.
    func testInterruptionYieldsMidSessionRevoked() async throws {
        let (stream, cont) = AsyncStream<VisionDegradationReason>.makeStream()
        let capture = CameraCapture(degradationContinuation: cont, degradationStream: stream)
        await capture.setAuthStatusProbe { .authorized }

        do {
            try await capture.open()
        } catch VisionError.noCameraDevice {
            try XCTSkipIf(true, "no camera device available — see Track-C 6 hardware test")
            return
        } catch {
            try XCTSkipIf(true, "camera open failed (\(error)) — see Track-C 6 hardware test")
            return
        }

        try await capture.simulateInterruption()

        let reason = await Self.firstDeg(stream: stream, timeout: 1.0)
        XCTAssertEqual(reason, .midSessionRevoked,
            "AVCaptureSession.wasInterruptedNotification must yield .midSessionRevoked")

        await capture.shutdown()
    }

    /// Race the next event off the stream against a sleep so the test does
    /// not hang when no event will ever arrive. Mirrors the helper in
    /// `CameraCaptureTCCTests`.
    private static func firstDeg(
        stream: AsyncStream<VisionDegradationReason>,
        timeout: Double
    ) async -> VisionDegradationReason? {
        let collector = Task { () -> VisionDegradationReason? in
            for await reason in stream {
                return reason
            }
            return nil
        }
        let timer = Task { () -> VisionDegradationReason? in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            collector.cancel()
            return nil
        }
        let result = await collector.value
        timer.cancel()
        return result
    }
}
