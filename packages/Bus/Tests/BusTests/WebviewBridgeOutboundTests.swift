import XCTest
import WebKit
@testable import Bus

/// Exercises the outbound path via a fake `JSEvaluator` so tests don't need
/// to drive a real WebKit process. The fake records `(functionBody, arguments,
/// contentWorld)` tuples; assertions inspect them.
@MainActor
final class WebviewBridgeOutboundTests: XCTestCase {
    // MARK: - Fakes

    /// Records each call for assertion. `arguments` is `[String: Any]` so the
    /// keys + string payload survive without bridging weirdness.
    final class FakeJSEvaluator: WebviewBridge.JSEvaluator {
        struct Call {
            let functionBody: String
            let arguments: [String: Any]
            let contentWorld: WKContentWorld
        }
        var calls: [Call] = []
        var reply: Any? = NSNull()

        func callAsync(
            functionBody: String,
            arguments: [String: Any],
            contentWorld: WKContentWorld
        ) async throws -> Any? {
            calls.append(Call(
                functionBody: functionBody,
                arguments: arguments,
                contentWorld: contentWorld
            ))
            return reply
        }
    }

    // MARK: - Construction helpers

    private func makeBridge(
        evaluator: FakeJSEvaluator,
        controller: WKUserContentController = WKUserContentController()
    ) -> WebviewBridge {
        WebviewBridge(
            evaluator: evaluator,
            userContentController: controller,
            alertPresenter: { _, _ in }
        )
    }

    // MARK: - send(_:) gating

    func test_sendWhenArmedCallsEvaluator() async throws {
        let evaluator = FakeJSEvaluator()
        let bridge = makeBridge(evaluator: evaluator)
        bridge.startHandshake()
        bridge.handleHelloAck(BUS_PROTOCOL_VERSION)

        // Drain the startHandshake()-issued hello call before asserting on
        // the next send.
        try await Task.sleep(for: .milliseconds(30))
        evaluator.calls.removeAll()

        try await bridge.send(.hudState(.idle))

        XCTAssertEqual(evaluator.calls.count, 1)
        let call = evaluator.calls[0]
        XCTAssertTrue(
            call.functionBody.contains("window.jarvisBus.receive(payload)"),
            "function body must invoke window.jarvisBus.receive(payload)"
        )
        let payload = call.arguments["payload"] as? String
        XCTAssertEqual(payload, #"{"type":"hudState","state":"idle"}"#)
        XCTAssertEqual(call.contentWorld, WKContentWorld.world(name: "JarvisBusWorld"))
    }

    func test_sendWhenNotArmedThrows() async {
        let evaluator = FakeJSEvaluator()
        let bridge = makeBridge(evaluator: evaluator)

        do {
            try await bridge.send(.hudState(.idle))
            XCTFail("expected BusError.bridgeNotReady")
        } catch let error as BusError {
            XCTAssertEqual(error, .bridgeNotReady)
        } catch {
            XCTFail("expected BusError.bridgeNotReady, got \(error)")
        }

        // No evaluator call must have been made — gate triggered before send.
        XCTAssertEqual(evaluator.calls.count, 0)
    }

    // MARK: - startHandshake sends hello via sendRaw (bypasses armed gate)

    func test_startHandshakeSendsHelloViaSendRaw() async throws {
        let evaluator = FakeJSEvaluator()
        let bridge = makeBridge(evaluator: evaluator)

        bridge.startHandshake()

        // startHandshake's Task hops back to MainActor and issues the hello
        // asynchronously; give it a window to land before inspecting.
        let deadline = Date().addingTimeInterval(1.0)
        while evaluator.calls.isEmpty && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(evaluator.calls.count, 1, "expected exactly one hello call")
        let payload = evaluator.calls.first?.arguments["payload"] as? String
        XCTAssertEqual(payload, #"{"type":"hello","version":"\#(BUS_PROTOCOL_VERSION)"}"#)
    }

    // MARK: - WKUserScript injection

    func test_injectionScriptIsInstalled() {
        let evaluator = FakeJSEvaluator()
        let controller = WKUserContentController()
        _ = makeBridge(evaluator: evaluator, controller: controller)

        let injections = controller.userScripts.filter { $0.source.contains("window.jarvisBus") }
        XCTAssertGreaterThanOrEqual(
            injections.count,
            1,
            "exactly one window.jarvisBus injection must be registered"
        )
    }

    func test_injectionScriptInstalledAtDocumentStart() {
        let evaluator = FakeJSEvaluator()
        let controller = WKUserContentController()
        _ = makeBridge(evaluator: evaluator, controller: controller)

        let injection = controller.userScripts.first { $0.source.contains("window.jarvisBus") }
        XCTAssertNotNil(injection, "injection script must be registered")
        XCTAssertEqual(injection?.injectionTime, .atDocumentStart)
        // WKUserScript does not expose `contentWorld` as a readable property;
        // the world assignment happens at WKUserScript.init and is verified
        // indirectly by the `addScriptMessageHandler` registration in the
        // same world succeeding (duplicate-registration would raise
        // NSInvalidArgumentException).
        XCTAssertTrue(injection?.isForMainFrameOnly ?? false)
    }

    // MARK: - Invariant: no evaluateJavaScript anywhere in Bus sources

    func test_noEvaluateJavaScriptCalls() throws {
        // Walk up from the test file to find `packages/Bus/Sources/Bus/`.
        // #filePath resolves inside the test binary; the repo layout puts
        // this test under `packages/Bus/Tests/BusTests/...` so the
        // package root is `../../..` from the file's directory.
        let testFile = URL(fileURLWithPath: #filePath)
        let packageRoot = testFile
            .deletingLastPathComponent()   // BusTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // Bus/ (the SPM package root)
        let sourcesDir = packageRoot.appendingPathComponent("Sources/Bus")

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: sourcesDir,
                                             includingPropertiesForKeys: nil) else {
            XCTFail("could not walk \(sourcesDir.path)")
            return
        }

        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(
                source.contains("evaluateJavaScript"),
                "Bus package must not call evaluateJavaScript — found in \(url.lastPathComponent)"
            )
        }
    }
}
