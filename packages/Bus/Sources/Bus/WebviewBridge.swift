import Foundation
import WebKit
import Logging
import JarvisLogging

/// Main-actor-bound bridge between Swift and the webview's JS layer.
///
/// Responsibilities (P2-01 scope):
/// - Install a `WKScriptMessageHandlerWithReply` in an isolated content world
///   (`JarvisBusWorld`) so page scripts cannot observe or post to it.
/// - Decode inbound JSON into `BusInbound` and either (a) handle the handshake
///   ack inline or (b) route to the caller-supplied `onInbound` closure.
/// - Surface every decode/handler path through the `replyHandler` so the JS
///   side gets a `resolve` or `reject` for every `postMessage` call.
/// - Drive the two-way handshake state machine (HUD-05) with a 2s timeout.
/// - Present a stubbed `send(_:)` outbound API; Plan 03 swaps the stub for a
///   real `callAsyncJavaScript` wiring.
///
/// This class is `@MainActor` because WebKit APIs demand main-thread calls
/// and `WKScriptMessage.body` must be read on main. The
/// `WKScriptMessageHandlerWithReply` protocol method itself is marked
/// `nonisolated` by the SDK, so the protocol method hops back onto the main
/// actor via `MainActor.assumeIsolated` — the recommended Swift 6 workaround
/// from Apple DevForums 751086 (FB13774556).
@MainActor
public final class WebviewBridge: NSObject {
    /// Closure used to display hard-block alerts on handshake failure.
    /// Injected so tests can verify the alert path without calling
    /// `NSAlert.runModal` under XCTest. Production wiring (Plan 03) routes
    /// this to `TCCAlertService.presentHardBlock` + `NSApp.terminate`.
    public typealias AlertPresenter = @MainActor (_ title: String, _ body: String) -> Void

    // MARK: - Configuration

    private let webView: WKWebView
    private let messageHandlerName: String
    private let contentWorld: WKContentWorld
    private let alertPresenter: AlertPresenter

    // MARK: - Codecs

    private let encoder = BusCoder.makeEncoder()
    private let decoder = BusCoder.makeDecoder()
    private let logger = Logger(label: JarvisLogChannel.bus.rawValue)

    // MARK: - Public hooks

    /// Invoked for every non-handshake inbound message. Return `nil` for
    /// an implicit success reply (`{"ok": true}`); return an explicit
    /// `BusReply` to ship a payload or an explicit error.
    ///
    /// A throw here surfaces to JS as `Promise.reject(new Error(error))`.
    public var onInbound: (@MainActor (BusInbound) async throws -> BusReply?)?

    /// Fires exactly once when the handshake transitions `.sentHello` →
    /// `.armed`. Plan 03 uses this to unblock outbound sends and kick off
    /// `OutboundBatcher`.
    public var onHandshakeArmed: (@MainActor () -> Void)?

    // MARK: - State

    public private(set) var handshakeState: HandshakeState = .idle

    private var timeoutTask: Task<Void, Never>?

    // MARK: - Init

    public init(
        webView: WKWebView,
        messageHandlerName: String = "jarvisBus",
        contentWorldName: String = "JarvisBusWorld",
        alertPresenter: @escaping AlertPresenter
    ) {
        self.webView = webView
        self.messageHandlerName = messageHandlerName
        self.contentWorld = WKContentWorld.world(name: contentWorldName)
        self.alertPresenter = alertPresenter
        super.init()

        webView.configuration.userContentController.addScriptMessageHandler(
            self,
            contentWorld: self.contentWorld,
            name: self.messageHandlerName
        )
    }

    // MARK: - Handshake surface

    /// Plan 03 calls this after `WKNavigationDelegate.webView(_:didFinish:)`.
    /// P2-01 scope: state-machine transition + timeout task. The actual
    /// `callAsyncJavaScript` `{"type":"hello",…}` send is a Plan 03 concern
    /// so this package does not need to know about navigation lifecycle.
    public func startHandshake() {
        let deadline = Date().addingTimeInterval(2.0)
        handshakeState = .sentHello(deadline: deadline)
        scheduleTimeout()
    }

