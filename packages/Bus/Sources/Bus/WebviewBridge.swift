import Foundation
import WebKit
import Logging
import JarvisLogging

/// Main-actor-bound bridge between Swift and the webview's JS layer.
///
/// Responsibilities:
/// - Install a `WKScriptMessageHandlerWithReply` in an isolated content world
///   (`JarvisBusWorld`) so page scripts cannot observe or post to it.
/// - Inject a `WKUserScript` at `.atDocumentStart` in the same world so
///   `window.jarvisBus` exists before any page script runs (pitfall 3).
/// - Decode inbound JSON into `BusInbound` and either (a) handle the handshake
///   ack inline or (b) route to the caller-supplied `onInbound` closure.
/// - Surface every decode/handler path through the `replyHandler` so the JS
///   side gets a `resolve` or `reject` for every `postMessage` call.
/// - Drive the two-way handshake state machine (HUD-05) with a 2s timeout.
/// - Drive outbound sends via `callAsyncJavaScript` with a primitive-string
///   `payload` argument — NEVER via `evaluateJavaScript` and NEVER with the
///   JSON concatenated into the function body (HUD-04 / T-02-13).
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
    /// `NSAlert.runModal` under XCTest. Production wiring (AppDelegate) routes
    /// this to `TCCAlertService.presentHardBlock` + `NSApp.terminate`.
    public typealias AlertPresenter = @MainActor (_ title: String, _ body: String) -> Void

    /// Test seam for `WKWebView.callAsyncJavaScript(_:arguments:in:contentWorld:)`.
    /// Production wiring uses `WKWebViewJSEvaluator`; tests use a recording
    /// fake so they don't need to spin up a real WebKit process.
    public protocol JSEvaluator: AnyObject {
        @MainActor func callAsync(
            functionBody: String,
            arguments: [String: Any],
            contentWorld: WKContentWorld
        ) async throws -> Any?
    }

    // MARK: - Configuration

    private let evaluator: JSEvaluator
    private let userContentController: WKUserContentController
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
    /// `.armed`. AppDelegate uses this to unblock outbound sends and kick off
    /// `OutboundBatcher`.
    public var onHandshakeArmed: (@MainActor () -> Void)?

    // MARK: - State

    public private(set) var handshakeState: HandshakeState = .idle

    private var timeoutTask: Task<Void, Never>?

    // MARK: - Init

    public init(
        webView: WKWebView,
        messageHandlerName: String = "jarvisBus",
        contentWorld: WKContentWorld = .page,
        alertPresenter: @escaping AlertPresenter
    ) {
        self.evaluator = WKWebViewJSEvaluator(webView: webView)
        self.userContentController = webView.configuration.userContentController
        self.messageHandlerName = messageHandlerName
        self.contentWorld = contentWorld
        self.alertPresenter = alertPresenter
        super.init()
        registerHandlerAndInjection()
    }

    /// Test-only seam — injects a fake evaluator and a caller-supplied
    /// `WKUserContentController` so tests can introspect `userScripts` without
    /// constructing a real `WKWebView`. Marked `internal` for `@testable
    /// import Bus`; production code must use the public `init(webView:…)`.
    internal init(
        evaluator: JSEvaluator,
        userContentController: WKUserContentController,
        messageHandlerName: String = "jarvisBus",
        contentWorld: WKContentWorld = .page,
        alertPresenter: @escaping AlertPresenter
    ) {
        self.evaluator = evaluator
        self.userContentController = userContentController
        self.messageHandlerName = messageHandlerName
        self.contentWorld = contentWorld
        self.alertPresenter = alertPresenter
        super.init()
        registerHandlerAndInjection()
    }

    private func registerHandlerAndInjection() {
        userContentController.addScriptMessageHandler(
            self,
            contentWorld: self.contentWorld,
            name: self.messageHandlerName
        )
        installInjectionScript()
    }

    private func installInjectionScript() {
        guard let url = Bundle.module.url(forResource: "Injection", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            logger.error("bus: Injection.js resource missing — bundle setup broken")
            return
        }
        let script = WKUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: contentWorld
        )
        userContentController.addUserScript(script)
    }

    // MARK: - Handshake surface

    /// Transitions to `.sentHello`, schedules the 2s timeout, and sends the
    /// `hello` frame over the outbound path. Called by `AppDelegate` on
    /// `WKNavigationDelegate.webView(_:didFinish:)`.
    public func startHandshake() {
        let deadline = Date().addingTimeInterval(2.0)
        handshakeState = .sentHello(deadline: deadline)
        scheduleTimeout()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.sendRaw(.hello(version: BUS_PROTOCOL_VERSION))
            } catch {
                self.logger.error("bus: failed to send hello: \(error)")
                // Don't short-circuit — let the 2s timeout Task classify this.
            }
        }
    }

    // MARK: - Outbound

    /// Public outbound send — gates on `handshakeState == .armed`, then
    /// delegates to `sendRaw`. Throws `BusError.bridgeNotReady` if called
    /// before the handshake completes.
    public func send(_ message: BusOutbound) async throws {
        guard handshakeState == .armed else {
            throw BusError.bridgeNotReady
        }
        try await sendRaw(message)
    }

    /// Raw outbound path — bypasses the armed-state gate. Used by:
    /// 1. `startHandshake` (the hello message itself is what STARTS the
    ///    handshake, so it must bypass the gate that `send(_:)` enforces).
    /// 2. `OutboundBatcher` via the `Sink` conformance — the batcher already
    ///    knows the bridge is armed (AppDelegate constructs the batcher on
    ///    `onHandshakeArmed`).
    public func sendRaw(_ message: BusOutbound) async throws {
        let data = try encoder.encode(message)
        let json = String(decoding: data, as: UTF8.self)
        _ = try await evaluator.callAsync(
            functionBody: """
            if (!window.jarvisBus || !window.jarvisBus.receive) {
                throw new Error('bus not mounted');
            }
            window.jarvisBus.receive(payload);
            return true;
            """,
            arguments: ["payload": json],
            contentWorld: contentWorld
        )
    }

    // MARK: - Internal: inbound dispatch (testable seam)

    /// Internal entry point used by both the protocol method and the
    /// handshake/bridge XCTest suites. Extracting this off the
    /// `WKScriptMessageHandlerWithReply` method keeps tests independent of
    /// the WKScriptMessage API (which is not constructible from user code).
    func handleInboundString(_ raw: String?, replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
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

// MARK: - OutboundBatcher.Sink conformance

extension WebviewBridge: OutboundBatcher.Sink {
    // sendRaw is the public API above — this extension is just the
    // protocol-conformance declaration.
}

// MARK: - JSEvaluator production adapter

/// Production `JSEvaluator` that forwards to
/// `WKWebView.callAsyncJavaScript(_:arguments:in:contentWorld:)`.
///
/// This is the ONLY call site of `callAsyncJavaScript` in the Bus package;
/// `WebviewBridge.sendRaw` composes the function body + primitive-string
/// `payload` argument and routes through this adapter. There are zero calls
/// to `evaluateJavaScript` anywhere in the Bus package (HUD-04 invariant;
/// `WebviewBridgeOutboundTests.test_noEvaluateJavaScriptCalls` enforces it).
final class WKWebViewJSEvaluator: WebviewBridge.JSEvaluator {
    private let webView: WKWebView
    init(webView: WKWebView) { self.webView = webView }

    @MainActor
    func callAsync(
        functionBody: String,
        arguments: [String: Any],
        contentWorld: WKContentWorld
    ) async throws -> Any? {
        try await webView.callAsyncJavaScript(
            functionBody,
            arguments: arguments,
            in: nil,
            contentWorld: contentWorld
        )
    }
}
