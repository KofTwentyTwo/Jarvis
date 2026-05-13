import XCTest
import WebKit
@testable import Bus

/// Drives the handshake state machine through `WebviewBridge`'s internal
/// `handleHelloAck` + `startHandshake` surface. Alerts are captured into an
/// in-memory collector via the injectable `alertPresenter`, so no NSAlert
/// ever runs under XCTest.
@MainActor
final class HandshakeTests: XCTestCase {
    // MARK: - Fixtures

    private func makeBridge(
        alertCollector: AlertCollector,
        armedExpectation: XCTestExpectation? = nil
    ) -> WebviewBridge {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let bridge = WebviewBridge(
            webView: webView,
            alertPresenter: { title, body in
                alertCollector.record(title: title, body: body)
            }
        )
        if let armedExpectation {
            bridge.onHandshakeArmed = { armedExpectation.fulfill() }
        }
        return bridge
    }

    // MARK: - Tests

    func test_handshakeArmsOnMatchingVersion() {
        let alerts = AlertCollector()
        let armed = expectation(description: "onHandshakeArmed fires once")
        armed.assertForOverFulfill = true
        let bridge = makeBridge(alertCollector: alerts, armedExpectation: armed)

        bridge.startHandshake()
        bridge.handleHelloAck(BUS_PROTOCOL_VERSION)

        wait(for: [armed], timeout: 0.1)
        XCTAssertEqual(bridge.handshakeState, .armed)
        XCTAssertEqual(alerts.count, 0, "no alert should fire on successful handshake")
    }

    func test_handshakeMismatchTriggersAlertAndBlocks() {
        let alerts = AlertCollector()
        let bridge = makeBridge(alertCollector: alerts)
        var armedFired = false
        bridge.onHandshakeArmed = { armedFired = true }

        bridge.startHandshake()
        bridge.handleHelloAck("1.9.0")

        XCTAssertEqual(
            bridge.handshakeState,
            .mismatched(swift: BUS_PROTOCOL_VERSION, js: "1.9.0")
        )
        XCTAssertEqual(alerts.count, 1, "exactly one alert on version mismatch")
        XCTAssertEqual(alerts.titles.first, "Jarvis HUD couldn't start")
        XCTAssertTrue(
            alerts.bodies.first?.contains("v1.9.0") ?? false,
            "alert body should mention JS version"
        )
        XCTAssertFalse(armedFired, "onHandshakeArmed must not fire on mismatch")
    }

    func test_handshakeTimeoutTriggersAlert() async {
        let alerts = AlertCollector()
        let bridge = makeBridge(alertCollector: alerts)

        // Use a local expectation to wait out the 2s HandshakeTiming.timeout
        // (+ a small margin).
        let timedOut = expectation(description: "handshake times out")
        alerts.onRecord = { timedOut.fulfill() }

        bridge.startHandshake()

        await fulfillment(of: [timedOut], timeout: 3.0)
        XCTAssertEqual(bridge.handshakeState, .timedOut)
        XCTAssertEqual(alerts.count, 1, "exactly one alert on timeout")
        XCTAssertEqual(alerts.titles.first, "Jarvis HUD couldn't start")
        XCTAssertTrue(
            alerts.bodies.first?.contains("2 seconds") ?? false,
            "alert body should mention the 2s window"
        )
    }

    func test_handshakeTimeoutCancelledByArm() async {
        let alerts = AlertCollector()
        let bridge = makeBridge(alertCollector: alerts)

        bridge.startHandshake()
        // Arm well before the 2s deadline; the timeout Task must be cancelled.
        try? await Task.sleep(for: .milliseconds(100))
        bridge.handleHelloAck(BUS_PROTOCOL_VERSION)
        XCTAssertEqual(bridge.handshakeState, .armed)

        // Wait past the original 2s deadline; if the timeout leaked we'd see
        // `.timedOut` + an alert.
        try? await Task.sleep(for: .milliseconds(2100))
        XCTAssertEqual(bridge.handshakeState, .armed, "state must stay armed past deadline")
        XCTAssertEqual(alerts.count, 0, "armed handshake must suppress timeout alert")
    }

    // MARK: - Audit-2026-05-12 S1 / #40 — failHandshake(reason:)

