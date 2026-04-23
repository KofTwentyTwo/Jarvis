import XCTest
import AppKit
@testable import Jarvis
@testable import Bus
@testable import Config
@testable import Keychain
@testable import Shell

/// Exercises the Plan 02-03 bus wiring: `installBus()` constructs the
/// `WebviewBridge` around `hudPanel.webView`, `onHandshakeArmed` closure
/// records ready-state, mismatch calls the injected terminate closure, and
/// `toggleHUD()` gates on `handshakeState == .armed` — unarmed path enqueues
/// the `hud-not-ready` banner.
@MainActor
final class AppDelegateBusWiringTests: XCTestCase {
    // MARK: - Fakes (reuse the patterns established in AppDelegateWiringTests)

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

    // MARK: - Tests

    func test_installBusConstructsWebviewBridge() {
        let delegate = makeDelegate()
        delegate.applicationWillFinishLaunching(Notification(name: .init("t")))

        XCTAssertNotNil(delegate.hudPanel, "HUD panel must be installed before bus wiring")
        XCTAssertNotNil(
            delegate.webviewBridge,
            "installBus() must construct the WebviewBridge and hold it on the delegate"
        )
        cleanUp(delegate)
    }

    func test_toggleHUDWhenNotArmedEnqueuesBanner() {
        let delegate = makeDelegate()
        delegate.applicationWillFinishLaunching(Notification(name: .init("t")))

        // Bridge is not armed (no helloAck delivered in the test) — toggleHUD
        // should NOT summon the panel; it should enqueue the
        // `hud-not-ready` banner.
        XCTAssertNotEqual(delegate.webviewBridge?.handshakeState, .armed)

        delegate.exposedToggleHUD()

        XCTAssertEqual(
            delegate.bannerCoordinator?.currentBanner?.id,
            "hud-not-ready",
            "toggleHUD on an unarmed bridge must enqueue the priority-2 banner"
        )
        XCTAssertFalse(
            delegate.hudPanel?.isSummoned ?? true,
            "HUD panel must NOT summon when the bridge is not armed"
        )
        cleanUp(delegate)
    }

    func test_handshakeMismatchCallsTerminate() {
        let delegate = makeDelegate()
        var terminateCalls = 0
        delegate.onHandshakeMismatch = { terminateCalls += 1 }

        delegate.applicationWillFinishLaunching(Notification(name: .init("t")))
        XCTAssertNotNil(delegate.webviewBridge)

        // Drive a mismatch via the internal seam.
        delegate.webviewBridge?.handleHelloAck("1.0.0")

        XCTAssertEqual(terminateCalls, 1, "mismatch must fire the injected terminate closure exactly once")
        if case .mismatched(let swift, let js) = delegate.webviewBridge?.handshakeState {
            XCTAssertEqual(swift, BUS_PROTOCOL_VERSION)
            XCTAssertEqual(js, "1.0.0")
        } else {
            XCTFail("expected .mismatched state, got \(String(describing: delegate.webviewBridge?.handshakeState))")
        }
        cleanUp(delegate)
    }

    func test_onHandshakeArmedFiresInjectedHook() {
        let delegate = makeDelegate()
        var armedCount = 0
        delegate.onBusArmed = { armedCount += 1 }

        delegate.applicationWillFinishLaunching(Notification(name: .init("t")))
        // Drive a successful handshake via the internal seam.
        delegate.webviewBridge?.handleHelloAck(BUS_PROTOCOL_VERSION)

        XCTAssertEqual(armedCount, 1, "onBusArmed must fire exactly once on successful handshake")
        XCTAssertEqual(delegate.webviewBridge?.handshakeState, .armed)
        cleanUp(delegate)
    }

    func test_busHarnessHTMLPresentInBundle() {
        // Verifies the project.yml resource wiring: bus-harness.html must be
        // resolvable via Bundle.main under the `webview` subdirectory —
        // otherwise `panel.webView.loadFileURL(...)` at launch would fail.
        //
        // Under XCTest the main bundle IS the Jarvis app bundle (the test
        // bundle uses BUNDLE_LOADER to host inside Jarvis.app), so
        // `Bundle.main.url(forResource: "bus-harness", ...)` resolves against
        // the Jarvis.app/Contents/Resources/ tree.
        let url = Bundle.main.url(
            forResource: "bus-harness",
            withExtension: "html",
            subdirectory: "webview"
        )
        XCTAssertNotNil(
            url,
            "bus-harness.html must ship in Contents/Resources/webview/ of the built bundle. "
            + "Check project.yml resources wiring for App/Resources/webview."
        )
    }

    func test_toggleHUDWhenArmedSummonsPanel() {
        let delegate = makeDelegate()
        delegate.applicationWillFinishLaunching(Notification(name: .init("t")))

        // Drive the handshake to armed.
        delegate.webviewBridge?.handleHelloAck(BUS_PROTOCOL_VERSION)
        XCTAssertEqual(delegate.webviewBridge?.handshakeState, .armed)

        delegate.exposedToggleHUD()

        XCTAssertTrue(delegate.hudPanel?.isSummoned ?? false, "armed bridge must allow HUD summon")
        XCTAssertNotEqual(
            delegate.bannerCoordinator?.currentBanner?.id,
            "hud-not-ready",
            "armed bridge must not enqueue hud-not-ready"
        )
        cleanUp(delegate)
    }
}
