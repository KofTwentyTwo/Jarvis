import XCTest
@testable import Jarvis
@testable import Voice
@testable import Keychain
@testable import Config

// MARK: - VoiceWiringTests
//
// W1: AppDelegate has strong properties for voice subsystem instances
// W2: dormantVoiceContinuation is replaced (nil) when VoiceController is wired
// W3: MenuBarIconController.contextMenu is public (accessible for MuteWakeWord)
// W4: VoiceController can be constructed and started without crashing

@MainActor
final class VoiceWiringTests: XCTestCase {

    // MARK: - Helpers

    private struct EntitlementYes: EntitlementGateProbe { func isVerified() -> Bool { true } }
    private struct FakeKeychain: KeychainStore {
        func set(_ value: String, for item: KeychainItem) throws {}
        func get(_ item: KeychainItem) throws -> String { "fake-key" }
        func delete(_ item: KeychainItem) throws {}
    }
    private struct FakeHIDProbe: HIDAccessProbe {
        func requestListenEventAccess() -> Bool { true }
    }

    private func makeSnapshots() -> (LaunchSnapshot, PerTurnSnapshot) {
        let launchJSON = """
        {"schemaVersion":1,"ollama":{"baseURL":"http://127.0.0.1:11434"},"applescript":{"confirmationRequired":true},"toolBlocklist":[],"confirmationPolicy":{"timeoutSeconds":60},"logging":{"fileLevel":"info","osLogLevel":"info"}}
        """.data(using: .utf8)!
        let perTurnJSON = """
        {"schemaVersion":1,"provider":"anthropic","tts":{"tier":"tier1"},"stt":{"whisperKitFallback":false},"featureFlags":{}}
        """.data(using: .utf8)!
        return (
            try! JSONDecoder().decode(LaunchSnapshot.self, from: launchJSON),
            try! JSONDecoder().decode(PerTurnSnapshot.self, from: perTurnJSON)
        )
    }

    private func makeDelegate() -> AppDelegate {
        let delegate = AppDelegate()
        delegate.entitlementProbe = EntitlementYes()
        delegate.configLoader = { _ in self.makeSnapshots() }
        delegate.configWriter = { _ in self.makeSnapshots() }
        delegate.keychainStore = FakeKeychain()
        delegate.hidProbe = FakeHIDProbe()
        delegate.loggingBootstrap = {}
        return delegate
    }

    private func cleanUp(_ delegate: AppDelegate) {
        if let item = delegate.statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        delegate.wizardController?.close()
        delegate.voiceInstallTask?.cancel()
    }

    // MARK: - W1: AppDelegate has strong voice subsystem properties

    func testW1_appDelegate_has_voice_subsystem_properties() {
        let delegate = AppDelegate()
        // Properties must exist (type-level check)
        // voiceController is nil before installVoice runs
        XCTAssertNil(delegate.voiceController,
            "W1: voiceController should be nil before install")
        XCTAssertNil(delegate.pushToTalk,
            "W1: pushToTalk should be nil before install")
        XCTAssertNil(delegate.muteWakeWord,
            "W1: muteWakeWord should be nil before install")
        XCTAssertNil(delegate.voiceInstallTask,
            "W1: voiceInstallTask should be nil before launch")
        // Track B-4: AudioGraphOwner + degradation/rebuild consumer tasks
        // must exist as strong properties so they outlive installVoice().
        XCTAssertNil(delegate.audioGraphOwner,
            "W1/B-4: audioGraphOwner should be nil before install")
        XCTAssertNil(delegate.audioGraphDegradationTask,
            "W1/B-4: audioGraphDegradationTask should be nil before install")
        XCTAssertNil(delegate.audioGraphRebuildTask,
            "W1/B-4: audioGraphRebuildTask should be nil before install")
    }

    // MARK: - W2: dormantVoiceContinuation is alive after installBus (before voice install)

    func testW2_dormant_voice_continuation_alive_after_bus_install() {
        let delegate = makeDelegate()
        defer { cleanUp(delegate) }

        delegate.applicationWillFinishLaunching(Notification(name: NSApplication.willFinishLaunchingNotification))
        // After applicationWillFinishLaunching, dormantVoiceContinuation should be set
        // (voiceInstallTask is in-flight but hasn't replaced it yet — model files absent in test)
        XCTAssertNotNil(delegate.dormantVoiceContinuation,
            "W2: dormantVoiceContinuation should be alive after installBus (voice install may still be pending)")
    }

    // MARK: - W3: MenuBarIconController.contextMenu is publicly accessible

    func testW3_menuBarIconController_contextMenu_is_public() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(statusItem) }

        let menu = NSMenu(title: "Test")
        let controller = MenuBarIconController(statusItem: statusItem, contextMenu: menu)

        // contextMenu must be public (compile-time check that property is accessible)
        let accessedMenu: NSMenu = controller.contextMenu
        XCTAssertEqual(accessedMenu.title, "Test",
            "W3: contextMenu must be publicly readable for MuteWakeWord wiring")
    }

    // MARK: - W4: VoiceController can be constructed with adapters and started

    func testW4_voiceController_constructs_and_starts() async {
        let (wakeWordStream, _) = AsyncStream<WakeWordEvent>.makeStream()
        let (_, hudCont) = AsyncStream<VoiceHudIntent>.makeStream()

        let vc = VoiceController(
            wakeWordStream: wakeWordStream,
            vadFactory: { SileroVAD(engine: StubVADEngineForW4()) },
            sttFactory: { StubSTTProviderForW4() },
            tts: StubTTSForW4(),
            orchestrator: StubOrchestratorForW4(),
            bannerCoordinator: StubBannerForW4(),
            bus: StubBusForW4(),
            voiceHudCont: hudCont
        )

        // Should not crash
        await vc.start()
        let state = await vc.state
        XCTAssertEqual(state, .idle,
            "W4: VoiceController should be in .idle state after start")

        await vc.shutdown()
    }
}

// MARK: - Minimal stubs for W4

@testable import Voice

private final class StubVADEngineForW4: VADInferenceEngine, @unchecked Sendable {
    func runInference(pcm: UnsafeBufferPointer<Float>) throws -> Float { return 0.0 }
}

private final class StubSTTProviderForW4: STTProvider, @unchecked Sendable {
    func transcribe(stream: AsyncStream<AudioChunk>) -> AsyncStream<PartialTranscript> {
        let (s, c) = AsyncStream<PartialTranscript>.makeStream()
        Task { c.finish() }
        return s
    }
    func finalize() async throws -> String { return "" }
}

private actor StubTTSForW4: VoiceTTSInterface {
    var hasSynthInFlight: Bool { false }
    func synthesize(_ text: String) async {}
    func cancelTTS() async {}
}

private actor StubOrchestratorForW4: VoiceOrchestratorInterface {
    nonisolated let voiceEvents: AsyncStream<VoiceOrchestratorEvent>
    init() { (voiceEvents, _) = AsyncStream<VoiceOrchestratorEvent>.makeStream() }
    func submit(text: String) async {}
    func cancelAndSubmit(text: String) async {}
}

private final class StubBannerForW4: VoiceBannerInterface, @unchecked Sendable {
    func showBanner(message: String) {}
    func dismissBanner() {}
}

private actor StubBusForW4: BusOutboundEmitter {
    func postAudio(_ rms: Float) async {}
}