    /// `failHandshake` from `.sentHello` transitions to `.loadFailed`, cancels
    /// the pending 2s timeout, and fires exactly one alert.
    func test_failHandshakeTransitionsToLoadFailedAndAlerts() async {
        let alerts = AlertCollector()
        let bridge = makeBridge(alertCollector: alerts)

        bridge.startHandshake()
        bridge.failHandshake(reason: "bundle 404: assets/index-XYZ.js")

        XCTAssertEqual(
            bridge.handshakeState,
            .loadFailed(reason: "bundle 404: assets/index-XYZ.js")
        )
        XCTAssertEqual(alerts.count, 1, "exactly one alert on load failure")
        XCTAssertEqual(alerts.titles.first, "Jarvis HUD couldn't start")
        XCTAssertTrue(
            alerts.bodies.first?.contains("assets/index-XYZ.js") ?? false,
            "alert body should mention the underlying reason"
        )

        // The cancelled timeout must not fire — wait past the 2s deadline
        // and confirm no second alert lands.
        try? await Task.sleep(for: .milliseconds(2100))
        XCTAssertEqual(
            alerts.count,
            1,
            "cancelled timeout must not surface a second alert"
        )
        if case .loadFailed = bridge.handshakeState {
            // ok
        } else {
            XCTFail("state must remain .loadFailed past 2s deadline, got \(bridge.handshakeState)")
        }
    }

    /// `failHandshake` from `.idle` (before `startHandshake`) is still valid —
    /// the navigation can fail before `didFinish` would have been called.
    func test_failHandshakeFromIdleTransitions() {
        let alerts = AlertCollector()
        let bridge = makeBridge(alertCollector: alerts)

        XCTAssertEqual(bridge.handshakeState, .idle)
        bridge.failHandshake(reason: "provisional nav failed: -1100")

        XCTAssertEqual(
            bridge.handshakeState,
            .loadFailed(reason: "provisional nav failed: -1100")
        )
        XCTAssertEqual(alerts.count, 1)
    }

    /// `failHandshake` is idempotent — once in a terminal state, calling
    /// again no-ops (no second alert, no state change).
    func test_failHandshakeIsIdempotent() {
        let alerts = AlertCollector()
        let bridge = makeBridge(alertCollector: alerts)

        bridge.failHandshake(reason: "first")
        bridge.failHandshake(reason: "second")

        XCTAssertEqual(
            bridge.handshakeState,
            .loadFailed(reason: "first"),
            "subsequent failHandshake calls must not overwrite the first reason"
        )
        XCTAssertEqual(alerts.count, 1, "subsequent failHandshake calls must not re-alert")
    }

    /// `failHandshake` after `.armed` no-ops — once the handshake succeeds,
    /// a late navigation-failure callback (which would normally never fire)
    /// must not transition out of `.armed`.
    func test_failHandshakeAfterArmedNoOps() {
        let alerts = AlertCollector()
        let bridge = makeBridge(alertCollector: alerts)

        bridge.startHandshake()
        bridge.handleHelloAck(BUS_PROTOCOL_VERSION)
        XCTAssertEqual(bridge.handshakeState, .armed)

        bridge.failHandshake(reason: "late didFail")

        XCTAssertEqual(bridge.handshakeState, .armed, "armed handshake must not regress to .loadFailed")
        XCTAssertEqual(alerts.count, 0)
    }

    func test_startHandshakeMovesToSentHello() {
        let alerts = AlertCollector()
        let bridge = makeBridge(alertCollector: alerts)

        XCTAssertEqual(bridge.handshakeState, .idle)
        bridge.startHandshake()

        if case .sentHello(let deadline) = bridge.handshakeState {
            XCTAssertGreaterThan(deadline, Date(), "deadline must be in the future")
            XCTAssertLessThan(
                deadline.timeIntervalSince(Date()),
                3.0,
                "deadline must be ~2s from now"
            )
        } else {
            XCTFail("expected .sentHello, got \(bridge.handshakeState)")
        }
    }
}

// MARK: - Test helpers

/// Captures alert invocations. `XCTestExpectation` alone would fulfill on
/// the first record but can't count or inspect payload — this collector
/// fills both gaps.
@MainActor
final class AlertCollector {
    private(set) var titles: [String] = []
    private(set) var bodies: [String] = []
    var onRecord: (() -> Void)?

    var count: Int { titles.count }

    func record(title: String, body: String) {
        titles.append(title)
        bodies.append(body)
        onRecord?()
    }
}
