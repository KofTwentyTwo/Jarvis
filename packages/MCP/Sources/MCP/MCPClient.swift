// MCPClient.swift
//
// Top-level facade over the JarvisMCP layer. Hosts the registry of
// `MCPServerHandle` actors keyed by server name and the tool→server lookup
// table built from each helper's `tools/list` response. Plan 05-04 will wrap
// this into a concrete `ToolDispatcher`; for now MCPClient is consumed
// directly by 05-02 (helpers) and 05-04 (sanitize pipeline).
//
// The per-server restart mutex lives in `callTool` and is layered on top of
// each handle's `restartTask: Task<Void, Error>?` slot — concurrent callers
// awaiting a crashed helper share one in-flight restart instead of stampeding.
//
// Plan: 05-01

import Foundation
import JarvisChildSpawn
import Logging
import MCP

/// Lightweight metadata about a registered tool. Plan 05-04/05-05 consume this
/// to drive the confirmation broker (`requiresConfirmation`) and to populate
/// dispatch routing.
public struct ToolMetadata: Sendable, Equatable {
    public let name: String
    public let server: String
    public let requiresConfirmation: Bool

    public init(name: String, server: String, requiresConfirmation: Bool) {
        self.name = name
        self.server = server
        self.requiresConfirmation = requiresConfirmation
    }
}

