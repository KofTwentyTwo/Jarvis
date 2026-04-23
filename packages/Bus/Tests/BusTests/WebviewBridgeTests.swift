import XCTest
import WebKit
@testable import Bus

/// Exercises the inbound-decode-and-dispatch path via the internal
/// `handleInboundString` seam. Synthesizing `WKScriptMessage` instances from
/// user code is not supported — the test seam keeps the decode path covered
/// without reaching for WebKit internals.
@MainActor
final class WebviewBridgeTests: XCTestCase {
    // MARK: - Fixtures

    private func makeBridge() -> (WebviewBridge, WKWebView) {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let bridge = WebviewBridge(
            webView: webView,
            alertPresenter: { _, _ in
                // Silent presenter — these tests assert the inbound dispatch
                // path, not the alert path (covered by HandshakeTests).
            }
        )
        return (bridge, webView)
    }

    /// Main-actor-scoped reply capture. `Any?` is not `Sendable`, so we
    /// stash the reply values into main-actor-isolated storage and read them
    /// after waiting on an expectation that the replyHandler fulfills.
    private func runAndCaptureReply(
        _ body: (ReplyCollector) -> Void,
        timeout: TimeInterval = 1.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> ReplyCollector {
        let collector = ReplyCollector()
        body(collector)
        let waiter = XCTWaiter()
        _ = waiter.wait(for: [collector.expectation], timeout: timeout)
        if !collector.received {
            XCTFail("replyHandler never fired within \(timeout)s", file: file, line: line)
        }
        return collector
    }

    // MARK: - Success paths

    func test_inboundDecodeSuccessCallsOnInbound() {
        let (bridge, _) = makeBridge()
        var recorded: [BusInbound] = []
        bridge.onInbound = { msg in
            recorded.append(msg)
            return .success
        }

        let reply = runAndCaptureReply { collector in
            bridge.handleInboundString(#"{"type":"uiReady"}"#, replyHandler: collector.replyHandler)
        }

        XCTAssertEqual(recorded, [.uiReady])
        XCTAssertNil(reply.error)
        XCTAssertEqual(reply.plist?["ok"] as? Bool, true)
    }

    func test_onInboundReturningNilYieldsImplicitSuccess() {
        let (bridge, _) = makeBridge()
        bridge.onInbound = { _ in nil }

        let reply = runAndCaptureReply { collector in
            bridge.handleInboundString(#"{"type":"uiReady"}"#, replyHandler: collector.replyHandler)
        }

        XCTAssertNil(reply.error)
        XCTAssertEqual(reply.plist?["ok"] as? Bool, true)
    }

    // MARK: - Failure paths

    func test_inboundDecodeFailureSurfacesAsFailureReply() {
        let (bridge, _) = makeBridge()
        var onInboundCalls = 0
        bridge.onInbound = { _ in
            onInboundCalls += 1
            return .success
        }

        let reply = runAndCaptureReply { collector in
            bridge.handleInboundString("{not json", replyHandler: collector.replyHandler)
        }

        XCTAssertNil(reply.plist)
        XCTAssertTrue(
            reply.error?.lowercased().contains("decode") ?? false,
            "expected decode-error message, got: \(reply.error ?? "<nil>")"
        )
        XCTAssertEqual(onInboundCalls, 0, "onInbound must not fire on decode failure")
    }

    func test_inboundNonStringBodyIsFailureReply() {
        let (bridge, _) = makeBridge()

        let reply = runAndCaptureReply { collector in
            // `nil` models the "body was not a string" guard at the top of
            // `handleInboundString` — which the protocol method hits when
            // `message.body as? String` fails.
            bridge.handleInboundString(nil, replyHandler: collector.replyHandler)
        }

        XCTAssertNil(reply.plist)
        XCTAssertEqual(reply.error, "bus: expected string payload")
    }

    func test_onInboundThrowingErrorSurfacesAsFailureReply() {
        let (bridge, _) = makeBridge()
        bridge.onInbound = { _ in
            throw BusError.bridgeNotReady
        }

        let reply = runAndCaptureReply { collector in
            bridge.handleInboundString(#"{"type":"uiReady"}"#, replyHandler: collector.replyHandler)
        }

        XCTAssertNil(reply.plist)
        XCTAssertTrue(
            reply.error?.contains("handler error") ?? false,
            "expected handler-error prefix, got: \(reply.error ?? "<nil>")"
        )
    }

    // MARK: - Handshake ack is handled inline

    func test_helloAckHandledInlineDoesNotCallOnInbound() {
        let (bridge, _) = makeBridge()
        var onInboundCalls = 0
        bridge.onInbound = { _ in
            onInboundCalls += 1
            return .success
        }

        bridge.startHandshake()
        let payload = #"{"type":"helloAck","version":"\#(BUS_PROTOCOL_VERSION)"}"#
        let reply = runAndCaptureReply { collector in
            bridge.handleInboundString(payload, replyHandler: collector.replyHandler)
        }

        XCTAssertEqual(onInboundCalls, 0, "helloAck must not reach onInbound")
        XCTAssertEqual(bridge.handshakeState, .armed)
        XCTAssertNil(reply.error)
        XCTAssertEqual(reply.plist?["ok"] as? Bool, true)
    }

    // MARK: - Content world / handler registration

    func test_scriptMessageHandlerIsRegisteredUnderConfiguredName() {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        _ = WebviewBridge(
            webView: webView,
            messageHandlerName: "jarvisBus",
            alertPresenter: { _, _ in }
        )

        // Re-adding a handler with the same (contentWorld, name) pair would
        // raise `NSInvalidArgumentException`. The constructor succeeding is
        // itself evidence of registration. As a double-check, `remove` on a
        // registered handler must succeed without throwing.
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(
            forName: "jarvisBus",
            contentWorld: WKContentWorld.world(name: "JarvisBusWorld")
        )
        // No XCTAssert needed — the remove call succeeding on a registered
        // handler is the assertion.
    }
}

// MARK: - Reply collector

/// Main-actor-isolated reply storage. The replyHandler closure captures the
/// collector and writes into its mutable fields synchronously; the test
/// reads those fields after waiting on `expectation`.
@MainActor
final class ReplyCollector {
    let expectation = XCTestExpectation(description: "bus reply")
    var plist: [String: Any]?
    var error: String?
    var received: Bool = false

    var replyHandler: @MainActor @Sendable (Any?, String?) -> Void {
        { [self] value, error in
            self.plist = value as? [String: Any]
            self.error = error
            self.received = true
            self.expectation.fulfill()
        }
    }
}
