import XCTest
@testable import Jarvis
@testable import Keychain
@testable import Config
@testable import Shell

@MainActor
final class AppDelegateWiringTests: XCTestCase {
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

    /// Minimal valid `LaunchSnapshot` + `PerTurnSnapshot` pair decoded from
    /// hand-written JSON so tests don't depend on `writeDefaultAndReload`
    /// touching real disk.
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

    /// Helper: remove the status item installed by applicationWillFinishLaunching
    /// so tests don't leak menu-bar chrome across the suite.
    private func cleanUp(_ delegate: AppDelegate) {
        if let item = delegate.statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        // Close any wizard window opened during wiring.
        delegate.wizardController?.close()
    }

    func test_loggingBootstrapCalled() {
        let delegate = AppDelegate()
        delegate.entitlementProbe = EntitlementYes()
        delegate.configLoader = { _ in self.makeSnapshots() }
        delegate.configWriter = { _ in self.makeSnapshots() }
        delegate.keychainStore = FakeKeychain(apiKeyStored: true)
        delegate.hidProbe = FakeHIDProbe(granted: true)
        var bootstrapped = 0
        delegate.loggingBootstrap = { bootstrapped += 1 }

        delegate.applicationWillFinishLaunching(Notification(name: .init("t")))
        XCTAssertEqual(bootstrapped, 1, "Logging must bootstrap exactly once (S-8)")
        cleanUp(delegate)
    }

    func test_bannerEnqueuedOnKeychainEmpty() {
        let delegate = AppDelegate()
        delegate.entitlementProbe = EntitlementYes()
        delegate.configLoader = { _ in self.makeSnapshots() }
        delegate.configWriter = { _ in self.makeSnapshots() }
        delegate.keychainStore = FakeKeychain(apiKeyStored: false)
        delegate.hidProbe = FakeHIDProbe(granted: true)
        delegate.loggingBootstrap = {}

        delegate.applicationWillFinishLaunching(Notification(name: .init("t")))
        XCTAssertEqual(
            delegate.bannerCoordinator?.currentBanner?.id,
            "keychain-empty",
            "Keychain-empty must enqueue the priority-1 banner"
        )
        cleanUp(delegate)
    }

    func test_bannerEnqueuedOnInputMonitoringDenial() {
        let delegate = AppDelegate()
        delegate.entitlementProbe = EntitlementYes()
        delegate.configLoader = { _ in self.makeSnapshots() }
        delegate.configWriter = { _ in self.makeSnapshots() }
        delegate.keychainStore = FakeKeychain(apiKeyStored: true)
        delegate.hidProbe = FakeHIDProbe(granted: false)
        delegate.loggingBootstrap = {}

        delegate.applicationWillFinishLaunching(Notification(name: .init("t")))
        // Priority: keychain-empty (1) > input-monitoring-denied (2). API key
        // stored → no keychain banner. Denied → input-monitoring-denied.
        XCTAssertEqual(
            delegate.bannerCoordinator?.currentBanner?.id,
            "input-monitoring-denied",
            "Input Monitoring denial must enqueue the priority-2 banner (SHELL-06)"
        )
        cleanUp(delegate)
    }

    /// IN-07 (T-04-02 / SEC-01): `copyStateDump()` writes only boolean
    /// presence indicators to the clipboard — never the API key itself.
    /// Previously this test was an `XCTAssertTrue(true)` tautology that
    /// couldn't fail on a real regression. Now we use a FakeKeychain that
    /// returns a recognizable plaintext value ("sk-ant-test-plaintext"),
    /// invoke `copyStateDump` via the private selector, and assert the
    /// pasteboard contents DO NOT contain that plaintext.
    func test_stateDumpDoesNotIncludeAPIKey() throws {
        let recognizablePlaintext = "sk-ant-test-do-not-leak"
        struct RecognizableKeychain: KeychainStore {
            let value: String
            func set(_ value: String, for item: KeychainItem) throws {}
            func get(_ item: KeychainItem) throws -> String { value }
            func delete(_ item: KeychainItem) throws {}
        }

        let delegate = AppDelegate()
        delegate.entitlementProbe = EntitlementYes()
        delegate.configLoader = { _ in self.makeSnapshots() }
        delegate.configWriter = { _ in self.makeSnapshots() }
        delegate.keychainStore = RecognizableKeychain(value: recognizablePlaintext)
        delegate.hidProbe = FakeHIDProbe(granted: true)
        delegate.loggingBootstrap = {}

        // Clear pasteboard first so a prior test's contents can't contaminate
        // the assertion.
        NSPasteboard.general.clearContents()

        delegate.applicationWillFinishLaunching(Notification(name: .init("t")))

        // `copyStateDump` is private; invoke via perform(...) for test access.
        let selector = Selector(("copyStateDump"))
        if delegate.responds(to: selector) {
            delegate.perform(selector)
        } else {
            XCTFail("AppDelegate must expose copyStateDump for SEC-01 verification")
            cleanUp(delegate)
            return
        }

        let pasteboardContents = NSPasteboard.general.string(forType: .string) ?? ""
        XCTAssertFalse(
            pasteboardContents.contains(recognizablePlaintext),
            "SEC-01/T-04-02: state dump must never include the raw API key. "
            + "Found leaked value in pasteboard: \(pasteboardContents.prefix(200))"
        )
        XCTAssertFalse(
            pasteboardContents.contains("sk-ant-"),
            "SEC-01: state dump must not contain any `sk-ant-` prefix"
        )
        // Sanity: the dump should exist (non-empty JSON) and carry the
        // boolean indicator we expect. This confirms the test exercised the
        // happy path rather than failing silently.
        XCTAssertTrue(
            pasteboardContents.contains("\"apiKeyStored\""),
            "State dump must include the apiKeyStored boolean"
        )
        cleanUp(delegate)
    }
}