/// Top-level facade over the JarvisMCP layer: a registry of `MCPServerHandle`
/// actors keyed by server name and a tool→server lookup table built from each
/// helper's `tools/list` response.
///
/// `register(name:binaryURL:requiresConfirmation:)` spawns a helper as a
/// child process via `ChildSpawnGate`, awaits its initialize handshake, calls
/// `tools/list`, and inserts the returned tools into the lookup table.
/// `callTool(name:arguments:)` resolves the server, takes the per-server
/// restart mutex (so concurrent callers awaiting a crashed helper share one
/// in-flight restart instead of stampeding), and dispatches.
///
/// ## Threading
/// Actor isolation. Per-server `restartTask: Task<Void, Error>?` slot lives
/// on `MCPServerHandle`; the mutex is layered on top in `callTool`.
///
/// ## See also
/// - `MCPRuntimeWiring.build` (in `App/MCP/`) — the production composition
/// - `ConfirmingToolDispatcher` — wraps this client to gate confirmations
/// - `JarvisChildSpawn.ChildSpawnGate` — the FD/env-hardened spawn primitive
public actor MCPClient {
    private var registry: [String: MCPServerHandle] = [:]
    private var toolToServer: [String: String] = [:]
    private let logger: Logger

    public init(logger: Logger = MCPLogChannel.logger(label: "client")) {
        self.logger = logger
    }

    // MARK: - Registration

    /// Spawns the helper at `binaryURL`, completes initialize, and indexes the
    /// helper's tool list into the registry.
    public func register(name: String, binaryURL: URL, requiresConfirmation: Bool) async throws {
        try await register(
            name: name,
            binaryURL: binaryURL,
            requiresConfirmation: requiresConfirmation,
            extraEnvironment: [:]
        )
    }

    /// Test-friendly overload allowing the caller to layer environment overrides
    /// (e.g. `MOCK_HELPER_CRASH_AFTER`) on top of `ChildSpawnGate.minimalEnvironment`.
    /// Production helpers should use the public `register(name:binaryURL:requiresConfirmation:)`.
    public func register(
        name: String,
        binaryURL: URL,
        requiresConfirmation: Bool,
        extraEnvironment: [String: String]
    ) async throws {
        let handle = MCPServerHandle(
            name: name,
            binaryURL: binaryURL,
            requiresConfirmation: requiresConfirmation,
            extraEnvironment: extraEnvironment
        )
        try await handle.start()

        let listed = try await handle.listTools()
        registry[name] = handle
        for tool in listed.tools {
            toolToServer[tool.name] = name
        }
        logger.info("registered MCP helper '\(name)' with \(listed.tools.count) tool(s)")
    }

    // MARK: - Tool dispatch

    /// Dispatch a single tool call. Layers the per-server restart mutex on top
    /// of the handle's `restartTask` slot:
    ///
    ///   1. If a restart is already in flight for this server, await it.
    ///   2. Else if the handle is crashed, atomically claim-or-share the slot
    ///      via `MCPServerHandle.claimOrShareRestart`. The claimant runs
    ///      start(); sharers await the existing task.
    ///   3. Dispatch through the SDK client.
    ///
    /// Concurrent callers on a crashed server therefore share ONE in-flight
    /// restart Task rather than stampeding the spawn path. On restart failure,
    /// the slot is cleared so a subsequent call can attempt again. (We do not
    /// add backoff/retry here — RESEARCH A5: failed restart propagates;
    /// hardening is a future plan.)
    /// WR-06 (REVIEW 05): `arguments` is optional, matching the SDK's
    /// `Client.callTool(name:arguments:)` signature. Tools registered with
    /// empty `inputSchema.required` (get_time, get_clipboard) accept `null`
    /// arguments per JSON-RPC; callers no longer need to pass `[:]`.
    /// Some MCP servers distinguish `arguments: null` (no args provided)
    /// from `arguments: {}` (empty arg dict); the wrapper preserves that
    /// distinction now.
    public func callTool(name: String, arguments: [String: Value]? = nil) async throws -> CallTool.Result {
        guard let serverName = toolToServer[name] else {
            throw JarvisMCPError.helperMissing(name: name)
        }
        guard let handle = registry[serverName] else {
            throw JarvisMCPError.helperMissing(name: name)
        }

        // 1. If a restart is already in flight, share it.
        if let inFlight = await handle.restartTask {
            try await inFlight.value
        }

        // 2. If still crashed, atomically claim or share the restart slot.
        //    The claim-or-share decision happens under the handle actor's
        //    isolation, so concurrent callers can't both fall through to
        //    spawn fresh start() tasks.
        if await handle.isCrashed {
            // The closure builds a Task only if claimOrShareRestart picks "claim".
            // Implementation note: claimOrShareRestart is a sync method on the
            // actor; the closure is invoked synchronously inside the actor's
            // executor before returning, so the Task is created on the right
            // executor and the slot is committed atomically with isCrashed/
            // restartTask checks.
            let outcome = await handle.claimOrShareRestart {
                Task { try await handle.start() }
            }
            if outcome.claimed, let task = outcome.task {
                do {
                    try await task.value
                    await handle.setRestartTask(nil)
                } catch {
                    // Clear the slot so a future call can try again. The error
                    // propagates verbatim — caller sees the underlying spawn
                    // failure.
                    await handle.setRestartTask(nil)
                    throw error
                }
            } else if let shared = outcome.task {
                // Another caller already claimed; await their restart.
                try await shared.value
            }
            // outcome.task == nil → handle is no longer crashed (a third
            // caller completed restart and cleared the slot before we got
            // here). Fall through to dispatch.
        }

        // 3. Dispatch.
        return try await handle.callTool(name: name, arguments: arguments)
    }

    // MARK: - Introspection

    public func toolMetadata(_ name: String) -> ToolMetadata? {
        guard let server = toolToServer[name],
              let handle = registry[server]
        else { return nil }
        return ToolMetadata(
            name: name,
            server: server,
            requiresConfirmation: handle.requiresConfirmation
        )
    }

    public func registeredServerNames() -> [String] {
        Array(registry.keys)
    }

    public func registeredToolNames() -> [String] {
        Array(toolToServer.keys)
    }

    // MARK: - Teardown

    public func shutdown() async {
        for (_, handle) in registry {
            await handle.shutdown()
        }
        registry.removeAll()
        toolToServer.removeAll()
    }

    // MARK: - Test-only inspection

    #if DEBUG
    /// Test-only accessor into the registry. Used by restart-mutex tests that
    /// need to SIGKILL the helper PID directly. NOT for production use.
    /// Gated by `@_spi(Testing)` so callers must opt in via
    /// `@_spi(Testing) import JarvisMCP` (used by tests via `@testable` and
    /// by the eval `Harness` package). Plain `import JarvisMCP` cannot see it.
    @_spi(Testing) public func _testHandle(named name: String) -> MCPServerHandle? {
        registry[name]
    }
    #endif
}
