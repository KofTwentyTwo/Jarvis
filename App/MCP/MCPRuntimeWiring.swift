// MCPRuntimeWiring.swift
//
// Dependency-graph constructor for the MCP runtime chain. Plan 05-05 Task 4.
//
// Wave-5 of Phase 5 — production wiring that closes:
//   - MCP-04 / MCP-09 / AGENT-11 (the broker + presenter + dispatcher
//     chain composed end-to-end)
//   - SEC-07 (ReplayingToolResultObserver injected so pre-/post-sanitize
//     bytes both land in ReplayLog)
//   - ME-04 (Plan 04-05 deferred state — the orch→replay
//     `BoundedAsyncChannel<ReplayEvent>(capacity: 2048, policy: .dropOldest)`
//     is instantiated in production code by AppDelegate; this builder
//     returns the dispatcher chain that orchestrator consumes)
//
// Composition shape:
//
//   MCPClient                         (Plan 05-01)
//     |  register(name:binaryURL:requiresConfirmation:) × 3
//     v
//   ToolRegistry                      (Plan 05-04)
//     |
//     v
//   MCPToolDispatcher (inner)         (Plan 05-04)
//     |
//     v
//   ConfirmingToolDispatcher (outer)  (Plan 05-05)
//        |
//        v
//   ConfirmationBroker  ←→  ConfirmationPresenter
//
// Tests do not exercise this builder directly via spawning helpers — the
// `MCPRuntimeWiringTests` builds a smaller `MCPRuntime` value by hand
// against a stubbed registry to assert the wiring graph composes.

import Foundation
import AgentCore
import AgentOrchestrator
import JarvisMCP
import Replay

/// Bundle of references the AppDelegate retains for the lifetime of the
/// process. The AgentOrchestrator (added in a later plan) consumes
/// `dispatcher`; the broker / presenter / observer are kept alive here so
/// they don't deinit while a confirmation is pending.
///
/// WR-02 (REVIEW 05) lifecycle invariant: AppDelegate MUST hold MCPRuntime
/// strongly for the lifetime of the process. The orchestrator MUST NOT
/// outlive MCPRuntime. The presenter ↔ broker reference graph (presenter
/// holds broker strong, holder holds presenter strong) is acyclic only
/// because broker holds the holder, not the presenter directly. If
/// MCPRuntime is allowed to deinit while a confirmation is pending, the
/// awaiter still observes a result (broker resolves with .timeout in the
/// worst case), but the panel may flicker between states. Don't let it
/// happen.
@MainActor
public struct MCPRuntime {
    public let client: MCPClient
    public let dispatcher: any ToolDispatcher          // = ConfirmingToolDispatcher
    public let presenter: ConfirmationPresenter
    public let broker: ConfirmationBroker
    public let toolResultObserver: any ToolResultObserver
}

/// Builder for the production runtime chain.
@MainActor
public enum MCPRuntimeWiring {

    /// Production builder: spawns the three helpers, registers them with
    /// MCPClient, builds the ToolRegistry, wires the observer +
    /// dispatcher chain, and returns the MCPRuntime.
    ///
    /// CR-02 (REVIEW 05): observer now produces into the orch→replay
    /// channel; the AppDelegate drain Task is the consumer that calls
    /// `replayLog.record(...)` per drained event. This wires the four-seam
    /// AGENT-10 contract end-to-end — previously the observer wrote
    /// directly to ReplayLog and the channel was dead code.
    ///
    /// - Parameters:
    ///   - bundleURL: typically `Bundle.main.bundleURL`. Helpers live at
    ///     `<bundleURL>/Contents/Helpers/<name>.app/Contents/MacOS/<name>`.
    ///   - bus: the gateway adapter that translates the ConfirmingToolDispatcher's
    ///     bus events to the existing `BusOutbound.toolCallStart`/`toolCallEnd`.
    ///   - replayChannel: the AppDelegate-owned orch→replay 2048-cap
    ///     `.dropOldest` channel. The observer sends ReplayEnvelopes here;
    ///     AppDelegate's drain Task consumes them.
    ///   - turnIDResolver: closure the observer uses to resolve the
    ///     active TurnID at write time. Returns `nil` until the
    ///     orchestrator is wired (later plan).
    public static func build(
        bundleURL: URL,
        bus: any BusGateway,
        replayChannel: BoundedAsyncChannel<ReplayEnvelope>,
        turnIDResolver: @escaping @Sendable () async -> TurnID? = { nil }
    ) async throws -> MCPRuntime {
        let helpersDir = bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true)

        // 1. MCPClient + helper registration.
        let client = MCPClient()
        try await client.register(
            name: "mcp-time",
            binaryURL: helperBinary(in: helpersDir, name: "mcp-time"),
            requiresConfirmation: false
        )
        try await client.register(
            name: "mcp-clipboard",
            binaryURL: helperBinary(in: helpersDir, name: "mcp-clipboard"),
            requiresConfirmation: false
        )
        try await client.register(
            name: "mcp-applescript",
            binaryURL: helperBinary(in: helpersDir, name: "mcp-applescript"),
            requiresConfirmation: true
        )

