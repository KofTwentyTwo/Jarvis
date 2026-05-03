import XCTest
import WebKit
@testable import Bus

/// End-to-end integration tests for the bus handshake using a REAL
/// `WKWebView`. Distinct from `WebviewBridgeTests` (which uses the
/// `handleInboundString` test seam) and `HandshakeTests` (which drives
/// `handleHelloAck` directly).
///
/// These tests load a tiny HTML page, let `Injection.js` execute at
/// document-start, then call `bridge.startHandshake()` and wait for
/// the JS round-trip to drive `handshakeState` to `.armed` via the
/// real `WKScriptMessageHandlerWithReply` path.
///
/// **Why this exists** — Phase D-Phase-2 / Phase F1 of
/// `.planning/AUDIT-AND-FIX-PLAN.md`. The 2026-05-02 audit-and-fix
/// session uncovered a `WKContentWorld` isolation bug
/// (`Injection.js` ran in `WKContentWorld(name: "JarvisBusWorld")`
/// while the bundle ran in the page world; `window.jarvisBus`
/// properties were per-world isolated; bundle's `attachBus()` saw
/// `undefined` and created a SECOND fresh bus object; two stubs, two
/// objects, no shared handler, handshake hung). The unit-level test
/// suites (Bus 54/54, AppTests, etc.) all passed because they bypass
/// the `WKScriptMessageHandler` delivery path via the
/// `JSEvaluator` / `handleInboundString` test seams.
///
/// A test that loads a real `WKWebView` and waits for the handshake
/// to actually round-trip would have failed in 60–80 ms on the bug
/// branch, and the bug would not have shipped. This file is that
/// test.
///
/// **Runtime constraints:**
/// - Must run on the main actor — WebKit refuses `@MainActor`-required
///   APIs off main.
/// - Must give Injection.js time to install before assertions fire —
///   the WKWebView navigation completes synchronously, but the user
///   script execution is queued; we poll on `handshakeState` rather
///   than `Task.sleep` for a fixed duration.
/// - Avoid `loadHTMLString` with `nil` baseURL on macOS 14+ — the
///   resulting page has no origin and some WK internals throw on
///   that (use `URL(fileURLWithPath: "/")`).
@MainActor
final class RealWKWebViewIntegrationTests: XCTestCase {

    // MARK: - Fixtures

    private struct E2EFixture {
        let webView: WKWebView
        let bridge: WebviewBridge
        let alertWasCalled: () -> Bool
    }

    private func makeFixture() -> E2EFixture {
        // Box the alert flag in a class so the bridge's `@escaping`
        // closure captures by reference and the test can read it
        // after-the-fact without `inout`.
        final class AlertFlag { var fired = false }
        let flag = AlertFlag()

        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        let bridge = WebviewBridge(
            webView: webView,
            alertPresenter: { _, _ in
                flag.fired = true
            }
        )

        return E2EFixture(
            webView: webView,
            bridge: bridge,
            alertWasCalled: { flag.fired }
        )
    }

    /// Tiny page that does NOT register an `onOutbound` handler. Per the
    /// fb41c5f production fix, `Injection.js` auto-acks `hello` at the
    /// stub layer regardless of whether the bundle's handler is
    /// registered, so handshake succeeds without any bundle code.
    /// This is the minimum-viable real round-trip.
    private static let blankHTML = """
    <!DOCTYPE html>
    <html><head><meta charset="utf-8"></head>
    <body><div id="root"></div></body></html>
    """

    /// Loads the blank HTML and waits for `webView.isLoading == false`
    /// before returning. `loadHTMLString` resolves on the navigation
    /// delegate; we don't have one wired here, so we poll the
    /// `isLoading` flag with an XCTNSPredicateExpectation.
    private func loadBlankAndWait(
        _ webView: WKWebView,
        timeout: TimeInterval = 2.0
    ) {
        webView.loadHTMLString(
            Self.blankHTML,
            baseURL: URL(fileURLWithPath: "/")
        )
        let pred = NSPredicate(block: { obj, _ in
            guard let wv = obj as? WKWebView else { return false }
            return !wv.isLoading
        })
        let exp = expectation(for: pred, evaluatedWith: webView)
        wait(for: [exp], timeout: timeout)
    }