    /// Stubbed outbound send. Plan 03 replaces the body with a real
    /// `callAsyncJavaScript` wiring. Keeping the method here lets the Plan 03
    /// test surface already assume the signature exists.
    public func send(_ message: BusOutbound) async throws {
        guard handshakeState == .armed else {
            throw BusError.bridgeNotReady
        }
        // P2-01 stub — serialize to exercise the Codable path end-to-end so
        // any breakage surfaces here rather than at P2-03 integration time.
        _ = try encoder.encode(message)
        // P2-03 replaces the line above with:
        //     let json = String(decoding: try encoder.encode(message), as: UTF8.self)
        //     _ = try await webView.callAsyncJavaScript(
        //         "window.__jarvisBusOnOutbound(arguments[0]);",
        //         arguments: ["payload": json],
        //         in: nil,
        //         contentWorld: contentWorld
        //     )
    }

    // MARK: - Internal: inbound dispatch (testable seam)

    /// Internal entry point used by both the protocol method and the
    /// handshake/bridge XCTest suites. Extracting this off the
    /// `WKScriptMessageHandlerWithReply` method keeps tests independent of
    /// the WKScriptMessage API (which is not constructible from user code).
    func handleInboundString(_ raw: String?, replyHandler: @escaping (Any?, String?) -> Void) {
        guard let raw else {
            logger.error("bus: inbound body was not a String")
            replyHandler(nil, "bus: expected string payload")
            return
        }

        let data = Data(raw.utf8)
        let inbound: BusInbound
        do {
            inbound = try decoder.decode(BusInbound.self, from: data)
        } catch {
            logger.error("bus: inbound decode failed: \(error)")
            replyHandler(nil, "bus: decode error: \(error)")
            return
        }

        // Handshake ack is handled inline — onInbound consumers never see it.
        if case .helloAck(let version) = inbound {
            handleHelloAck(version)
            replyHandler(BusReply.success.asPlist(), nil)
            return
        }

        // Non-handshake inbound: dispatch to the caller-supplied closure.
        // Kept in a `Task` so the closure can suspend without blocking the
        // WKScriptMessageHandler thread.
        Task { @MainActor [weak self] in
            guard let self else {
                replyHandler(nil, "bus: bridge deallocated")
                return
            }
            do {
                let reply = try await self.onInbound?(inbound)
                replyHandler((reply ?? .success).asPlist(), nil)
            } catch {
                replyHandler(nil, "bus: handler error: \(error)")
            }
        }
    }

    // MARK: - Internal: handshake transitions (exposed for XCTest)

    /// Moves the state machine forward in response to a `helloAck` inbound.
    /// Internal (not fileprivate) so HandshakeTests can drive the transition
    /// directly — this is the cleanest idiomatic seam for testing an
    /// actor-ish class.
    func handleHelloAck(_ jsVersion: String) {
        timeoutTask?.cancel()
        timeoutTask = nil

        if jsVersion == BUS_PROTOCOL_VERSION {
            handshakeState = .armed
            logger.info("bus handshake armed at v\(jsVersion)")
            onHandshakeArmed?()
        } else {
            handshakeState = .mismatched(swift: BUS_PROTOCOL_VERSION, js: jsVersion)
            logger.critical("bus handshake mismatch: swift=\(BUS_PROTOCOL_VERSION) js=\(jsVersion)")
            alertPresenter(
                "Jarvis HUD couldn't start",
                "The HUD bundle was built against bus protocol v\(jsVersion); the app expects v\(BUS_PROTOCOL_VERSION). Rebuild Jarvis from source."
            )
        }
    }

    // MARK: - Private

    private func scheduleTimeout() {
        timeoutTask?.cancel()
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: HandshakeTiming.timeout)
            guard !Task.isCancelled, let self else { return }
            self.handleTimeout()
        }
    }

    private func handleTimeout() {
        // Idempotent: only fire when we're still waiting for the ack.
        guard case .sentHello = handshakeState else { return }

        logger.critical("bus handshake timeout after 2s")
        handshakeState = .timedOut
        alertPresenter(
            "Jarvis HUD couldn't start",
            "The HUD bundle did not respond to the bus handshake within 2 seconds. Rebuild Jarvis from source."
        )
    }
}

// MARK: - WKScriptMessageHandlerWithReply

extension WebviewBridge: WKScriptMessageHandlerWithReply {
    /// WebKit invokes this on the main thread, but the protocol is not
    /// annotated `@MainActor`. Under Swift 6 strict concurrency we have to
    /// assert the isolation we already have via `MainActor.assumeIsolated`
    /// — the workaround Apple documents in DevForums thread 751086.
    public nonisolated func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        MainActor.assumeIsolated {
            let body = message.body as? String
            self.handleInboundString(body, replyHandler: replyHandler)
        }
    }
}
