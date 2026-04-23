---
phase: 02-bus
plan: 03
type: execute
wave: 2
depends_on: [01, 02]
files_modified:
  - packages/Bus/Sources/Bus/OutboundBatcher.swift
  - packages/Bus/Sources/Bus/WebviewBridge.swift
  - packages/Bus/Sources/Bus/Resources/Injection.js
  - packages/Bus/Tests/BusTests/BatcherTests.swift
  - packages/Bus/Tests/BusTests/WebviewBridgeOutboundTests.swift
  - App/HUD/JarvisHUDPanel.swift
  - App/AppDelegate.swift
  - App/Resources/webview/bus-harness.html
  - App/Tests/AppTests/AppDelegateBusWiringTests.swift
  - project.yml
autonomous: true
requirements: [HUD-03, HUD-04, HUD-05, HUD-06]

must_haves:
  truths:
    - "`OutboundBatcher` is an `actor` that coalesces `audioLevel` and `tokenDelta` at a ~33ms window (~30Hz)"
    - "`audioLevel` uses latest-value-wins: 10 calls within 33ms produce exactly one `sendRaw(.audioLevel)` with the 10th value"
    - "`tokenDelta` uses concat: 3 calls with 'foo', 'bar', 'baz' within 33ms produce exactly one `sendRaw(.tokenDelta(text: \"foobarbaz\"))`"
    - "`flushAndSend(_:)` for state-transition events cancels pending batch, drains the buffer in-order, then sends the caller's message; order is preserved"
    - "Token stream that interleaves with a `hudState` transition preserves chronological order in the `sendRaw` sequence — no state event overtakes a pending tokenDelta"
    - "`WebviewBridge.send(_:)` is now fully wired: JSON-encode the message, hop to MainActor, call `webView.callAsyncJavaScript(\"window.jarvisBus.receive(payload); return true;\", arguments: [\"payload\": json], in: nil, contentWorld: JarvisBusWorld)` — ZERO `evaluateJavaScript` calls anywhere"
    - "`WKUserScript` at `.atDocumentStart` in `JarvisBusWorld` installs the `window.jarvisBus` stub before any page script runs (prevents 'bus not mounted' race)"
    - "`JarvisHUDPanel.webView` is exposed as a `public` property so AppDelegate can hand it to `WebviewBridge(webView:)` — the dep graph stays: App → Bus (not Bus → App)"
    - "AppDelegate constructs `WebviewBridge` during `installHUDPanel()` AFTER the panel is created, configures `onHandshakeArmed` + `alertPresenter = TCCAlertService.presentHardBlock(...) + NSApp.terminate(nil)`, and calls `panel.webView.loadFileURL(busHarnessURL, allowingReadAccessTo: busResourcesDir)` to trigger the handshake"
    - "`App/Resources/webview/bus-harness.html` + compiled `packages/bus/dist/index.js` are vendored into the app bundle via project.yml `resources`/`copyBundleResources` — loaded via `Bundle.main.url(forResource:)`"
    - "AppDelegate gates the `toggleHUD` summon on `handshakeState == .armed` — if the bus isn't armed, show a banner 'Jarvis HUD not ready' instead of popping an empty window"
  artifacts:
    - path: "packages/Bus/Sources/Bus/OutboundBatcher.swift"
      provides: "`actor OutboundBatcher` with `postAudio`, `postToken`, `flushAndSend` + 33ms scheduling"
      contains: "actor OutboundBatcher"
    - path: "packages/Bus/Sources/Bus/WebviewBridge.swift"
      provides: "Fills in the P2-01 `send(_:)` stub with the real `callAsyncJavaScript` call; adds `sendRaw(_:)` for batcher; adds `startHandshake()` sending hello via outbound path; adds `WKUserScript` injection"
      contains: "callAsyncJavaScript"
    - path: "packages/Bus/Sources/Bus/Resources/Injection.js"
      provides: "WKUserScript source that runs at document-start in JarvisBusWorld to install window.jarvisBus when the page script hasn't"
    - path: "packages/Bus/Tests/BusTests/BatcherTests.swift"
      provides: "Cadence tests: latest-wins, concat, flush-and-send, interleaved order preservation"
    - path: "packages/Bus/Tests/BusTests/WebviewBridgeOutboundTests.swift"
      provides: "Outbound tests with a fake WKWebView-ish JS evaluator; asserts `callAsyncJavaScript` called with the expected arguments"
    - path: "App/HUD/JarvisHUDPanel.swift"
      provides: "Lifts `webView` from `private` to `public` — surgical one-line change"
    - path: "App/AppDelegate.swift"
      provides: "New step in launch chain: construct WebviewBridge + startHandshake + loadFileURL + gate toggleHUD on armed"
    - path: "App/Resources/webview/bus-harness.html"
      provides: "Bundle-vendored harness HTML (build step copies from webview/ to App/Resources/webview/)"
    - path: "project.yml"
      provides: "Adds `Bus` package dep to Jarvis target; adds `App/Resources/**` to resources bundle; adds pnpm-build + resource-copy pre-build phases"
  key_links:
    - from: "packages/Bus/Sources/Bus/WebviewBridge.swift"
      to: "callAsyncJavaScript"
      via: "primitive-string `payload` argument; function body is `window.jarvisBus.receive(payload); return true;`"
      pattern: "callAsyncJavaScript"
    - from: "packages/Bus/Sources/Bus/OutboundBatcher.swift"
      to: "WebviewBridge.sendRaw"
      via: "weak reference on the actor; hops to MainActor for the JS call"
      pattern: "sendRaw"
    - from: "App/AppDelegate.swift"
      to: "WebviewBridge(webView: panel.webView, ...)"
      via: "public `webView` property on `JarvisHUDPanel`"
      pattern: "WebviewBridge\\("
    - from: "App/AppDelegate.swift"
      to: "panel.webView.loadFileURL"
      via: "Bundle.main.url(forResource: 'bus-harness', withExtension: 'html')"
      pattern: "loadFileURL"
---

<objective>
Wire the bus end-to-end at runtime. Plans 01 and 02 delivered the types +
protocol + TS side; this plan:

1. **`OutboundBatcher` actor** — 40-LOC Swift 6 actor with `Task.sleep`-based
   ~30Hz cadence. `audioLevel` latest-wins, `tokenDelta` concat, state events
   flush-then-send. Implements the HUD-06 coalescer.
