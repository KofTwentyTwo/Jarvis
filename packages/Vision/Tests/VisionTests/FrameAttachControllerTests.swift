import XCTest
import Foundation
@testable import JarvisVision
import AgentCore

/// Plan 07-05 / Task 6 — FrameAttachController dual-trigger ingest +
/// always-confirm gate + discard-on-turn-complete edge.
final class FrameAttachControllerTests: XCTestCase {

    private let fixtureFrame = CapturedFrame(
        jpegData: Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46]),
        width: 1024,
        height: 768,
        capturedAt: Date()
    )

    // MARK: - Test 1: dual trigger reaches single entry point

    func testPhraseTriggerAndHudButtonReachSameRequestAttach() async throws {
        let capture = FakeCapture(frame: fixtureFrame)
        let sink = FakeReplaySink()
        let controller = FrameAttachController(
            captureSession: capture,
            replaySink: sink,
            config: VisionRouterConfig.default
        )
        // Trigger via phrase
        await controller.requestAttach(reason: .phraseDetected(in: "can you see this"))
        // Trigger via HUD button
        await controller.requestAttach(reason: .hudButton)
        let pending = await controller.hasPendingFrame
        XCTAssertTrue(pending, "second trigger replaces; single-slot semantics")
        let count = await capture.captureCount
        XCTAssertEqual(count, 2, "both triggers reach captureFrame()")
    }

    // MARK: - Test 2: provider never reached without explicit confirm

    func testProviderNotInvokedOnTimeout() async throws {
        let capture = FakeCapture(frame: fixtureFrame)
        let sink = FakeReplaySink()
        var cfg = VisionRouterConfig.default
        cfg.frameConfirmTimeout = .milliseconds(50)
        let controller = FrameAttachController(
            captureSession: capture,
            replaySink: sink,
            config: cfg
        )
        await controller.requestAttach(reason: .hudButton)
        // Wait for the timeout path to fire
        try await Task.sleep(for: .milliseconds(150))
        let decision = await controller.lastDecision
        XCTAssertEqual(decision, .timeout, "default-cancel after timeout")
        let pending = await controller.hasPendingFrame
        XCTAssertFalse(pending, "frame discarded after timeout")
    }

    // MARK: - Test 3: explicit cancel discards

    func testExplicitCancelDiscards() async throws {
        let capture = FakeCapture(frame: fixtureFrame)
        let sink = FakeReplaySink()
        let controller = FrameAttachController(
            captureSession: capture,
            replaySink: sink,
            config: VisionRouterConfig.default
        )
        await controller.requestAttach(reason: .hudButton)
        await controller.cancel()
        let pending = await controller.hasPendingFrame
        XCTAssertFalse(pending, "cancel discards immediately")
        let decision = await controller.lastDecision
        XCTAssertEqual(decision, .cancel)
    }

    // MARK: - Test 4: confirm produces an ImageBlock that routes to provider

    func testConfirmProducesImageBlock() async throws {
        let capture = FakeCapture(frame: fixtureFrame)
        let sink = FakeReplaySink()
        let controller = FrameAttachController(
            captureSession: capture,
            replaySink: sink,
            config: VisionRouterConfig.default
        )
        await controller.requestAttach(reason: .phraseDetected(in: "can you see this"))
        let imageBlock = await controller.confirmSend(userText: "what is this")
        XCTAssertNotNil(imageBlock, "confirmSend produces an ImageBlock")
        XCTAssertEqual(imageBlock?.mediaType, "image/jpeg")
        XCTAssertEqual(imageBlock?.data, fixtureFrame.jpegData)
        let decision = await controller.lastDecision
        XCTAssertEqual(decision, .send)
        // Replay sink should have recorded a placeholder for this turn
        let recorded = await sink.recordedPlaceholders
        XCTAssertEqual(recorded.count, 1)
    }

    // MARK: - Test 5: assistant-turn-complete edge discards

    func testOnAssistantTurnCompleteDiscardsFrame() async throws {
        let capture = FakeCapture(frame: fixtureFrame)
        let sink = FakeReplaySink()
        let controller = FrameAttachController(
            captureSession: capture,
            replaySink: sink,
            config: VisionRouterConfig.default
        )
        await controller.requestAttach(reason: .hudButton)
        _ = await controller.confirmSend(userText: "describe")
        // After send, pendingFrame is still tracked until the assistant
        // finishes streaming. Calling onAssistantTurnComplete clears it.
        await controller.onAssistantTurnComplete()
        let pending = await controller.hasPendingFrame
        XCTAssertFalse(pending, "discardFrame on assistant-turn-complete edge")
        // Subsequent calls are no-op (idempotent).
        await controller.onAssistantTurnComplete()
        let stillFalse = await controller.hasPendingFrame
        XCTAssertFalse(stillFalse)
    }

    // MARK: - Test 6: rejected-submit release path (#2)

    /// Audit 2026-05-12 F-V2 — when `confirmSend` produced an ImageBlock but
    /// the orchestrator returned `.rejected`, the controller must release the
    /// frame on demand. Without `releaseAfterRejectedSubmit()` the JPEG bytes
    /// would sit in actor memory until the next `requestAttach` overwrites
    /// them — privacy regression on the D-15 byte-release window.
    func testReleaseAfterRejectedSubmitClearsPendingFrame() async throws {
        let capture = FakeCapture(frame: fixtureFrame)
        let sink = FakeReplaySink()
        let controller = FrameAttachController(
            captureSession: capture,
            replaySink: sink,
            config: VisionRouterConfig.default
        )
        await controller.requestAttach(reason: .hudButton)
        let block = await controller.confirmSend(userText: "what is this")
        XCTAssertNotNil(block, "confirmSend should have produced an ImageBlock")
        // After confirmSend the slot is still populated by design — the
        // assistant-turn-complete edge would normally release it. Simulate a
        // rejected submit (no .turnEnd will ever fire) and assert the
        // dedicated release entry point clears the slot.
        let stillPending = await controller.hasPendingFrame
        XCTAssertTrue(stillPending, "confirmSend keeps the slot populated until release")
        await controller.releaseAfterRejectedSubmit()
        let pending = await controller.hasPendingFrame
        XCTAssertFalse(pending, "releaseAfterRejectedSubmit must clear pendingFrame")
        // Idempotent.
        await controller.releaseAfterRejectedSubmit()
        let stillFalse = await controller.hasPendingFrame
        XCTAssertFalse(stillFalse)
    }
}

// MARK: - Test fakes

private actor FakeCapture: FrameAttachController.CaptureSource {
    let frame: CapturedFrame
    var captureCount: Int = 0

    init(frame: CapturedFrame) {
        self.frame = frame
    }

    func captureFrame() async throws -> CapturedFrame {
        captureCount += 1
        return frame
    }
}

private actor FakeReplaySink: FrameAttachController.ReplaySink {
    var recordedPlaceholders: [Data] = []
    func recordImageTurn(text: String) async {
        let payload = "{\"type\":\"image\",\"discarded\":true,\"text\":\"\(text)\"}"
        recordedPlaceholders.append(Data(payload.utf8))
    }
}
