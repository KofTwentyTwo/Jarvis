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

    /// Dispatch a single tool call. In Task 3 this method gains the per-server
    /// restart-mutex layer; for now (Task 2) it forwards directly to the handle.
    public func callTool(name: String, arguments: [String: Value]) async throws -> CallTool.Result {
        guard let serverName = toolToServer[name] else {
            throw JarvisMCPError.helperMissing(name: name)
        }
        guard let handle = registry[serverName] else {
            throw JarvisMCPError.helperMissing(name: name)
        }
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
}