2. **Real `callAsyncJavaScript` outbound path** — replaces Plan 01's stubbed
   `send(_:)` with the real primitive-string-argument call per HUD-04.
   `sendRaw(_:)` is the batcher-facing API (skips the armed-state gate for
   the hello message); `send(_:)` is the public API that gates on armed.
3. **`WKUserScript` document-start injection** — vendors the TS-compiled
   `installJarvisBus()` as a string and installs it in `JarvisBusWorld` at
   document-start via `WKUserScript`. Guarantees `window.jarvisBus.receive`
   exists before any page script loads (pitfall 3).
4. **AppDelegate wiring** — step 4a in the launch chain:
   a. After `installHUDPanel()`, construct `WebviewBridge(webView: panel.webView, ...)`
   b. Set `onHandshakeArmed` to log + enqueue a "HUD ready" state marker
   c. Set `alertPresenter` to `TCCAlertService.presentHardBlock(...)` +
      `NSApp.terminate(nil)` per RESEARCH open question #3 (terminate on mismatch)
   d. `WKNavigationDelegate.webView(_:didFinish:)` → `Task { await bridge.startHandshake() }`
   e. `panel.webView.loadFileURL(Bundle.main.url(forResource: "bus-harness", withExtension: "html", subdirectory: "webview"), allowingReadAccessTo: <subdir>)`
   f. `toggleHUD()` gates on `handshakeState == .armed`; otherwise enqueue a
      "HUD not ready" banner (non-fatal — Plan 04 catches drift at build time)
5. **Bundle resources wiring** — `project.yml` adds `App/Resources/**` to the
   Jarvis target sources list; adds a pre-build run-script phase that runs
   `pnpm --filter @jarvis/bus build` and copies `dist/*` + `bus-harness.html`
   into `App/Resources/webview/`. This is the developer-machine bundle step
   — Plan 04 adds the parity/lint checks around it.
6. **Lift `JarvisHUDPanel.webView` from private to public** — one-line surgical
   change per RESEARCH open question #4 (avoid inverting the dep graph).

Purpose: Plans 01+02 gave us the types. This plan makes the handshake
actually fire at app launch — with real NSAlert-terminate on mismatch, real
WebKit calls on success. The end-to-end chain is now live; Plan 04 hardens
it with build-time lint + parity enforcement.

Output: Two new Swift files (OutboundBatcher + Injection.js resource); one
Swift file grows (WebviewBridge fills in its outbound stub); one-line change
to `JarvisHUDPanel` (public webView); ~40 lines added to `AppDelegate`;
~20 lines added to `project.yml`; two new test files.
</objective>

<execution_context>
@~/.claude/get-shit-done/workflows/execute-plan.md
@~/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/PROJECT.md
@.planning/ROADMAP.md
@.planning/STATE.md
@.planning/phases/02-bus/02-RESEARCH.md
@.planning/phases/02-bus/02-01-swift-bus-package-PLAN.md
@.planning/phases/02-bus/02-02-ts-bus-package-PLAN.md

<!-- Prior plan outputs — these are the inputs this plan consumes. -->
@App/AppDelegate.swift
@App/HUD/JarvisHUDPanel.swift
@project.yml
@packages/Shell/Sources/Shell/TCCAlertService.swift

<interfaces>
<!-- From Plan 01 (assumed complete): WebviewBridge constructor + state -->
```swift
@MainActor
public final class WebviewBridge: NSObject {
    public init(webView: WKWebView, messageHandlerName: String = "jarvisBus",
                contentWorldName: String = "JarvisBusWorld",
                alertPresenter: @escaping AlertPresenter)
    public var onInbound: (@MainActor (BusInbound) async throws -> BusReply?)?
    public var onHandshakeArmed: (@MainActor () -> Void)?
    public private(set) var handshakeState: HandshakeState
    public func startHandshake()            // P2-01 kicked state machine only
    public func send(_ msg: BusOutbound) async throws  // P2-01 stub; this plan fills in
}
```

<!-- From Plan 02 (assumed complete): bus-harness.html + compiled dist/ -->
```
webview/packages/bus/dist/index.js     ← produced by `pnpm --filter @jarvis/bus build`
webview/packages/bus/dist/index.d.ts
webview/bus-harness.html               ← imports ./packages/bus/dist/index.js
```

<!-- From P1 (existing) — TCCAlertService pattern this plan reuses -->
```swift
public enum TCCAlertService {
    @MainActor public static func presentHardBlock(title: String, informativeText: String)
    // Shows NSAlert .critical with Quit button; does not terminate — caller follows up with NSApp.terminate(nil)
}
```

<!-- From P1 (existing) — JarvisHUDPanel with private webView -->
```swift
@MainActor
public final class JarvisHUDPanel: NSPanel {
    private var webView: WKWebView!      // this plan changes to `public var webView: WKWebView!`
    public func summon(on screen: NSScreen? = nil)
    public func dismiss()
    public var isSummoned: Bool { isVisible }
}
```
</interfaces>
</context>

<tasks>

