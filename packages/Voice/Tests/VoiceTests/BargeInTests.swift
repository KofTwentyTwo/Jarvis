import XCTest
@testable import Voice

// MARK: - BargeInTests
//
// B1: wake-word during .speaking calls cancelAndSubmit EXACTLY ONCE (VOICE-14)
// B2: wake-word during .speaking → VoiceHudIntent.listening within 150ms
// B3: cancelAndSubmit records the barge-in sentinel (empty string)
// B4: rapid double barge-in (50ms apart) → debounced, cancelAndSubmit runs once
//
// Mocks are defined in VoiceControllerTests.swift (same test target).

final class BargeInTests: XCTestCase {

    // MARK: - B1: single cancelAndSubmit on barge-in (VOICE-14)

    func testB1_bargeIn_calls_cancelAndSubmit_exactly_once() async throws {
        let (controller, deps) = makeBargeInController()
        await controller.startForTests()

        // Force state to .speaking
        await controller._forceState(.speaking)

        // Fire wake-word during .speaking
        deps.wakeWordCont.yield(.fired(at: Date()))
        try await Task.sleep(for: .milliseconds(200))

        let count = await deps.orchestrator.cancelAndSubmitCount
        XCTAssertEqual(count, 1,
            "cancelAndSubmit must be called EXACTLY ONCE per barge-in (VOICE-14)")
    }

    // MARK: - B2: HUD transitions to .listening on barge-in within 150ms

    func testB2_bargeIn_hud_transitions_to_listening() async throws {
        let (controller, deps) = makeBargeInController()
        await controller.startForTests()

        await controller._forceState(.speaking)
        deps.wakeWordCont.yield(.fired(at: Date()))
        try await Task.sleep(for: .milliseconds(150))

        let state = await controller.state
        guard case .listening = state else {
            XCTFail("Expected .listening after barge-in, got \(state)")
            return
        }

        let intents = deps._hudIntents
        XCTAssertTrue(intents.contains(.listening),
            "HUD must receive .listening intent during barge-in (B2)")
    }

    // MARK: - B3: cancelAndSubmit called with barge-in sentinel (empty string)

    func testB3_bargeIn_uses_empty_sentinel() async throws {
        let (controller, deps) = makeBargeInController()
        await controller.startForTests()

        await controller._forceState(.speaking)
        deps.wakeWordCont.yield(.fired(at: Date()))
        try await Task.sleep(for: .milliseconds(200))

        let capturedTexts = await deps.orchestrator.capturedCancelAndSubmitTexts
        XCTAssertFalse(capturedTexts.isEmpty, "cancelAndSubmit should have been called")
        // Sentinel value is empty string (barge-in displacement signal, plan §292)
        XCTAssertEqual(capturedTexts.first, "",
            "Barge-in sentinel must be empty string")
    }

    // MARK: - B4: rapid double barge-in → debounced (200ms window)

    func testB4_rapid_double_bargeIn_debounced() async throws {
        let (controller, deps) = makeBargeInController()
        await controller.startForTests()

        await controller._forceState(.speaking)

        // Fire two wake-word events 50ms apart
        deps.wakeWordCont.yield(.fired(at: Date()))
        try await Task.sleep(for: .milliseconds(50))
        // After first fire, state is already .listening — second is a no-op
        deps.wakeWordCont.yield(.fired(at: Date()))
        try await Task.sleep(for: .milliseconds(300))

        let count = await deps.orchestrator.cancelAndSubmitCount
        XCTAssertEqual(count, 1,
            "B4 debounce: second wake-word during .listening must not call cancelAndSubmit again")
    }
}

// MARK: - Helpers

private func makeBargeInController() -> (VoiceController, TestDeps) {
    let deps = TestDeps()
    let controller = VoiceController(
        wakeWordStream: deps.wakeWordStream,
        vadFactory: { SileroVAD(engine: MockVADEngine()) },
        sttFactory: { deps.sttProvider },
        tts: deps.tts,
        orchestrator: deps.orchestrator,
        bannerCoordinator: deps.banner,
        bus: deps.bus,
        voiceHudCont: deps.hudCont
    )
    return (controller, deps)
}
