import XCTest
@testable import JarvisVision
import AgentCore

/// Track-C 5 — `FrameAttachController.confirmSend(...)` is no longer
/// orphaned. Closes vision-audit §4 "`confirmSend` has zero non-test
/// callers in the entire codebase".
///
/// AppDelegate's chat-submit handlers now consult the controller for a
/// pending frame and, when present, route the resulting `ImageBlock`
/// through `AgentOrchestrator.submit(.withImages(...))`. These tests are
/// structural — they grep AppDelegate.swift to enforce the wiring exists.
/// The behavioural assertions on confirmSend's return value are exercised
/// by `FrameAttachControllerTests.testConfirmProducesImageBlock`.
final class FrameAttachConfirmSendWiringTests: XCTestCase {

    func testAppDelegateCallsConfirmSendInChatSubmitPath() throws {
        let url = appDelegateURL()
        let src = try String(contentsOf: url, encoding: .utf8)

        // The wiring must exist in BOTH chat-submit paths (chatSubmit AND
        // chatCancelAndSubmit) — without that, a barge-in after the camera
        // button is pressed silently drops the frame (the WARNING-4
        // pattern that already applied to phrase triggers).
        XCTAssertTrue(
            src.contains("consumePendingFrameIfAny"),
            "AppDelegate must consume the pending frame from FrameAttachController before submit"
        )
        XCTAssertTrue(
            src.contains("confirmSend(userText:"),
            "AppDelegate must invoke FrameAttachController.confirmSend(userText:) — Track-C 5 wiring"
        )
        XCTAssertTrue(
            src.contains(".withImages(.text, text: text, images: [imageBlock])"),
            "AppDelegate must route the confirmed frame through TurnInput.withImages(...)"
        )
    }

    func testConfirmSendIsReachableFromBothChatHandlers() throws {
        let url = appDelegateURL()
        let src = try String(contentsOf: url, encoding: .utf8)

        // Count occurrences — both handlers (handleChatSubmit AND
        // handleChatCancelAndSubmit) must call the helper, mirroring the
        // existing WARNING-4 pattern for tryPhraseAttachIfMatch.
        let occurrences = src.components(separatedBy: "consumePendingFrameIfAny(userText:").count - 1
        XCTAssertGreaterThanOrEqual(
            occurrences,
            2,
            "consumePendingFrameIfAny must be called from BOTH handleChatSubmit AND handleChatCancelAndSubmit (got \(occurrences) occurrences)"
        )
    }

    /// confirmSend's behaviour itself stays covered by
    /// FrameAttachControllerTests.testConfirmProducesImageBlock. This test
    /// re-asserts the contract that AppDelegate's wiring depends on:
    /// confirmSend returns nil when nothing is pending, and an ImageBlock
    /// when a frame is armed.
    func testConfirmSendNilWhenNothingPending() async throws {
        struct StubCapture: FrameAttachController.CaptureSource {
            func captureFrame() async throws -> CapturedFrame {
                XCTFail("captureFrame must not be called when no requestAttach armed it")
                return CapturedFrame(jpegData: Data(), width: 0, height: 0, capturedAt: Date())
            }
        }
        actor StubSink: FrameAttachController.ReplaySink {
            func recordImageTurn(text: String) async {}
        }
        let controller = FrameAttachController(
            captureSession: StubCapture(),
            replaySink: StubSink(),
            config: .default
        )
        let block = await controller.confirmSend(userText: "hi")
        XCTAssertNil(block, "confirmSend must return nil when no frame is pending")
    }

    // MARK: - Helpers

    private func appDelegateURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // Tests/VisionTests
            .deletingLastPathComponent()    // Tests
            .deletingLastPathComponent()    // packages/Vision
            .deletingLastPathComponent()    // packages
            .deletingLastPathComponent()    // repo root
            .appendingPathComponent("App/AppDelegate.swift")
    }
}
