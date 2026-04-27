import XCTest
@testable import Voice

// MARK: - AECFallbackBannerTests
//
// F1: VoiceController.handleAECUnavailable() → banner shown with AEC message (VOICE-09)
// F2: VoiceController.handleAECRestored() after handleAECUnavailable → banner dismissed
//
// VOICE-09: AEC banner uses AppKit path (VoiceBannerInterface). No webview modal.
// The modal-lint gate (Phase 5) enforces no NSAlert/runModal in the Voice package.

final class AECFallbackBannerTests: XCTestCase {

    // MARK: - F1: AEC unavailable → banner shown with correct message

    func testF1_aec_unavailable_shows_banner() async throws {
        let banner = MockBannerForController()
        let controller = makeBannerController(banner: banner)
        await controller.startForTests()

        await controller.handleAECUnavailable()

        XCTAssertEqual(banner.shownMessages.count, 1,
            "F1: showBanner must be called exactly once on AEC unavailable")
        XCTAssertEqual(banner.shownMessages.first,
            "AEC unavailable; degraded-mode active",
            "F1: banner message must match VOICE-09 specification")
        XCTAssertEqual(banner.dismissCalls, 0,
            "F1: banner must not be dismissed on first unavailability")
    }

    // MARK: - F2: AEC restored → banner dismissed

    func testF2_aec_restored_dismisses_banner() async throws {
        let banner = MockBannerForController()
        let controller = makeBannerController(banner: banner)
        await controller.startForTests()

        // First trigger unavailable
        await controller.handleAECUnavailable()
        XCTAssertEqual(banner.shownMessages.count, 1, "F2 pre-condition: banner shown")

        // Now restore
        await controller.handleAECRestored()

        XCTAssertEqual(banner.dismissCalls, 1,
            "F2: dismissBanner must be called once on AEC restored")
    }

    // MARK: - F1b: idempotency — calling handleAECUnavailable twice shows banner once

    func testF1b_aec_unavailable_is_idempotent() async throws {
        let banner = MockBannerForController()
        let controller = makeBannerController(banner: banner)
        await controller.startForTests()

        await controller.handleAECUnavailable()
        await controller.handleAECUnavailable()  // second call must be no-op

        XCTAssertEqual(banner.shownMessages.count, 1,
            "F1b: showBanner must be called exactly once (idempotent)")
    }
}

// MARK: - Helpers

private func makeBannerController(banner: MockBannerForController) -> VoiceController {
    let (wakeWordStream, _) = AsyncStream<WakeWordEvent>.makeStream()
    let (_, hudCont) = AsyncStream<VoiceHudIntent>.makeStream()
    return VoiceController(
        wakeWordStream: wakeWordStream,
        vadFactory: { SileroVAD(engine: MockVADEngine()) },
        sttFactory: { MockSTTForController() },
        tts: MockTTSForController(),
        orchestrator: MockOrchestratorForController(),
        bannerCoordinator: banner,
        bus: MockBusEmitter(),
        voiceHudCont: hudCont
    )
}
