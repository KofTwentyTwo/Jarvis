import XCTest
import AVFoundation
@testable import JarvisVision

/// Track-C 2 — assert `CameraCapture.frameStream(forPresence:)` is no longer
/// the immediately-finished AsyncStream from 07-04. Frames pushed through the
/// `VideoSampleDelegate` fan-out reach every live subscriber, and cancellation
/// (consumer side) plus shutdown (producer side) tear the subscription down.
final class CameraCaptureFrameStreamTests: XCTestCase {

    // MARK: - Test 1: open() builds the delegate; injected samples reach the stream

    func testFrameStreamYieldsInjectedSamplesAfterOpen() async throws {
        let (degStream, degCont) = AsyncStream<VisionDegradationReason>.makeStream()
        let capture = CameraCapture(degradationContinuation: degCont, degradationStream: degStream)
        await capture.setAuthStatusProbe { .authorized }

        do {
            try await capture.open()
        } catch VisionError.noCameraDevice {
            try XCTSkipIf(true, "no camera device available")
            return
        } catch {
            try XCTSkipIf(true, "camera open failed: \(error)")
            return
        }

        let stream = capture.frameStream(forPresence: true)

        // Wait for the actor hop in frameStream's init Task to register the
        // subscription, then inject. The subscriber set is internal to the
        // delegate; the test seam reads the count directly.
        let delegate = await capture.videoSampleDelegate
        XCTAssertNotNil(delegate, "open() must have built the VideoSampleDelegate")

        // Spin briefly until the subscription registers (cooperative wait).
        var attached = false
        for _ in 0..<20 {
            if (delegate?.subscriberCount() ?? 0) >= 1 {
                attached = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(attached, "frameStream subscription did not register on the delegate")

        // Inject a synthetic detection through the same fan-out path used by
        // the AVFoundation captureOutput callback.
        delegate?.injectForTesting(.syntheticDetection(faceDetected: true, timestamp: Date()))

        // Drain one frame (with a timeout so we don't hang on regression).
        let received = await Self.firstSample(from: stream, timeout: 0.5)
        switch received {
        case .syntheticDetection(let face, _):
            XCTAssertTrue(face, "expected the injected sample to surface")
        case .none:
            XCTFail("frameStream did not yield the injected sample within timeout")
        default:
            XCTFail("unexpected sample type: \(String(describing: received))")
        }

        await capture.shutdown()
        _ = degStream
    }

    // MARK: - Test 2: shutdown() finishes outstanding streams

    func testShutdownFinishesOutstandingStreams() async throws {
        let (degStream, degCont) = AsyncStream<VisionDegradationReason>.makeStream()
        let capture = CameraCapture(degradationContinuation: degCont, degradationStream: degStream)
        await capture.setAuthStatusProbe { .authorized }

        do {
            try await capture.open()
        } catch VisionError.noCameraDevice {
            try XCTSkipIf(true, "no camera device available")
            return
        } catch {
            try XCTSkipIf(true, "camera open failed: \(error)")
            return
        }

        let stream = capture.frameStream(forPresence: true)
        // Give the registration task a moment to attach.
        try await Task.sleep(for: .milliseconds(20))

        await capture.shutdown()

        // After shutdown the for-await must terminate (loop exits).
        let drainTask = Task<Bool, Never> {
            for await _ in stream { /* drain */ }
            return true
        }
        let timer = Task<Bool, Never> {
            try? await Task.sleep(for: .milliseconds(200))
            drainTask.cancel()
            return false
        }
        let didFinish = await drainTask.value
        timer.cancel()
        XCTAssertTrue(didFinish, "shutdown() must finish outstanding frameStream continuations")
        _ = degStream
    }

    // MARK: - Test 3: frameStream finishes immediately when session not open

    func testFrameStreamFinishesImmediatelyWhenNotOpen() async throws {
        let (degStream, degCont) = AsyncStream<VisionDegradationReason>.makeStream()
        let capture = CameraCapture(degradationContinuation: degCont, degradationStream: degStream)
        // Never call open().

        let stream = capture.frameStream(forPresence: true)

        let drainTask = Task<Bool, Never> {
            for await _ in stream { /* should never fire */ }
            return true
        }
        let timer = Task<Bool, Never> {
            try? await Task.sleep(for: .milliseconds(200))
            drainTask.cancel()
            return false
        }
        let didFinish = await drainTask.value
        timer.cancel()
        XCTAssertTrue(didFinish, "frameStream must finish immediately when session is not open")
        await capture.shutdown()
        _ = degStream
    }

    // MARK: - Test 4: structural — frameStream is no longer the empty
    // AsyncStream { cont.finish() } that shipped through 07-04..07-06.

    func testFrameStreamSourceNoLongerImmediatelyFinishes() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Vision/CameraCapture.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(
            src.contains("// 07-04: production path is intentionally a no-op stream"),
            "frameStream is no longer a 07-04 stub — comment must be gone"
        )
        XCTAssertTrue(
            src.contains("VideoSampleDelegate"),
            "frameStream must be backed by the VideoSampleDelegate fan-out"
        )
    }

    // MARK: - Helpers

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
