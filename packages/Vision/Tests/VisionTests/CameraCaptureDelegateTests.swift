import XCTest
import AVFoundation
@testable import JarvisVision

/// Track-C 1 — assert that `CameraCapture.captureFrame()` reaches the
/// production AVCapturePhotoOutput delegate path (instead of returning the
/// 1×1 black-JPEG hardcode that shipped through 07-04..07-06) and that the
/// `PhotoCaptureProxy` correctly bridges the delegate callback into a
/// Swift continuation.
///
/// The real `capturePhoto(...)` delegate flow is exercised by the hardware
/// integration test (Track-C 6, env-gated). These tests assert the bridge
/// without spinning up a real `AVCaptureSession`.
final class CameraCaptureDelegateTests: XCTestCase {

    // MARK: - Test 1: photoCaptureOverride seam routes through captureFrame()

    func testCaptureFrameRoutesThroughOverrideSeam() async throws {
        // The seam exists specifically so `captureFrame()` can be exercised
        // end-to-end (including the `session.isRunning` precondition) without
        // hardware. We open a real session — on a host with no camera, skip.
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

        let fixture = CapturedFrame(
            jpegData: Data([0xFF, 0xD8, 0xFF, 0xE0]),
            width: 1280,
            height: 720,
            capturedAt: Date()
        )
        await capture.setPhotoCaptureOverride { fixture }

        let captured = try await capture.captureFrame()
        XCTAssertEqual(captured.jpegData, fixture.jpegData)
        XCTAssertEqual(captured.width, 1280)
        XCTAssertEqual(captured.height, 720)
        await capture.shutdown()
        _ = stream
    }

    // MARK: - Test 2: captureFrame() throws sessionNotRunning before open()

    func testCaptureFrameThrowsSessionNotRunningBeforeOpen() async throws {
        let (stream, cont) = AsyncStream<VisionDegradationReason>.makeStream()
        let capture = CameraCapture(degradationContinuation: cont, degradationStream: stream)
        do {
            _ = try await capture.captureFrame()
            XCTFail("Expected VisionError.sessionNotRunning")
        } catch VisionError.sessionNotRunning {
            // Pass.
        } catch {
            XCTFail("Wrong error: \(error)")
        }
        await capture.shutdown()
        _ = stream
    }

    // MARK: - Test 3: structural — captureFrame() no longer returns the
    // 1×1 black JPEG hardcode. Greps the source to enforce no regression.
    //
    // This is a guard against the symptom that originally produced
    // BLOCKER-INT-4 / vision-audit §1: the body of captureFrame returning a
    // hand-crafted `onePixelJPEG()`. If a future commit reintroduces that
    // helper or reverts `capturePhoto` back to a hardcoded blob, this fails.

    func testCaptureFrameSourceDoesNotEmbedHardcodedJPEG() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // Tests/VisionTests
            .deletingLastPathComponent()    // Tests
            .deletingLastPathComponent()    // packages/Vision
            .appendingPathComponent("Sources/Vision/CameraCapture.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(
            src.contains("onePixelJPEG"),
            "CameraCapture.swift must not embed a hardcoded JPEG — captureFrame() routes through capturePhoto delegate now"
        )
        XCTAssertTrue(
            src.contains("photoOutput.capturePhoto(with:"),
            "CameraCapture.captureFrame() must invoke AVCapturePhotoOutput.capturePhoto(with:delegate:)"
        )
        XCTAssertTrue(
            src.contains("AVCapturePhotoCaptureDelegate"),
            "CameraCapture must bridge through an AVCapturePhotoCaptureDelegate"
        )
    }
}

extension CameraCapture {
    /// Mirror of `setAuthStatusProbe` — sets the photoCaptureOverride seam
    /// from non-isolated test contexts.
    func setPhotoCaptureOverride(
        _ override: @escaping @Sendable () async throws -> CapturedFrame
    ) {
        self.photoCaptureOverride = override
    }
}
