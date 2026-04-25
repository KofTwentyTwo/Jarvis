import XCTest
import AppKit
import WebKit
@testable import Jarvis
@testable import Bus
@testable import Config
@testable import Keychain
@testable import Shell

/// Plan 03-05 Task 2 wiring tests — asserts `AppDelegate.installBus()`
/// constructs + starts a `HudStateCoordinator`, wires its emit closure to
/// `WebviewBridge.send(.hudState(...))` via the `busHudState()` bridge, and
/// calls `coordinator.markReady()` on `onHandshakeArmed`.
///
/// These tests DO NOT attempt to launch the XCTest bundle — that path is
/// broken on Xcode 26 (02-03 SUMMARY line 220 / xctest-launch-runningboard-
/// error-5.md). They drive the delegate in-process via the same DI seams as
/// `AppDelegateBusWiringTests` from Plan 02-03. `xcodebuild build` compiles
/// them; launch-time assertions await Phase 1's test-host fix.
@MainActor
final class HudStateCoordinatorBusWiringTests: XCTestCase {
    // MARK: - Fakes (mirror AppDelegateBusWiringTests patterns)

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

    // MARK: - W1: coordinator construction

    func test_coordinatorConstructedInInstallBus() {
        let delegate = makeDelegate()
        delegate.applicationWillFinishLaunching(Notification(name: .init("t")))

        XCTAssertNotNil(
            delegate.hudStateCoordinator,
            "installBus() must construct the HudStateCoordinator and hold it on the delegate"
        )
        cleanUp(delegate)
    }

    // MARK: - W3: markReady wired to onHandshakeArmed

    func test_markReadyCalledOnHandshakeArmed() {
        let delegate = makeDelegate()
        delegate.applicationWillFinishLaunching(Notification(name: .init("t")))
        guard let coordinator = delegate.hudStateCoordinator else {
            XCTFail("coordinator required")
            return
        }
        // Coordinator starts in .booting and is pinned there until markReady.
        XCTAssertEqual(coordinator.currentStateForTests, .booting)

        // Drive a successful handshake — onHandshakeArmed fires markReady().
        delegate.webviewBridge?.handleHelloAck(BUS_PROTOCOL_VERSION)

        XCTAssertNotEqual(
            coordinator.currentStateForTests,
            .booting,
            "coordinator must promote off .booting after handshake armed → markReady"
        )
        // With no intents fired, ready-resolve lands on .idle.
        XCTAssertEqual(coordinator.currentStateForTests, .idle)
        cleanUp(delegate)
    }

    // MARK: - W4: App.HudState ↔ Bus.HudState rawValue parity

    func test_appHudStateRawValueMatchesBusHudState() {
        // If either enum gains or renames a case without the other, this
        // table-driven check fires before `busHudState(from:)` hits its
        // assertionFailure at runtime.
        // Plan 05-05 deviation (Rule 1): Adding JarvisMCP / Replay
        // framework deps to the AppTests target made unqualified
        // `HudState` ambiguous between `Jarvis.HudState` and
        // `Bus.HudState`. Qualified references restore disambiguation.
        for appCase in Jarvis.HudState.allCases {
            XCTAssertNotNil(
                Bus.HudState(rawValue: appCase.rawValue),
                "App.HudState.\(appCase.rawValue) has no matching Bus.HudState rawValue"
            )
        }
        // Reverse parity — Bus cases must all be representable in App.
        for busCase in Bus.HudState.allCases {
            XCTAssertNotNil(
                Jarvis.HudState(rawValue: busCase.rawValue),
                "Bus.HudState.\(busCase.rawValue) has no matching App.HudState rawValue"
            )
        }
        // Spot-check the helper on every App case.
        for appCase in Jarvis.HudState.allCases {
            let bus = busHudState(from: appCase)
            XCTAssertEqual(bus.rawValue, appCase.rawValue)
        }
    }

    // MARK: - W5: dormant continuations retained by delegate

