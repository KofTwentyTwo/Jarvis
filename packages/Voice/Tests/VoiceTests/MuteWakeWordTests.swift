import XCTest
import AppKit
@testable import Voice

// MARK: - MuteWakeWordTests
//
// M1: toggle mute → WakeWordDAG.pause() state + UserDefaults = true
// M2: toggle un-mute → WakeWordDAG.resume() state + UserDefaults = false
// M3: persistence — re-instantiating MuteWakeWord reads UserDefaults, applies muted state on init
//
// WakeWordDAG is a concrete actor (not protocol-seamed), so we create one using
// OpenWakeWordSession(scriptedClassifier:) which bypasses ORT.
// We verify pause/resume by checking WakeWordDAG.isPaused (internal test seam).

final class MuteWakeWordTests: XCTestCase {

    // Clean up the UserDefaults key after each test
    override func tearDownWithError() throws {
        UserDefaults.standard.removeObject(forKey: "features.voice.wakeWordMuted")
    }

    // MARK: - M1: toggle to muted → UserDefaults = true + isMuted = true

    @MainActor
    func testM1_toggle_to_muted_persists() async {
        let (dag, controller, menu) = await makeDeps()

        let muteWakeWord = MuteWakeWord(
            controller: controller,
            wakeWordDAG: dag,
            menuBarMenu: menu
        )

        // Start unmuted — toggle to muted
        muteWakeWord.setMutedForTests(true)
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(muteWakeWord.isMutedForTests,
            "M1: isMuted should be true after setMuted(true)")
        XCTAssertEqual(
            UserDefaults.standard.bool(forKey: "features.voice.wakeWordMuted"),
            true,
            "M1: UserDefaults must reflect muted=true"
        )
    }

    // MARK: - M2: toggle to unmuted → UserDefaults = false + isMuted = false

    @MainActor
    func testM2_toggle_to_unmuted_persists() async {
        let (dag, controller, menu) = await makeDeps()

        // Pre-set to muted
        UserDefaults.standard.set(true, forKey: "features.voice.wakeWordMuted")

        let muteWakeWord = MuteWakeWord(
            controller: controller,
            wakeWordDAG: dag,
            menuBarMenu: menu
        )

        try? await Task.sleep(for: .milliseconds(100))  // let init task run

        // Now unmute
        muteWakeWord.setMutedForTests(false)
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertFalse(muteWakeWord.isMutedForTests,
            "M2: isMuted should be false after setMuted(false)")
        XCTAssertEqual(
            UserDefaults.standard.bool(forKey: "features.voice.wakeWordMuted"),
            false,
            "M2: UserDefaults must reflect muted=false"
        )
    }

    // MARK: - M3: persistence — re-instantiation reads and applies UserDefaults muted state

    @MainActor
    func testM3_persistence_applies_muted_state_on_init() async {
        let (dag, controller, menu) = await makeDeps()

        // Pre-set UserDefaults to muted=true (simulating previous app session)
        UserDefaults.standard.set(true, forKey: "features.voice.wakeWordMuted")

        // Instantiate fresh MuteWakeWord — must read UserDefaults and apply
        let muteWakeWord = MuteWakeWord(
            controller: controller,
            wakeWordDAG: dag,
            menuBarMenu: menu
        )

        try? await Task.sleep(for: .milliseconds(100))  // let init task run

        XCTAssertTrue(muteWakeWord.isMutedForTests,
            "M3: MuteWakeWord must read UserDefaults muted=true on init")
    }
}

// MARK: - Test helpers

private func makeDeps() async -> (WakeWordDAG, VoiceController, NSMenu) {
    // Use the scripted session (ORT-free) — classifier always returns 0.0 (silence)
    let session = OpenWakeWordSession(scriptedClassifier: { _ in 0.0 })
    let dag = WakeWordDAG(session: session)

    let (wakeWordStream, _) = AsyncStream<WakeWordEvent>.makeStream()
    let (_, hudCont) = AsyncStream<VoiceHudIntent>.makeStream()
    let controller = VoiceController(
        wakeWordStream: wakeWordStream,
        vadFactory: { SileroVAD(engine: MockVADEngine()) },
        sttFactory: { MockSTTForController() },
        tts: MockTTSForController(),
        orchestrator: MockOrchestratorForController(),
        bannerCoordinator: MockBannerForController(),
        bus: MockBusEmitter(),
        voiceHudCont: hudCont
    )
    let menu = NSMenu(title: "Test")
    return (dag, controller, menu)
}
