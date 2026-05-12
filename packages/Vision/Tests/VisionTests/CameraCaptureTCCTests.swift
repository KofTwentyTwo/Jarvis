import XCTest
import AVFoundation
@testable import JarvisVision

final class CameraCaptureTCCTests: XCTestCase {

    func testTCCDeniedYieldsDegradationAndThrows() async throws {
        let (stream, cont) = AsyncStream<VisionDegradationReason>.makeStream()
        let capture = CameraCapture(degradationContinuation: cont, degradationStream: stream)
        await capture.setAuthStatusProbe { .denied }

        do {
            try await capture.open()
            XCTFail("Expected VisionError.tccDenied")
        } catch VisionError.tccDenied {
            // Pass — also assert degradation banner fired.
        } catch {
            XCTFail("Wrong error: \(error)")
        }

        let reason = await Self.firstDeg(stream: stream, timeout: 0.3)
        XCTAssertEqual(reason, .cameraDenied)
        await capture.shutdown()
    }

    func testTCCNotDeterminedThrowsWithoutDegradationBanner() async throws {
        let (stream, cont) = AsyncStream<VisionDegradationReason>.makeStream()
        let capture = CameraCapture(degradationContinuation: cont, degradationStream: stream)
        await capture.setAuthStatusProbe { .notDetermined }

        do {
            try await capture.open()
            XCTFail("Expected VisionError.tccNotDetermined")
        } catch VisionError.tccNotDetermined {
            // Pass.
        } catch {
            XCTFail("Wrong error: \(error)")
        }

        let reason = await Self.firstDeg(stream: stream, timeout: 0.3)
        XCTAssertNil(reason, "notDetermined must NOT raise a graceful-denial banner — caller is expected to request access.")
        await capture.shutdown()
    }

    /// Audit 2026-05-12 F-V3 — `becameAuthorized()` is the re-grant entry
    /// point AppDelegate's foreground TCC re-check calls when the user
    /// flips camera permission `.denied → .authorized` via System Settings.
    /// Before the fix, this method had zero non-doc callsites in production
    /// (grep returned nothing outside its own declaration), so a re-grant
    /// after first-launch denial never reopened the session. The
    /// AppDelegate-side wiring is exercised by host integration; this test
    /// covers the Vision-side contract: after the auth probe flips to
    /// .authorized, calling becameAuthorized() opens the session
    /// successfully.
    func testBecameAuthorizedOpensSessionAfterRegrant() async throws {
        // Class-backed status box so the @Sendable probe can read the
        // latest value (simulating the user flipping permission in
        // System Settings between calls without needing an actor hop).
        final class StatusBox: @unchecked Sendable {
            private let lock = NSLock()
            private var value: AVAuthorizationStatus
            init(_ v: AVAuthorizationStatus) { self.value = v }
            func read() -> AVAuthorizationStatus { lock.lock(); defer { lock.unlock() }; return value }
            func write(_ v: AVAuthorizationStatus) { lock.lock(); defer { lock.unlock() }; value = v }
        }
        let box = StatusBox(.denied)

        let (stream, cont) = AsyncStream<VisionDegradationReason>.makeStream()
        let capture = CameraCapture(degradationContinuation: cont, degradationStream: stream)
        await capture.setAuthStatusProbe { box.read() }

        do {
            try await capture.open()
            XCTFail("Expected VisionError.tccDenied on first open")
        } catch VisionError.tccDenied {
            // Expected — first-launch denial.
        }

        // Flip the probe — user granted via Settings.
        box.write(.authorized)
        do {
            try await capture.becameAuthorized()
        } catch VisionError.noCameraDevice {
            try XCTSkipIf(true, "no camera device available — see Track-C 6 hardware test")
            return
        } catch {
            XCTFail("becameAuthorized() threw after re-grant: \(error)")
        }

        await capture.shutdown()
        _ = stream
    }

    func testCaptureFrameThrowsWhenSessionNotRunning() async throws {
        let (stream, cont) = AsyncStream<VisionDegradationReason>.makeStream()
        let capture = CameraCapture(degradationContinuation: cont, degradationStream: stream)
        // Never call open().
        do {
            _ = try await capture.captureFrame()
            XCTFail("Expected VisionError.sessionNotRunning")
        } catch VisionError.sessionNotRunning {
            // Pass.
        } catch {
            XCTFail("Wrong error: \(error)")
        }
        await capture.shutdown()
        // Drain any spurious yields so the stream can finish.
        _ = stream
    }

    /// Race the next event off the stream against a sleep so the test does
    /// not hang when no event will ever arrive.
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

extension CameraCapture {
    /// Test helper to set the auth-status probe from non-isolated test contexts.
    /// Mirrors AudioGraphOwner test setup.
    func setAuthStatusProbe(_ probe: @escaping @Sendable () -> AVAuthorizationStatus) {
        self.authStatusProbe = probe
    }
}
