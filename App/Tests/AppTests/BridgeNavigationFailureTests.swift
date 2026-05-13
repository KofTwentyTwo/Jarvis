import XCTest
import AppKit
import WebKit
@testable import Jarvis
@testable import Bus
@testable import Config
@testable import Keychain
@testable import Shell

/// Audit-2026-05-12 S1 / #40 regression tests:
///
/// `BridgeNavigationDelegate.didFail*` arms surface a HUD-native critical
/// banner + transition the handshake state machine to `.loadFailed` so a
/// missing/stale bundle is never a silent black HUD. Before this fix, the
/// delegate only implemented `didFinish` — a 404 on the JS bundle (or any
/// pre-mount JS error) left the handshake stuck in `.idle` forever and the
/// 2s `HandshakeTiming.timeout` was never armed.
@MainActor
final class BridgeNavigationFailureTests: XCTestCase {
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

    // MARK: - Tests

    /// `handleWebviewLoadFailure` transitions the bridge to `.loadFailed` and
    /// enqueues a critical banner. Before this fix, a stale bundle reference
    /// (e.g. `<script src="./assets/index-XXX.js">` 404) left the handshake
    /// stuck in `.idle` forever — `startHandshake` only runs from
    /// `didFinish`, and `didFinish` never fires when the page errors before
    /// completing.
    func test_handleWebviewLoadFailureTransitionsBridgeAndEnqueuesBanner() {
        let delegate = makeDelegate()
        delegate.applicationWillFinishLaunching(Notification(name: .init("t")))
        guard let bridge = delegate.webviewBridge else {
            XCTFail("WebviewBridge must be installed by installBus()")
            cleanUp(delegate)
            return
        }
        guard let banners = delegate.bannerCoordinator else {
            XCTFail("BannerCoordinator must be installed before installBus()")
            cleanUp(delegate)
            return
        }
        XCTAssertNil(banners.currentBanner, "no banner before failure")

        // Synthesize a representative WKWebView navigation error — domain +
        // code mirror what WebKit emits for a missing file:// resource.
        let error = NSError(
            domain: "NSURLErrorDomain",
            code: -1100, // NSURLErrorFileDoesNotExist
            userInfo: [NSLocalizedDescriptionKey: "The requested file does not exist."]
        )

        delegate.handleWebviewLoadFailure(error)

        // Bridge state must be terminal `.loadFailed`.
        if case .loadFailed(let reason) = bridge.handshakeState {
            XCTAssertTrue(reason.contains("NSURLErrorDomain"))
            XCTAssertTrue(reason.contains("-1100"))
        } else {
            XCTFail("expected .loadFailed, got \(bridge.handshakeState)")
        }

        // A critical banner must be on screen.
        XCTAssertEqual(banners.currentBanner?.id, "boot-health-critical-webview")
        XCTAssertEqual(
            banners.currentBanner?.priority,
            1,
            "webview load failure is critical-priority (1)"
        )
        XCTAssertEqual(
            banners.currentBanner?.nonDismissible,
            true,
            "load-failure banner must be non-dismissible (user can't click away a black HUD)"
        )

        cleanUp(delegate)
    }

    /// `BridgeNavigationDelegate.didFailProvisionalNavigation` invokes the
    /// `onDidFail` closure. Drives the protocol method directly with a
    /// synthesized error to verify the arm exists and routes correctly.
    func test_bridgeNavigationDelegateDidFailProvisionalRoutesToOnDidFail() {
        var captured: Error?
        let expectation = self.expectation(description: "onDidFail fires")
        let delegate = BridgeNavigationDelegate(
            onDidFinish: { XCTFail("didFinish must not fire on failure path") },
            onDidFail: { error in
                captured = error
                expectation.fulfill()
            }
        )

        let error = NSError(domain: "WebKitErrorDomain", code: 102, userInfo: nil)
        let webView = WKWebView(frame: .zero)
        delegate.webView(webView, didFailProvisionalNavigation: nil, withError: error)

        wait(for: [expectation], timeout: 0.5)
        XCTAssertEqual((captured as NSError?)?.code, 102)
    }

    /// `BridgeNavigationDelegate.didFail` (post-provisional) also routes to
    /// `onDidFail` — separate arm but same closure target.
    func test_bridgeNavigationDelegateDidFailRoutesToOnDidFail() {
        var captured: Error?
        let expectation = self.expectation(description: "onDidFail fires")
        let delegate = BridgeNavigationDelegate(
            onDidFinish: { XCTFail("didFinish must not fire on failure path") },
            onDidFail: { error in
                captured = error
                expectation.fulfill()
            }
        )

        let error = NSError(domain: "WebKitErrorDomain", code: 204, userInfo: nil)
        let webView = WKWebView(frame: .zero)
        delegate.webView(webView, didFail: nil, withError: error)

        wait(for: [expectation], timeout: 0.5)
        XCTAssertEqual((captured as NSError?)?.code, 204)
    }
}