<task type="auto" tdd="true">
  <name>Task 1: OutboundBatcher actor + WebviewBridge sendRaw/send fill-in + WKUserScript injection</name>
  <files>
    packages/Bus/Sources/Bus/OutboundBatcher.swift,
    packages/Bus/Sources/Bus/WebviewBridge.swift,
    packages/Bus/Sources/Bus/Resources/Injection.js,
    packages/Bus/Tests/BusTests/BatcherTests.swift,
    packages/Bus/Tests/BusTests/WebviewBridgeOutboundTests.swift,
    packages/Bus/Package.swift
  </files>
  <behavior>
    - Test 1 (latest-wins): `postAudio(0.3); postAudio(0.5); postAudio(0.9)` within 20ms → after 40ms, fake bridge saw exactly one `sendRaw(.audioLevel(rms: 0.9))`
    - Test 2 (concat): `postToken("foo"); postToken("bar"); postToken("baz")` within 20ms → after 40ms, fake bridge saw exactly one `sendRaw(.tokenDelta(text: "foobarbaz"))`
    - Test 3 (flush-then-send): `postToken("foo"); flushAndSend(.hudState(.speaking))` → fake bridge saw `.tokenDelta(text:"foo")` FIRST, then `.hudState(.speaking)` — order preserved
    - Test 4 (multiple windows): 10 audio + 10 token calls within 33ms → exactly 1 `sendRaw(.audioLevel)` + 1 `sendRaw(.tokenDelta)`; another 10+10 in next 33ms → another 1+1 (total 4 sends for 40 posts)
    - Test 5 (bypass): `flushAndSend(.turnStarted(id: X))` with NO pending batch → fake bridge saw exactly one `sendRaw(.turnStarted(id: X))` — no audio/token sends fabricated
    - Test 6 (send): `WebviewBridge.send(.hudState(.idle))` with `handshakeState == .armed` calls `webView.callAsyncJavaScript(...)` with `functionBody` containing `window.jarvisBus.receive(payload)` and `arguments == ["payload": "{\"type\":\"hudState\",\"state\":\"idle\"}"]` — verified via a fake `JSEvaluator` protocol seam
    - Test 7 (not armed): `WebviewBridge.send(.hudState(.idle))` with `handshakeState == .idle` throws `BusError.bridgeNotReady`
    - Test 8 (hello sent via raw): `startHandshake()` calls `sendRaw(.hello(version: "2.0.0"))` — the hello message bypasses the armed gate (it's what STARTS the handshake)
    - Test 9 (WKUserScript registered): after `WebviewBridge.init`, the `WKUserContentController.userScripts` array contains one script whose source is the contents of `Injection.js` and whose `contentWorld` is `JarvisBusWorld` at `.atDocumentStart`
  </behavior>
  <action>
    **Decisions honored:** actor + Task.sleep batcher per RESEARCH §HUD-06.
    `callAsyncJavaScript(arguments:)` with primitive string payload per HUD-04 + RESEARCH §HUD-04 sketch.
    `WKUserScript` at `.atDocumentStart` in `JarvisBusWorld` per RESEARCH §pitfall 3 + §pitfall 4.
    Terminate on mismatch per RESEARCH open question #3 (propagated into AppDelegate in Task 2).

    **Test strategy:** Introduce a `JSEvaluator` protocol for `callAsyncJavaScript`
    so tests don't need a real WebKit process. `WKWebView` conforms to it via
    a small extension. Tests use a fake that records (functionBody, arguments)
    tuples.

    **1. `packages/Bus/Sources/Bus/OutboundBatcher.swift`** — follow RESEARCH
    §HUD-06 pattern sketch:
    ```swift
    import Foundation

    /// Coalesces high-frequency outbound bus events at ~30 Hz (33 ms window).
    /// - `postAudio`: latest value wins (volume is scalar, stale values irrelevant)
    /// - `postToken`: concatenated (preserves every character, minimizes call count)
    /// - `flushAndSend`: cancel pending window, drain buffers in-order, send the caller's msg
    ///
    /// `actor` rather than `@MainActor` because per-event buffer bookkeeping
    /// does not need main-thread isolation; the final JS call hops back to
    /// MainActor via `bridge.sendRaw(_:)`.
    public actor OutboundBatcher {
        /// Protocol seam for testability — `WebviewBridge` conforms; tests use a
        /// recording fake. Declared `Sendable` so we can hold a weak reference
        /// across actor boundary.
        public protocol Sink: AnyObject, Sendable {
            @MainActor func sendRaw(_ msg: BusOutbound) async throws
        }

        private weak var sink: Sink?
        private var latestAudio: Float?
        private var pendingTokens: [String] = []
        private var scheduled: Task<Void, Never>?
        private let windowMillis: UInt64

        public init(sink: Sink, windowMillis: UInt64 = 33) {
            self.sink = sink
            self.windowMillis = windowMillis
        }

        public func postAudio(_ rms: Float) {
            latestAudio = rms
            scheduleDrainIfNeeded()
        }

        public func postToken(_ chunk: String) {
            pendingTokens.append(chunk)
            scheduleDrainIfNeeded()
        }

        /// For state-transition events (hudState, toolCall*, turnStarted/Ended,
        /// voiceEvent, confirmationRequested/Resolved). Drains the batch so
        /// order is preserved, then sends the caller's message.
        public func flushAndSend(_ msg: BusOutbound) async throws {
            scheduled?.cancel()
            scheduled = nil
            try await drainLocked()
            try await sink?.sendRaw(msg)
        }

        // MARK: - Private

        private func scheduleDrainIfNeeded() {
            guard scheduled == nil else { return }
            scheduled = Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: .milliseconds(self.windowMillis))
                guard !Task.isCancelled else { return }
                try? await self.drainAndClear()
            }
        }

        private func drainAndClear() async throws {
            try await drainLocked()
            scheduled = nil
        }

        private func drainLocked() async throws {
            if let audio = latestAudio {
                latestAudio = nil
                try await sink?.sendRaw(.audioLevel(rms: audio))
            }
            if !pendingTokens.isEmpty {
                let joined = pendingTokens.joined()
                pendingTokens.removeAll()
                try await sink?.sendRaw(.tokenDelta(text: joined))
            }
        }
    }
    ```
    Sizing note: ~60 LOC including doc comments — matches RESEARCH §HUD-06
    "40 LOC" estimate within error bars.

    **2. `packages/Bus/Sources/Bus/Resources/Injection.js`** — WKUserScript source.
    **Tradeoff chosen**: inline the `installJarvisBus` behavior directly rather
    than trying to load the compiled `dist/index.js` from inside a WKUserScript
    string. Reasons: WKUserScript bodies are evaluated as classic scripts, not
    modules; the compiled bundle is an ESM module; loading ESM at
    document-start from inside a classic-script injection is painful. The
    Injection.js is ~40 lines of JS that duplicates what `bridge.ts` does in
    TypeScript — this is acceptable duplication because (a) it's tiny, (b) the
    TS version in `dist/` is what production HUD code will use in P3, (c) the
    injection is a safety net for the P2 harness handshake.

    Full Injection.js (plain JS — not a module; no imports):
    ```javascript
    // Injected at document-start in WKContentWorld("JarvisBusWorld").
    // Installs window.jarvisBus with the minimum surface needed to complete
    // the handshake. bus-harness.html's <script type="module"> loads the full
    // TS-compiled version and REPLACES window.jarvisBus when the module
    // evaluates — but the injection ensures a handler exists even before
    // the module fetch completes (race prevention per pitfall 3).
    (function() {
        "use strict";
        if (window.jarvisBus) { return; }
        window.jarvisBus = {
            protocolVersion: "2.0.0",
            _handler: null,
            _pendingHello: null,
            receive: function(payload) {
                var msg;
                try { msg = JSON.parse(payload); }
                catch (e) {
                    console.error("[bus] parse error:", e);
                    return;
                }
                if (!msg || typeof msg.type !== "string") {
                    console.error("[bus] missing discriminator");
                    return;
                }
                if (this._handler) { this._handler(msg); return; }
                if (msg.type === "hello") {
                    this.send({ type: "helloAck", version: this.protocolVersion });
                } else {
                    this._pendingHello = msg;
                    console.warn("[bus] received before handler registered");
                }
            },
            send: function(inbound) {
                if (!window.webkit || !window.webkit.messageHandlers || !window.webkit.messageHandlers.jarvisBus) {
                    return Promise.reject(new Error("webkit.messageHandlers.jarvisBus missing"));
                }
                return window.webkit.messageHandlers.jarvisBus.postMessage(JSON.stringify(inbound));
            },
            onOutbound: function(fn) {
                this._handler = fn;
                if (this._pendingHello) {
                    fn(this._pendingHello);
                    this._pendingHello = null;
                }
            }
        };
    })();
    ```

    **3. Update `packages/Bus/Package.swift`** to include Injection.js as a
    resource. Add `resources: [.process("Resources")]` to the `Bus` target:
    ```swift
    .target(
        name: "Bus",
        dependencies: [.product(name: "JarvisLogging", package: "Logging")],
        resources: [.process("Resources")],
        swiftSettings: [.swiftLanguageMode(.v6)],
        linkerSettings: [.linkedFramework("WebKit")]
    ),
    ```
    Test target keeps `resources: [.process("Fixtures")]` from Plan 01.

    **4. Update `packages/Bus/Sources/Bus/WebviewBridge.swift`** — fill in
    `send(_:)` stub + add `sendRaw(_:)` + install WKUserScript + send hello
    via outbound path in `startHandshake()`.

    Key additions (inside `@MainActor final class WebviewBridge`):
    ```swift
    /// Protocol seam so tests don't need real WebKit. WKWebView conforms via
    /// extension below.
    public protocol JSEvaluator: AnyObject {
        @MainActor func callAsync(
            functionBody: String,
            arguments: [String: Any],
            contentWorld: WKContentWorld
        ) async throws -> Any?
    }

    // Replace `private let webView: WKWebView` with:
    private let evaluator: JSEvaluator

    // New stored property — the WKUserContentController we registered on.
    // Kept so we can remove the handler at teardown.
    private let userContentController: WKUserContentController

    // Update init to accept evaluator + inject WKUserScript.
    public init(
        webView: WKWebView,
        messageHandlerName: String = "jarvisBus",
        contentWorldName: String = "JarvisBusWorld",
        alertPresenter: @escaping AlertPresenter
    ) {
        // Extract the evaluator + controller; the WKWebView itself is still
        // stored so tests can introspect userScripts. Wrap in a test-injectable
        // initializer below.
        self.evaluator = WKWebViewJSEvaluator(webView: webView)
        self.userContentController = webView.configuration.userContentController
        self.messageHandlerName = messageHandlerName
        self.contentWorld = WKContentWorld.world(name: contentWorldName)
        self.alertPresenter = alertPresenter
        super.init()

        // Install the handler (unchanged from P2-01).
        userContentController.addScriptMessageHandler(
            self, contentWorld: self.contentWorld, name: self.messageHandlerName
        )

        // NEW: inject the document-start stub so window.jarvisBus exists
        // before any page script. Per RESEARCH §pitfall 3 + §pitfall 4.
        installInjectionScript()
    }

    /// Test-only seam — inject a fake evaluator without a real WKWebView.
    internal init(
        evaluator: JSEvaluator,
        userContentController: WKUserContentController,
        contentWorldName: String = "JarvisBusWorld",
        alertPresenter: @escaping AlertPresenter
    ) {
        self.evaluator = evaluator
        self.userContentController = userContentController
        self.messageHandlerName = "jarvisBus"
        self.contentWorld = WKContentWorld.world(name: contentWorldName)
        self.alertPresenter = alertPresenter
        super.init()
        userContentController.addScriptMessageHandler(
            self, contentWorld: self.contentWorld, name: self.messageHandlerName
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

    // New — bypasses the armed-state gate (for hello + for the batcher-facing API).
    @MainActor
    public func sendRaw(_ msg: BusOutbound) async throws {
        let data = try encoder.encode(msg)
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

    // Fill in the P2-01 stub — gates on armed, then delegates to sendRaw.
    @MainActor
    public func send(_ msg: BusOutbound) async throws {
        guard handshakeState == .armed else {
            throw BusError.bridgeNotReady
        }
        try await sendRaw(msg)
    }

    // Update startHandshake() to actually send the hello message.
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
                // Let the 2s timeout Task fire — don't short-circuit here.
            }
        }
    }

    // Extension to conform WKWebView to JSEvaluator.
    // Place at end of file.
    final class WKWebViewJSEvaluator: JSEvaluator {
        private let webView: WKWebView
        init(webView: WKWebView) { self.webView = webView }
        @MainActor
        func callAsync(
            functionBody: String,
            arguments: [String: Any],
            contentWorld: WKContentWorld
        ) async throws -> Any? {
            return try await webView.callAsyncJavaScript(
                functionBody,
                arguments: arguments,
                in: nil,
                contentWorld: contentWorld
            )
        }
    }
    ```

    Critical design note: `WKContentWorld.world(name:)` returns the same
    object for the same name, so the Injection.js and the handler both land
    in the same world instance. Do not pass `.defaultClient` — RESEARCH §pitfall 4.

    **5. `packages/Bus/Tests/BusTests/BatcherTests.swift`** — Tests for the
    six batcher behaviors listed in `<behavior>`:

    Fake sink implementation:
    ```swift
    final class FakeBusSink: OutboundBatcher.Sink {
        @MainActor var sends: [BusOutbound] = []
        @MainActor var sendCount: Int { sends.count }

        @MainActor
        func sendRaw(_ msg: BusOutbound) async throws {
            sends.append(msg)
        }
    }
    ```

    Tests (abbreviated — write all 5 fully):
    - `test_audioLevelLatestWins` — post 3 values within 20ms, `await Task.sleep(for: .milliseconds(60))`, assert `sink.sends == [.audioLevel(rms: 0.9)]`.
    - `test_tokenDeltaConcat` — post 3 tokens, sleep 60ms, assert one `.tokenDelta(text: "foobarbaz")` send.
    - `test_flushAndSendPreservesOrder` — `postToken("foo")`, then `flushAndSend(.hudState(.speaking))`, then sleep 60ms, assert `sink.sends == [.tokenDelta(text: "foo"), .hudState(.speaking)]`.
    - `test_multipleWindows` — drive 10+10 events for 33ms, wait, drive another 10+10, assert total 4 sends (2 per window).
    - `test_flushAndSendBypassesEmptyBuffer` — `flushAndSend(.turnStarted(...))` with nothing pending; assert `sink.sends.count == 1` and equals `.turnStarted`.

    **6. `packages/Bus/Tests/BusTests/WebviewBridgeOutboundTests.swift`** —
    Outbound path via fake evaluator. Uses internal init:
    ```swift
    final class FakeJSEvaluator: WebviewBridge.JSEvaluator {
        struct Call { let functionBody: String; let arguments: [String: Any]; let contentWorld: WKContentWorld }
        @MainActor var calls: [Call] = []
        @MainActor var reply: Any? = NSNull()

        @MainActor
        func callAsync(functionBody: String, arguments: [String: Any],
                       contentWorld: WKContentWorld) async throws -> Any? {
            calls.append(Call(functionBody: functionBody, arguments: arguments, contentWorld: contentWorld))
            return reply
        }
    }
    ```
    Tests:
    - `test_sendWhenArmedCallsEvaluator` — force state to `.armed`, call `send(.hudState(.idle))`, assert one call with `arguments["payload"] == "{\"type\":\"hudState\",\"state\":\"idle\"}"` and functionBody contains `window.jarvisBus.receive(payload)`.
    - `test_sendWhenNotArmedThrows` — bridge with `.idle` state, `send(.hudState(.idle))` throws `BusError.bridgeNotReady`.
    - `test_startHandshakeSendsHelloViaSendRaw` — `startHandshake()`, wait briefly, assert fake saw one call with payload `"{\"type\":\"hello\",\"version\":\"2.0.0\"}"`.
    - `test_injectionScriptIsInstalled` — bridge init, assert `userContentController.userScripts.count >= 1` and at least one script's `source` contains `window.jarvisBus`.
    - `test_injectionScriptInstalledInJarvisBusWorld` — assert the user script's `contentWorld` equals `WKContentWorld.world(name: "JarvisBusWorld")`.
    - `test_noEvaluateJavaScriptCalls` — grep the Bus package sources for `evaluateJavaScript` and assert zero hits (via `#file`-anchored directory iteration at test time OR via a compile-time `// GREP:` comment pattern + CI check). Simpler: just add a test that scans the package source directory at runtime. If that's flaky due to build layout, skip and rely on Plan 04's build-time lint.

    **TDD flow:** Write `BatcherTests` first against a stub `OutboundBatcher`
    that has the API but no scheduling → watch 5 tests fail → fill in
    `scheduleDrainIfNeeded` + `drainLocked` + `flushAndSend` → green.
    Then `WebviewBridgeOutboundTests` — stub the new methods to `throw
    BusError.bridgeNotReady` → watch tests fail → fill in `sendRaw` + real
    `send` gate + injection script install → green.
  </action>
  <verify>
    <automated>cd packages/Bus && swift test --filter BatcherTests && swift test --filter WebviewBridgeOutboundTests</automated>
  </verify>
  <done>
    Batcher tests all green — latest-wins, concat, flush-then-send, multiple windows, empty-flush bypass.
    Outbound tests green — send gates on armed, startHandshake sends hello via outbound path, injection script is registered at document-start in JarvisBusWorld.
    `grep -rn 'evaluateJavaScript' packages/Bus/Sources/` == 0 (HUD-04 invariant preserved).
    `grep -c 'callAsyncJavaScript' packages/Bus/Sources/Bus/WebviewBridge.swift` == 1 (exactly one call site, inside `WKWebViewJSEvaluator.callAsync`).
  </done>
</task>

<task type="auto" tdd="true">
  <name>Task 2: AppDelegate wiring + JarvisHUDPanel webView exposure + project.yml bundle integration</name>
  <files>
    App/HUD/JarvisHUDPanel.swift,
    App/AppDelegate.swift,
    App/Resources/webview/bus-harness.html,
    App/Tests/AppTests/AppDelegateBusWiringTests.swift,
    project.yml
  </files>
  <behavior>
    - Test 1: AppDelegate constructs a `WebviewBridge` after `installHUDPanel()` passing `panel.webView`; the bridge's `onHandshakeArmed` closure is set to a @MainActor function that records the "armed" event (verifiable via a test hook)
    - Test 2: On a simulated handshake mismatch, `alertPresenter` is invoked with a title containing "couldn't start" and a body containing both version strings ("2.0.0" and the JS version)
    - Test 3: On a simulated handshake mismatch, `NSApp.terminate(nil)` is called (verifiable via injected closure; default production behavior calls the real `NSApp.terminate`)
    - Test 4: `toggleHUD()` gates on `handshakeState == .armed`; if not armed, enqueues `BannerContent(id: "hud-not-ready", priority: 2, …)` rather than summoning an empty panel
    - Test 5: `JarvisHUDPanel.webView` is `public var` — grep-verifiable
    - Test 6: `Bundle.main.url(forResource: "bus-harness", withExtension: "html", subdirectory: "webview")` resolves at runtime (bundle resource wiring verified)
    - Test 7: `project.yml` builds successfully with the added `Bus` package dep and resources — `xcodegen` regenerates `project.pbxproj`; `xcodebuild -scheme Jarvis build` succeeds
  </behavior>
  <action>
    **Decisions honored:** Lift `webView` to public per RESEARCH open question #4.
    Terminate on mismatch per RESEARCH open question #3.
    Load harness via `Bundle.main.url` — per RESEARCH open question #5 (AppDelegate calls loadFileURL after bridge is constructed).
    `toggleHUD` gating via banner, not silent no-op — consistent with P1 SHELL-06 pattern.

    **1. `App/HUD/JarvisHUDPanel.swift`** — surgical one-line change:
    ```diff
    - private var webView: WKWebView!
    + public var webView: WKWebView!
    ```
    No other changes to the file. Do NOT rename or refactor — just lift the
    access level. Per CLAUDE.md "Surgical Changes" rule.

    **2. `App/Resources/webview/bus-harness.html`** — vendored copy of the
    harness from Plan 02. The canonical source is `webview/bus-harness.html`
    (git-tracked); the bundle copy is a build artifact. **Decision**: since
    xcodegen-driven bundles don't have a clean "build-step-driven copy", we
    commit this file under `App/Resources/webview/` AND add a pre-build
    script that re-copies from `webview/` to `App/Resources/webview/`.
    Initial commit pins the content; the build script keeps it in sync.

    Commit content of `App/Resources/webview/bus-harness.html` (same content
    as `webview/bus-harness.html` from Plan 02):
    ```html
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="UTF-8">
      <title>Jarvis Bus Harness</title>
    </head>
    <body>
      <div style="color:#888;font-size:10px;opacity:0.4;position:fixed;bottom:8px;left:8px;">
        jarvis-bus-harness v2.0.0
      </div>
      <!-- The document-start WKUserScript from packages/Bus/Resources/Injection.js
           already installed window.jarvisBus before this script runs. This
           inline script is a marker — no imports required for P2. P3 replaces
           this file with the full React bundle entrypoint. -->
      <script>
        // Harness loaded — injection already installed jarvisBus.
        if (!window.jarvisBus) {
          console.error("[bus-harness] window.jarvisBus missing — injection failed");
        } else {
          console.log("[bus-harness] armed at v" + window.jarvisBus.protocolVersion);
        }
      </script>
    </body>
    </html>
    ```

    Rationale for the change from Plan 02's version: because Plan 01/03
    install the Injection.js at `.atDocumentStart` in `JarvisBusWorld`, the
    harness itself doesn't need to import the compiled `dist/index.js` —
    the injection already created `window.jarvisBus`. This simplifies the
    bundle story (no need to bundle `dist/` inside the app — though Plan 04
    does wire that up for P3 future-proofing).

    **3. `App/AppDelegate.swift`** — add `WebviewBridge` wiring. New
    imports + new stored property + new init steps.

    Top of file, add import:
    ```swift
    import Bus
    import WebKit
    ```

    New stored property on `AppDelegate`:
    ```swift
    var webviewBridge: WebviewBridge?

    /// Test-injectable — default calls NSApp.terminate(nil); tests can
    /// replace with a recording closure.
    var onHandshakeMismatch: @MainActor () -> Void = { NSApp.terminate(nil) }
    ```

    New method to construct the bridge + kick off handshake:
    ```swift
    private func installBus() {
        guard let panel = hudPanel else {
            systemLogger?.error("installBus called before hudPanel exists")
            return
        }

        // WKNavigationDelegate hook — fire handshake on didFinish.
        panel.webView.navigationDelegate = bridgeNavigationDelegate

        let bridge = WebviewBridge(
            webView: panel.webView,
            alertPresenter: { [weak self] title, body in
                // Reuse P1 TCCAlertService pattern. The modal alert is
                // followed by test-injectable terminate.
                TCCAlertService.presentHardBlock(title: title, informativeText: body)
                self?.onHandshakeMismatch()
            }
        )
        bridge.onHandshakeArmed = { [weak self] in
            self?.systemLogger?.info("bus handshake armed — HUD ready")
            self?.onBusArmed?()
        }
        // P2 does not wire onInbound — P3 attaches the HudStateCoordinator.
        webviewBridge = bridge

        // Load the harness.
        guard let harnessURL = Bundle.main.url(
            forResource: "bus-harness",
            withExtension: "html",
            subdirectory: "webview"
        ) else {
            systemLogger?.critical("bus-harness.html missing from bundle — cannot start HUD")
            TCCAlertService.presentHardBlock(
                title: "Jarvis can't start",
                informativeText: "Bundle is missing bus-harness.html. Rebuild Jarvis from source."
            )
            NSApp.terminate(nil)
            return
        }
        let resourcesDir = harnessURL.deletingLastPathComponent()
        panel.webView.loadFileURL(harnessURL, allowingReadAccessTo: resourcesDir)
    }

    /// Test hook — called on handshake armed; default nil.
    var onBusArmed: (@MainActor () -> Void)?

    private lazy var bridgeNavigationDelegate: BridgeNavigationDelegate = {
        BridgeNavigationDelegate { [weak self] in
            self?.webviewBridge?.startHandshake()
        }
    }()
    ```

    Add inner class `BridgeNavigationDelegate` at end of file:
    ```swift
    @MainActor
    private final class BridgeNavigationDelegate: NSObject, WKNavigationDelegate {
        let onDidFinish: @MainActor () -> Void
        init(onDidFinish: @escaping @MainActor () -> Void) {
            self.onDidFinish = onDidFinish
        }
        nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            MainActor.assumeIsolated { onDidFinish() }
        }
    }
    ```

    Update the launch chain. After `installBannerPanel()` (step 4), add
    step 4.5 (before the Keychain fetch):
    ```swift
    // 4.5 Bus wiring — construct bridge, install WKUserScript, kick off
    // handshake by loading bus-harness.html.
    installBus()
    ```

    Update `toggleHUD()`:
    ```swift
    private func toggleHUD() {
        guard let panel = hudPanel else { return }
        // Gate on handshake armed — don't summon an unresponsive HUD.
        if let bridge = webviewBridge, bridge.handshakeState != .armed {
            bannerCoordinator?.enqueue(BannerContent(
                id: "hud-not-ready",
                priority: 2,
                title: "HUD not ready",
                body: "The bus handshake is still completing. Try again in a moment.",
                action: nil
            ))
            return
        }
        if panel.isSummoned { panel.dismiss() } else { panel.summon() }
    }
    ```

    **4. `project.yml`** — add the `Bus` package dep and resources. Minimal
    diff:
    ```yaml
    # Under packages:
    packages:
      Keychain: { path: packages/Keychain }
      Config: { path: packages/Config }
      Logging: { path: packages/Logging }
      Shell: { path: packages/Shell }
      Bus: { path: packages/Bus }    # NEW

    # Under targets.Jarvis.sources — existing:
    #   - path: App
    #     excludes: [Info.plist, Jarvis.entitlements, Tests/**]
    # No change needed — App/Resources/** is already swept up.

    # Under targets.Jarvis.dependencies — add:
        - package: Bus
          product: Bus

    # Under targets.Jarvis — add resource bundle for bus-harness.html:
        resources:
          - path: App/Resources
    ```

    Note: Xcodegen handles `resources:` by wiring a Resources build phase;
    the `App/Resources/webview/bus-harness.html` will land in
    `Jarvis.app/Contents/Resources/webview/bus-harness.html`, reachable via
    `Bundle.main.url(forResource: "bus-harness", withExtension: "html", subdirectory: "webview")`.

    No pre-build script for the TS bundle copy — the `App/Resources/webview/bus-harness.html`
    is committed directly. Plan 04 adds the parity-check script that ensures
    this file stays in sync with `webview/bus-harness.html`.

    **5. `App/Tests/AppTests/AppDelegateBusWiringTests.swift`** — @MainActor
    XCTest cases for the wiring. Use the existing `@testable import Jarvis`
    pattern. Key tests:

    ```swift
    @MainActor
    final class AppDelegateBusWiringTests: XCTestCase {

        override class var defaultTestSuite: XCTestSuite {
            // Bus wiring exercises a real WKWebView — skip under environments
            // where WebKit isn't available (rare on macOS; defensive).
            return super.defaultTestSuite
        }

        func test_installBusConstructsWebviewBridge() throws {
            let delegate = AppDelegate()
            delegate.entitlementProbe = EntitlementYes()
            delegate.loggingBootstrap = { }
            delegate.configLoader = { _ in (.empty, .empty) }  // adjust to actual API
            delegate.keychainStore = FakeKeychain()  // existing fake from P1 tests
            delegate.hidProbe = FakeHIDProbeGranted()  // existing from P1

            delegate.applicationWillFinishLaunching(.init(name: .init(""), object: nil))

            XCTAssertNotNil(delegate.webviewBridge)
            XCTAssertNotNil(delegate.hudPanel)
            // The harness load kicks off async nav; we can't reliably assert
            // .armed state in a fast unit test. Assert construction only.
        }

        func test_toggleHUDWhenNotArmedEnqueuesBanner() throws {
            let delegate = AppDelegate()
            // ... set up fakes like above ...
            delegate.applicationWillFinishLaunching(.init(name: .init(""), object: nil))
            // Force bridge state to idle (not armed) — use internal seam
            // OR assert via a fresh bridge that hasn't received helloAck.

            // Invoke toggleHUD — reflection or @testable exposure needed.
            // Simplest: add @testable var exposedToggleHUD: () -> Void = ... seam
            // and call it. Assert bannerCoordinator saw an enqueue of
            // BannerContent(id: "hud-not-ready", ...).
        }

        func test_handshakeMismatchCallsTerminate() throws {
            let terminateExpectation = expectation(description: "terminate called")
            let delegate = AppDelegate()
            delegate.onHandshakeMismatch = { terminateExpectation.fulfill() }
            // ... setup ...
            delegate.applicationWillFinishLaunching(.init(name: .init(""), object: nil))

            // Trigger mismatch by driving webviewBridge.handleHelloAck("1.0.0")
            // via @testable internal seam.
            delegate.webviewBridge?.handleHelloAck("1.0.0")

            wait(for: [terminateExpectation], timeout: 2.0)
            XCTAssertEqual(delegate.webviewBridge?.handshakeState,
                           .mismatched(swift: "2.0.0", js: "1.0.0"))
        }
    }
    ```

    Note on test infrastructure: the existing `AppDelegateEntitlementTests`
    and `AppDelegateWiringTests` from Plan 01 already establish the pattern
    for injecting fakes. This file follows that pattern.

    **TDD flow:** Start by writing `test_installBusConstructsWebviewBridge`
    against a stub `installBus()` that does nothing → watch test fail
    (webviewBridge is nil) → fill in `installBus()` body → green. Then
    the mismatch-terminates test. Commit RED → GREEN atomically.

    **Final check after Task 2**: run `xcodegen` to regenerate
    `Jarvis.xcodeproj/project.pbxproj`. Re-apply any PBXCopyFilesBuildPhase
    re-insertion dance per the P1 SUMMARY pattern (Plan 01-04 SUMMARY
    documents this). Verify `xcodebuild -scheme Jarvis build` succeeds.
  </action>
  <verify>
    <automated>xcodegen generate && xcodebuild -project Jarvis.xcodeproj -scheme Jarvis build -destination 'platform=macOS' -configuration Debug 2>&1 | tail -20 && xcodebuild -project Jarvis.xcodeproj -scheme Jarvis test -destination 'platform=macOS' -only-testing:JarvisAppTests/AppDelegateBusWiringTests 2>&1 | tail -30</automated>
  </verify>
  <done>
    `JarvisHUDPanel.webView` is `public var` — `grep 'public var webView' App/HUD/JarvisHUDPanel.swift` returns 1 match.
    `AppDelegate.installBus()` exists, constructs `WebviewBridge`, sets `onHandshakeArmed` + `alertPresenter` closures, and calls `panel.webView.loadFileURL(busHarnessURL, allowingReadAccessTo: resourcesDir)`.
    `toggleHUD()` gates on `handshakeState == .armed` — not armed path enqueues `BannerContent(id: "hud-not-ready", ...)`.
    `project.yml` declares `Bus` package + dep + `App/Resources` resources; `xcodegen generate` produces a project that builds clean.
    `App/Resources/webview/bus-harness.html` exists in the tree and ships into `Jarvis.app/Contents/Resources/webview/bus-harness.html` (verified by introspecting the archive OR by `Bundle.main.url(forResource:…)` returning non-nil at test time).
    `grep -rn 'evaluateJavaScript' App/` == 0 (HUD-04 invariant preserved across the whole app).
  </done>
</task>

</tasks>

<threat_model>
## Trust Boundaries

| Boundary | Description |
|----------|-------------|
| WebKit process ↔ Swift host | Crossed by every `callAsyncJavaScript` payload and every inbound `postMessage` |
| `JarvisBusWorld` ↔ page world | `WKUserScript` + handler both installed in the named world; page scripts in `.defaultClient` cannot access |
| Bundle resource boundary | `bus-harness.html` + `Injection.js` are part of the signed app bundle — tampering requires breaking codesign (P1 MCP-06 verification) |

## STRIDE Threat Register

| Threat ID | Category | Component | Disposition | Mitigation Plan |
|-----------|----------|-----------|-------------|-----------------|
| T-02-13 | Tampering | `callAsyncJavaScript` payload XSS via `</script>`/U+2028 | mitigate | Payload passes as primitive string argument; JS side calls `JSON.parse(payload)` — NEVER concatenated into function body. CodeQL swift-unsafe-js-eval clean. |
| T-02-14 | Tampering | Page script hijacks `window.jarvisBus` | mitigate | `WKUserScript` + handler both installed in `WKContentWorld.world(name: "JarvisBusWorld")`. Page scripts in the default client world cannot read/write the bus world. |
| T-02-15 | Denial of Service | Batcher unbounded buffer during handshake | accept | Plan 03 scope: handshake is 2s max; tokens/audio during handshake are few. P4 adds a bounded-buffer cap if token storms happen during startup. |
| T-02-16 | Spoofing | Non-Jarvis webview posts to the handler | mitigate | Content world isolation + the bundle-only `file://` URL means no remote/third-party origin ever loads in this webview. P1 entitlements forbid network access for the webview process at the host level. |
| T-02-17 | Elevation of Privilege | `evaluateJavaScript` slips in via copy-paste regression | mitigate | Plan 04 installs `scripts/check-no-evaluate-javascript.sh` as a build-phase lint. P2-03 invariant verified via `grep -rn 'evaluateJavaScript' App/ packages/Bus/Sources/` in the `<done>` criteria. |
| T-02-18 | Tampering | Handshake mismatch allows stale-bundle HUD to run | mitigate | Mismatch → `TCCAlertService.presentHardBlock` + `NSApp.terminate(nil)`. No code path continues after mismatch (tests assert this). |
| T-02-19 | Denial of Service | `bus-harness.html` missing from bundle | mitigate | AppDelegate `installBus()` checks `Bundle.main.url(forResource:…) != nil`; nil triggers the same hard-block path as a mismatch. Plan 04 adds a build-time check. |
</threat_model>

<verification>
**Swift tests:**
- `cd packages/Bus && swift test` — BatcherTests (5 cases) + WebviewBridgeOutboundTests (6 cases) green.
- `xcodebuild test -scheme Jarvis -only-testing:JarvisAppTests/AppDelegateBusWiringTests` — 3 new wiring cases green.

**Build check:**
- `xcodegen generate && xcodebuild -scheme Jarvis build -destination 'platform=macOS' -configuration Debug` — green.

**Lint invariants (verified here; Plan 04 enforces at build time):**
- `grep -rn 'evaluateJavaScript' App/ packages/Bus/Sources/` returns zero lines.
- `grep -c 'callAsyncJavaScript' packages/Bus/Sources/Bus/WebviewBridge.swift` == 1.
- `grep -rn 'WKScriptMessageHandlerWithReply' packages/Bus/Sources/` >= 1 (the extension); zero uses of the legacy protocol.

**Bundle resources smoke (manual, developer laptop):**
- Build → archive → inspect `Jarvis.app/Contents/Resources/webview/bus-harness.html` exists. Cold-launch from the archive — Console shows `bus handshake armed at v2.0.0`.
</verification>

<success_criteria>
1. `OutboundBatcher` actor exists with `postAudio`, `postToken`, `flushAndSend`; 5 XCTest cases green (latest-wins, concat, flush-preserves-order, multi-windows, empty-flush-bypass).
2. `WebviewBridge.send(_:)` is no longer a stub — calls `callAsyncJavaScript` with primitive-string `payload` argument when `handshakeState == .armed`.
3. `WebviewBridge.sendRaw(_:)` bypasses the armed gate — used for hello + by `OutboundBatcher`.
4. `WKUserScript` is installed at `.atDocumentStart` in `JarvisBusWorld` with source loaded from `Bus`'s bundled `Injection.js` resource.
5. `WebviewBridge.startHandshake()` sends `.hello(version: "2.0.0")` via `sendRaw` — no more state-machine-only stub.
6. `JarvisHUDPanel.webView` is `public var` — tested via grep.
7. `AppDelegate` has `installBus()` wired as a new step 4.5 in the launch chain; constructs bridge, wires `onHandshakeArmed` + `alertPresenter`, sets `WKNavigationDelegate`, calls `loadFileURL` on `bus-harness.html`.
8. `toggleHUD()` gates on `handshakeState == .armed` — not-armed path enqueues `BannerContent(id: "hud-not-ready", priority: 2, ...)`.
9. `project.yml` declares `Bus` as a package dep on the `Jarvis` target; includes `App/Resources` in the resources bundle; regenerates a building Xcode project.
10. `xcodebuild -scheme Jarvis build` succeeds on a fresh `xcodegen` regeneration.
11. `grep -rn 'evaluateJavaScript' App/ packages/Bus/Sources/` returns zero — HUD-04 invariant preserved.
12. `App/Resources/webview/bus-harness.html` exists and loads `window.jarvisBus` via the WKUserScript document-start injection.
</success_criteria>

<output>
After completion, create `.planning/phases/02-bus/02-03-SUMMARY.md` covering:
- Files created: `OutboundBatcher.swift`, `Injection.js`, `BatcherTests.swift`, `WebviewBridgeOutboundTests.swift`, `AppDelegateBusWiringTests.swift`, `App/Resources/webview/bus-harness.html`
- Files modified: `WebviewBridge.swift` (sendRaw + send + startHandshake fill-in + WKUserScript install), `JarvisHUDPanel.swift` (private → public webView), `AppDelegate.swift` (installBus + toggleHUD gate + BridgeNavigationDelegate), `project.yml` (Bus package dep + App/Resources), `packages/Bus/Package.swift` (resources: [.process("Resources")] added)
- Key decisions:
  - Actor `OutboundBatcher` with `Task.sleep(for: .milliseconds(33))` — 60 LOC matches RESEARCH §HUD-06 40-LOC estimate within error bars
  - `JSEvaluator` protocol seam so outbound tests don't need real WebKit
  - Inline injection JS (not module load) at document-start — full TS bundle is P3's concern
  - `app-bundle-committed` harness HTML (not build-copied from webview/) — parity checked at build time in Plan 04
  - Terminate on mismatch — user-injectable for tests (`onHandshakeMismatch` closure)
- Tech-stack adds: `Bus` package as first-class Jarvis target dep; `App/Resources/webview/` bundle subdirectory
- Patterns established:
  - `JSEvaluator` protocol seam for WebKit-free testing
  - `BridgeNavigationDelegate` internal-class pattern for Swift 6 `@MainActor` + `WKNavigationDelegate` `nonisolated` protocol marriage
  - `App/Resources/<subdir>/` convention for bundled web assets (P3 extends with `webview/dist/` for the R3F bundle)
- Requirements completed: HUD-04 (real callAsyncJavaScript path with primitive-string argument, zero evaluateJavaScript), HUD-06 (OutboundBatcher with coalescing cadence + flush-then-send ordering), HUD-05 (handshake actually fires at runtime with real hello→ack round trip), HUD-03 (end-to-end inbound path completed — handler wired to AppDelegate's gating behavior)
- Handoff to Plan 04: parity script checks `BUS_PROTOCOL_VERSION` + diffs fixtures + greps `evaluateJavaScript` + verifies `bus-harness.html` byte-equality between `webview/` and `App/Resources/webview/`
- Handoff to P3 (HUD): `HudStateCoordinator` attaches to `AppDelegate.webviewBridge.onInbound`; P3 replaces bus-harness.html with the real React + R3F entrypoint; `panel.webView.loadFileURL` points at the new bundle
</output>