    /// Polls `bridge.handshakeState == expected` with the given timeout.
    /// Returns the final observed state for diagnostic XCTAssert messages.
    @MainActor
    private func waitForHandshake(
        _ bridge: WebviewBridge,
        toReach expected: HandshakeState,
        timeout: TimeInterval = 2.5
    ) -> HandshakeState {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if bridge.handshakeState == expected {
                return bridge.handshakeState
            }
            let runUntil = Date().addingTimeInterval(0.05)
            RunLoop.main.run(mode: .default, before: runUntil)
        }
        return bridge.handshakeState
    }

    // MARK: - Tests

    /// **The test that would have caught the WKContentWorld bug.**
    ///
    /// On the bug branch, `Injection.js` ran in
    /// `WKContentWorld(name: "JarvisBusWorld")` while
    /// `WebviewBridge.sendRaw` invoked `callAsyncJavaScript` against
    /// the same named world — but the message *handler* was registered
    /// against `WKContentWorld.page`, so JS-side `postMessage` calls
    /// from the named-world stub never reached Swift. Handshake hung
    /// at `.sentHello`, eventually timed out with an `NSAlert`.
    ///
    /// On the fixed branch (fb41c5f), Injection.js auto-acks `hello`
    /// at the stub layer in the unified `.page` world, the bridge's
    /// `WKScriptMessageHandlerWithReply` receives the ack, the
    /// handshake transitions `.sentHello → .armed`, and this test
    /// passes in well under 2 seconds.
    func test_endToEndHandshake_reachesArmed() throws {
        let fx = makeFixture()
        loadBlankAndWait(fx.webView)

        // Sanity: navigation completed but handshake hasn't started yet.
        XCTAssertEqual(fx.bridge.handshakeState, .idle)
        XCTAssertFalse(fx.alertWasCalled(),
            "no alert should fire pre-handshake")

        fx.bridge.startHandshake()
        let final = waitForHandshake(fx.bridge, toReach: .armed)

        XCTAssertEqual(
            final, .armed,
            """
            handshake should reach .armed within 2s; got \(final). \
            If this fails with .timedOut, check that Injection.js \
            and WebviewBridge use the SAME WKContentWorld for both \
            the message handler AND the user script AND \
            callAsyncJavaScript — otherwise window.jarvisBus is \
            isolated per-world.
            """
        )
        XCTAssertFalse(
            fx.alertWasCalled(),
            "the alert path is for handshake FAILURE; success path must not invoke it"
        )
    }

    /// **Asserts the handshake is genuinely round-trip — not a Swift-side
    /// short-circuit.**
    ///
    /// If the bridge incorrectly transitioned to `.armed` purely on
    /// `startHandshake()` (e.g., a bug that bypassed the JS ack),
    /// the test above could pass spuriously. This test confirms the
    /// transition happens AFTER the JS-side `helloAck` arrives, by
    /// inspecting that `handshakeState` was `.sentHello(...)` between
    /// `startHandshake()` and the JS round-trip.
    ///
    /// We can't guarantee a specific ordering window without a delay
    /// hook, so we sample `handshakeState` rapidly right after
    /// `startHandshake()` and assert that we observed `.sentHello` at
    /// least once before `.armed`. Empirically the round-trip takes
    /// ~10–30 ms on Apple Silicon, so a 1 ms sampling window catches
    /// it reliably without flake.
    func test_endToEndHandshake_passesThroughSentHello() throws {
        let fx = makeFixture()
        loadBlankAndWait(fx.webView)

        var observedSentHello = false
        fx.bridge.startHandshake()

        // Sample for up to 100 ms looking for the .sentHello state.
        let sampleDeadline = Date().addingTimeInterval(0.100)
        while Date() < sampleDeadline {
            if case .sentHello = fx.bridge.handshakeState {
                observedSentHello = true
                break
            }
            if fx.bridge.handshakeState == .armed { break }
            RunLoop.main.run(mode: .default,
                before: Date().addingTimeInterval(0.001))
        }

        // After sampling, finish the handshake.
        let final = waitForHandshake(fx.bridge, toReach: .armed)

        XCTAssertTrue(
            observedSentHello,
            """
            handshake should pass through .sentHello before .armed; \
            never observed .sentHello (final=\(final)). This would \
            indicate a Swift-side short-circuit bypassing the JS \
            round-trip.
            """
        )
        XCTAssertEqual(final, .armed)
    }
}
