import XCTest
import AppKit
@testable import Jarvis
@testable import Config
@testable import Keychain
@testable import Shell

@MainActor
final class AppDelegateEntitlementTests: XCTestCase {
    private struct MockProbe: EntitlementGateProbe {
        let verified: Bool
        func isVerified() -> Bool { verified }
    }

    private struct FakeKeychain: KeychainStore {
        func set(_ value: String, for item: KeychainItem) throws {}
        func get(_ item: KeychainItem) throws -> String { "sk-ant-fake" }
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

    func test_hardBlockTriggersOnMissingVerification() {
        let delegate = AppDelegate()
        delegate.entitlementProbe = MockProbe(verified: false)
        delegate.loggingBootstrap = {}  // S-8: avoid double-bootstrap across tests
        var failureCalled = false
        delegate.onEntitlementFailure = { failureCalled = true }

        delegate.applicationWillFinishLaunching(Notification(name: .init("test")))
        XCTAssertTrue(
            failureCalled,
            "Entitlement failure callback should fire when probe returns false"
        )
    }

    func test_noHardBlockWhenVerified() {
        let delegate = AppDelegate()
        delegate.entitlementProbe = MockProbe(verified: true)
        delegate.loggingBootstrap = {}  // S-8: avoid double-bootstrap across tests
        // Plan 04 added config/keychain/HID probing after the entitlement gate;
        // inject safe fakes so this test only exercises the entitlement path.
        delegate.configLoader = { _ in self.makeSnapshots() }
        delegate.configWriter = { _ in self.makeSnapshots() }
        delegate.keychainStore = FakeKeychain()
        delegate.hidProbe = FakeHIDProbe()
        var failureCalled = false
        delegate.onEntitlementFailure = { failureCalled = true }

        delegate.applicationWillFinishLaunching(Notification(name: .init("test")))
        XCTAssertFalse(
            failureCalled,
            "Entitlement failure should NOT fire when probe returns true"
        )

        // Clean up side effects: remove the installed status item so the test
        // leaves the status bar unchanged.
        if let item = delegate.statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        delegate.wizardController?.close()
    }
}
