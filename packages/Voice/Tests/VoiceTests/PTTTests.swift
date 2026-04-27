import XCTest
@testable import Voice

// MARK: - PTTTests
//
// P1: pttDown() from .idle → .listening(source: .ptt)
// P2: pttUp() from .listening(.ptt) finalizes STT session (endSTTSession)
// P3: PTT works when wake-word is muted (VOICE-12 contract)
// P4: pttDown() during .speaking triggers barge-in → .listening(.ptt)
//
// Mocks re-use TestDeps and helpers from VoiceControllerTests.swift (same test target).

final class PTTTests: XCTestCase {

    // MARK: - P1: pttDown from .idle → .listening(source: .ptt)

    func testP1_pttDown_from_idle_transitions_to_listening_ptt() async throws {
        let (controller, deps) = makePTTController()
        await controller.startForTests()

        await controller.pttDown()
        try await Task.sleep(for: .milliseconds(50))

        let state = await controller.state
        guard case .listening(let source) = state else {
            XCTFail("Expected .listening, got \(state)")
            return
        }
        XCTAssertEqual(source, .ptt, "P1: pttDown must produce .listening(source: .ptt)")

        // HUD should also emit .listening
        let intents = deps._hudIntents
        XCTAssertTrue(intents.contains(.listening), "P1: HUD must receive .listening intent")
    }

    // MARK: - P2: pttUp from .listening(.ptt) ends STT session

    func testP2_pttUp_from_listening_ptt_ends_stt_session() async throws {
        let (controller, _) = makePTTController()
        await controller.startForTests()

        // Enter .listening via PTT
        await controller.pttDown()
        try await Task.sleep(for: .milliseconds(50))

        let stateBefore = await controller.state
        guard case .listening(.ptt) = stateBefore else {
            XCTFail("Pre-condition: expected .listening(.ptt), got \(stateBefore)")
            return
        }

        // Release PTT — should end STT session (state goes back toward .idle)
        await controller.pttUp()
        try await Task.sleep(for: .milliseconds(50))

        // After pttUp with no speech, state goes .idle (empty STT result → idle)
        let stateAfter = await controller.state
        // The STT session ends: since MockSTTForController hangs until complete(),
        // after pttUp the stream is closed. finalize() returns "" → .idle.
        // We just verify pttUp doesn't crash and didn't remain in .listening(.ptt).
        // (The controller's sttChunkCont is finished on pttUp; drain task sees close.)
        XCTAssertNotEqual(stateAfter, .listening(source: .ptt),
            "P2: pttUp should end the PTT STT session")
    }

    // MARK: - P3: PTT works when wake-word is muted (VOICE-12)

    func testP3_ptt_works_when_wake_word_muted() async throws {
        let (controller, deps) = makePTTController()
        await controller.startForTests()

        // Mute wake-word
        await controller.muteWakeWord()

        // PTT must still work
        await controller.pttDown()
        try await Task.sleep(for: .milliseconds(50))

        let state = await controller.state
        guard case .listening(let source) = state else {
            XCTFail("P3 (VOICE-12): Expected .listening after pttDown with muted wake-word, got \(state)")
            return
        }
        XCTAssertEqual(source, .ptt,
            "P3 (VOICE-12): PTT must produce .listening(.ptt) even when wake-word is muted")
    }

    // MARK: - P4: pttDown during .speaking triggers barge-in → .listening(.ptt)

    func testP4_pttDown_during_speaking_triggers_bargeIn() async throws {
        let (controller, deps) = makePTTController()
        await controller.startForTests()

        // Force state to .speaking
        await controller._forceState(.speaking)

        await controller.pttDown()
        try await Task.sleep(for: .milliseconds(200))

        // Barge-in: cancelAndSubmit called once
        let cancelCount = await deps.orchestrator.cancelAndSubmitCount
        XCTAssertEqual(cancelCount, 1,
            "P4: pttDown during .speaking must trigger barge-in (cancelAndSubmit once)")

        // State should now be .listening(.ptt)
        let state = await controller.state
        guard case .listening(let source) = state else {
            XCTFail("P4: Expected .listening after barge-in pttDown, got \(state)")
            return
        }
        XCTAssertEqual(source, .ptt,
            "P4: barge-in via PTT must produce .listening(source: .ptt)")
    }
}

// MARK: - PushToTalk bind/unbind unit tests

final class PushToTalkTests: XCTestCase {

    // MARK: - PT1: bind sets isBound

    @MainActor
    func testPT1_bind_sets_isBound() {
        let controller = makeMockController()
        let ptt = PushToTalk(controller: controller)

        XCTAssertFalse(ptt.isBound, "Before bind, isBound must be false")
        ptt.bind(keyCode: 0x31, modifiers: [], inputMonitoringGranted: false)
        XCTAssertTrue(ptt.isBound, "After bind, isBound must be true")
        ptt.unbind()
        XCTAssertFalse(ptt.isBound, "After unbind, isBound must be false")
    }

    // MARK: - PT2: unbind is idempotent (no crash when called multiple times)

    @MainActor
    func testPT2_unbind_is_idempotent() {
        let controller = makeMockController()
        let ptt = PushToTalk(controller: controller)

        ptt.unbind()
        ptt.unbind()
        // No crash — pass
    }
}

// MARK: - Helpers

private func makePTTController() -> (VoiceController, TestDeps) {
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

@MainActor
private func makeMockController() -> VoiceController {
    let (wakeWordStream, _) = AsyncStream<WakeWordEvent>.makeStream()
    let (hudStream, hudCont) = AsyncStream<VoiceHudIntent>.makeStream()
    _ = hudStream
    return VoiceController(
        wakeWordStream: wakeWordStream,
        vadFactory: { SileroVAD(engine: MockVADEngine()) },
        sttFactory: { MockSTTForController() },
        tts: MockTTSForController(),
        orchestrator: MockOrchestratorForController(),
        bannerCoordinator: MockBannerForController(),
        bus: MockBusEmitter(),
        voiceHudCont: hudCont
    )
}