        // 2. ToolRegistry built from the three known tool names.
        var registry = ToolRegistry()
        registry.register(toolName: "get_time", serverName: "mcp-time", requiresConfirmation: false)
        registry.register(toolName: "get_clipboard", serverName: "mcp-clipboard", requiresConfirmation: false)
        registry.register(toolName: "run_applescript", serverName: "mcp-applescript", requiresConfirmation: true)

        // 3. Replaying observer (SEC-07) — produces into the orch→replay
        //    channel. CR-02 wires the actual ME-04 contract end-to-end.
        let observer = ReplayingToolResultObserver(replayChannel: replayChannel, turnIDResolver: turnIDResolver)

        // 4. Inner MCPToolDispatcher (Plan 05-04).
        let inner = MCPToolDispatcher(client: client, registry: registry, observer: observer)

        // 5. Broker + presenter (cycle-broken via the holder indirection).
        let presenterHolder = ConfirmationPresenterHolder()
        let broker = ConfirmationBroker(timeoutSeconds: 60, presenter: presenterHolder)
        let presenter = ConfirmationPresenter(broker: broker)
        presenterHolder.attach(presenter)

        // 6. Args sanitizer — 256-byte truncating UTF-8 preview.
        let sanitizer: @Sendable (Data) -> String = { argsJSON in
            guard let s = String(data: argsJSON, encoding: .utf8) else { return "{}" }
            if s.utf8.count <= 256 { return s }
            let head = Data(s.utf8.prefix(256))
            return String(decoding: head, as: UTF8.self) + "…[args-truncated]"
        }

        // 7. Outer ConfirmingToolDispatcher (Plan 05-05).
        let dispatcher = ConfirmingToolDispatcher(
            inner: inner,
            broker: broker,
            bus: bus,
            argsPreviewSanitizer: sanitizer
        )

        return MCPRuntime(
            client: client,
            dispatcher: dispatcher,
            presenter: presenter,
            broker: broker,
            toolResultObserver: observer
        )
    }

    /// Test seam: assemble the dispatcher chain from pre-built parts so
    /// structural tests can assert composition without spawning helper
    /// processes. Not used in production.
    public static func compose(
        inner: any ToolDispatcher,
        bus: (any BusGateway)?,
        broker: ConfirmationBroker,
        argsPreviewSanitizer: @escaping @Sendable (Data) -> String = { _ in "{}" }
    ) -> ConfirmingToolDispatcher {
        ConfirmingToolDispatcher(
            inner: inner,
            broker: broker,
            bus: bus,
            argsPreviewSanitizer: argsPreviewSanitizer
        )
    }

    private static func helperBinary(in helpersDir: URL, name: String) -> URL {
        helpersDir
            .appendingPathComponent("\(name).app", isDirectory: true)
            .appendingPathComponent("Contents/MacOS/\(name)", isDirectory: false)
    }
}

// MARK: - Cycle-breaking presenter holder

/// Indirection so `ConfirmationBroker.init(presenter:)` can take a
/// `ConfirmationPresenting` reference while the concrete
/// `ConfirmationPresenter` (which holds a back-ref to the broker for its
/// button handlers) is constructed afterwards. Without this, the broker
/// would need a `var presenter` slot we'd assign post-init, which would
/// require the broker to be a class. The holder keeps the broker an actor.
///
/// WR-02 (REVIEW 05): `inner` is held STRONGLY now. Previously it was
/// `weak var inner` paired with `weak var broker` on
/// `ConfirmationPresenter` — both could deinit during a pending request,
/// silently breaking Approve/Deny button responses. The MCPRuntime owns
/// broker + presenter + holder; under MCPRuntime's lifetime invariant
/// (held strongly by AppDelegate) the strong reference creates no cycle.
@MainActor
public final class ConfirmationPresenterHolder: ConfirmationPresenting {
    private var inner: ConfirmationPresenter?

    public init() {}

    public func attach(_ p: ConfirmationPresenter) { self.inner = p }

    public nonisolated func show(id: UUID, toolName: String, argsPreview: String) async {
        await MainActor.run { [weak self] in
            // Broker fires-and-forgets show; we re-dispatch into the
            // presenter on MainActor. self is weak (the holder is owned
            // by MCPRuntime), but inner is strong inside the holder.
            if let inner = self?.inner {
                Task { await inner.show(id: id, toolName: toolName, argsPreview: argsPreview) }
            }
        }
    }

    public nonisolated func dismiss(id: UUID) async {
        await MainActor.run { [weak self] in
            if let inner = self?.inner {
                Task { await inner.dismiss(id: id) }
            }
        }
    }
}