    func test_dormantStreamsHeldByDelegate() {
        let delegate = makeDelegate()
        delegate.applicationWillFinishLaunching(Notification(name: .init("t")))

        XCTAssertNotNil(
            delegate.dormantAgentContinuation,
            "agent-stream continuation must be retained so coordinator.agentTask stays live"
        )
        XCTAssertNotNil(
            delegate.dormantVoiceContinuation,
            "voice-stream continuation must be retained so coordinator.voiceTask stays live"
        )
        XCTAssertNotNil(
            delegate.dormantConfirmContinuation,
            "confirm-stream continuation must be retained so coordinator.confirmTask stays live"
        )
        cleanUp(delegate)
    }

    // MARK: - W6: installBus loads index.html (not bus-harness.html)

    func test_installBusLoadsIndexNotHarness() {
        let delegate = makeDelegate()
        // Sanity — property default before installBus runs.
        delegate.webviewEntryFilename = "UNSET"

        delegate.applicationWillFinishLaunching(Notification(name: .init("t")))

        XCTAssertEqual(
            delegate.webviewEntryFilename,
            "index",
            "installBus() must set webviewEntryFilename to \"index\" — 03-05 replaced the 02-03 bus-harness.html load target"
        )
        cleanUp(delegate)
    }

    // MARK: - W2: emit closure bridges to bus send (via evaluator observation)

    /// Drives the emit closure in isolation using a standalone coordinator +
    /// a FakeJSEvaluator-backed WebviewBridge. Mirrors the 02-03
    /// WebviewBridgeOutboundTests pattern. Proves that the closure shape
    /// AppDelegate installs genuinely produces a `.hudState(busHudState(...))`
    /// payload on the outbound channel.
    func test_emitClosureBridgesToBusSend() async throws {
        // Construct a WebviewBridge with a recording evaluator so we can
        // observe the outbound `.hudState(...)` without a real WKWebView.
        let evaluator = FakeJSEvaluator()
        let controller = WKUserContentController()
        let bridge = WebviewBridge(
            evaluator: evaluator,
            userContentController: controller,
            alertPresenter: { _, _ in }
        )

        // Build the same emit closure AppDelegate installs.
        let coordinator = HudStateCoordinator(emit: { [weak bridge] appState in
            guard let bridge else { return }
            Task { @MainActor in
                try? await bridge.send(.hudState(busHudState(from: appState)))
            }
        })
        let (agentStream, agentCont) = AsyncStream<AgentHudIntent>.makeStream()
        let (voiceStream, _) = AsyncStream<VoiceHudIntent>.makeStream()
        let (confirmStream, _) = AsyncStream<ConfirmHudIntent>.makeStream()
        coordinator.start(agent: agentStream, voice: voiceStream, confirmation: confirmStream)

        // Arm the bridge so send() doesn't throw bridgeNotReady.
        bridge.startHandshake()
        bridge.handleHelloAck(BUS_PROTOCOL_VERSION)
        try await Task.sleep(for: .milliseconds(30))
        evaluator.calls.removeAll()

        // Promote off .booting → .idle. Emit fires with .idle.
        coordinator.markReady()
        try await Task.sleep(for: .milliseconds(60))

        // Drive a thinking intent → emit fires with .thinking.
        agentCont.yield(.thinking)
        try await Task.sleep(for: .milliseconds(60))

        // The evaluator should have recorded at least one `.hudState(.thinking)`
        // outbound call. Inspect every call, decode its payload, and search
        // for the expected message.
        let decoder = BusCoder.makeDecoder()
        let decodedMessages: [BusOutbound] = evaluator.calls.compactMap { call in
            guard let payload = call.arguments["payload"] as? String,
                  let data = payload.data(using: .utf8),
                  let msg = try? decoder.decode(BusOutbound.self, from: data)
            else { return nil }
            return msg
        }
        XCTAssertTrue(
            decodedMessages.contains(.hudState(.thinking)),
            "emit closure must route App.HudState.thinking → Bus.HudState.thinking via bridge.send; got \(decodedMessages)"
        )

        coordinator.cancelAll()
        // Keep the unused continuations alive to the end of the test.
        _ = agentCont
    }

    // MARK: - Fake evaluator (mirrors packages/Bus/Tests/…/FakeJSEvaluator)

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
}
