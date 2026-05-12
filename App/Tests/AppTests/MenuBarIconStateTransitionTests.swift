import XCTest
import AppKit
import AgentCore
@testable import Jarvis
@testable import Bus
@testable import Config
@testable import Keychain
@testable import Shell

/// Audit-2026-05-12 S1 / #41 regression tests:
///
/// `MenuBarIconController.transition(to:)` is wired through the
/// `HudStateCoordinator` emit closure that drives the bus, so the menu-bar
/// icon animates per agent state (breath/rotate/shimmer/glow). Before this
/// fix the method existed and was unit-tested but had zero production call
/// sites — the icon stayed in `.idle` for the whole app lifetime regardless
/// of agent activity.
///
/// This is NOT a HUD-08 single-writer violation. `transition(to:)` writes
/// the icon's `currentState`, not `BusOutbound.hudState` (whose sole
/// constructor remains the coordinator's existing `bridge.send(.hudState(...))`
/// call). `scripts/check-single-writer-hudstate.sh` covers the invariant.
@MainActor
final class MenuBarIconStateTransitionTests: XCTestCase {
    // MARK: - Fakes (mirror existing AppDelegateBusWiringTests pattern)

    private struct FakeKeychain: KeychainStore {
        let apiKeyStored: Bool
        func set(_ value: String, for item: KeychainItem) throws {}
        func get(_ item: KeychainItem) throws -> String {
            guard apiKeyStored else { throw KeychainError.itemNotFound }
            return "sk-ant-fake"
        }
        func delete(_ item: KeychainItem) throws {}
    }

    private struct FakeHIDProbe: HIDAccessProbe {
        let granted: Bool
        func requestListenEventAccess() -> Bool { granted }
    }

    private struct EntitlementYes: EntitlementGateProbe { func isVerified() -> Bool { true } }

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

    private func cleanUp(_ delegate: AppDelegate) {
        if let item = delegate.statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        delegate.wizardController?.close()
    }

    private func makeDelegate(apiKey: Bool = true) -> AppDelegate {
        let delegate = AppDelegate()
        delegate.entitlementProbe = EntitlementYes()
        delegate.configLoader = { _ in self.makeSnapshots() }
        delegate.configWriter = { _ in self.makeSnapshots() }
        delegate.keychainStore = FakeKeychain(apiKeyStored: apiKey)
        delegate.hidProbe = FakeHIDProbe(granted: true)
        delegate.loggingBootstrap = {}
        return delegate
    }

    /// The `HudStateCoordinator` emit closure constructed in `installBus()`
    /// fans state changes to BOTH the bus AND `menuBarController.transition(to:)`.
    /// Drives the dormant agent-intent continuation through the live
    /// coordinator and asserts `menuBarController.state` advances.
    func test_menuBarIconAnimatesOnAgentStateChange() async throws {
        let delegate = makeDelegate()
        delegate.applicationWillFinishLaunching(Notification(name: .init("t")))
        defer { cleanUp(delegate) }

        guard let coordinator = delegate.hudStateCoordinator else {
            XCTFail("HudStateCoordinator must be installed")
            return
        }
        guard let icon = delegate.menuBarController else {
            XCTFail("MenuBarIconController must be installed")
            return
        }
        guard let agentCont = delegate.dormantAgentContinuation else {
            XCTFail("dormantAgentContinuation must be retained")
            return
        }

        // Arm the handshake so the coordinator promotes off `.booting` —
        // otherwise the coordinator pins everything to `.booting` per the
        // RESEARCH Open Q #4 boot gate, masking the agent intent.
        delegate.webviewBridge?.handleHelloAck(BUS_PROTOCOL_VERSION)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(
            coordinator.currentStateForTests,
            .idle,
            "coordinator must promote off .booting after handshake arms"
        )

        // Drive a sequence of agent intents and assert the icon follows.
        // The icon was initialized to `.idle`; after each intent, the
        // coordinator's emit closure routes to `transition(to:)`.
        agentCont.yield(.thinking)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(
            icon.state,
            .thinking,
            "menu-bar icon must reach .thinking when AgentHudIntent.thinking fires"
        )

        agentCont.yield(.speaking)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(
            icon.state,
            .speaking,
            "menu-bar icon must reach .speaking when AgentHudIntent.speaking fires"
        )

        agentCont.yield(.idle)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(
            icon.state,
            .idle,
            "menu-bar icon must return to .idle when AgentHudIntent.idle fires"
        )
    }
}
