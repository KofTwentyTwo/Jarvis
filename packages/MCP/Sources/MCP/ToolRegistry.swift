// ToolRegistry.swift
//
// Tool→server lookup table + `requiresConfirmation` flag, kept as a value
// type so MCPToolDispatcher can capture a `nonisolated let` snapshot and
// satisfy the protocol's synchronous `requiresConfirmation(toolName:)`
// without an actor hop. The orchestrator calls `requiresConfirmation`
// from arbitrary contexts (HUD pre-confirmation gating in Plan 05-05);
// keeping it sync avoids artificial async coloring of caller code.
//
// Last-write-wins on duplicate `register` (no error). v1 has no
// runtime tool deregistration path; tools are registered once at app
// boot and never removed until shutdown.
//
// Plan: 05-04 Task 2

import Foundation

public struct ToolRegistry: Sendable {

    private struct Entry: Sendable {
        let serverName: String
        let requiresConfirmation: Bool
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    public mutating func register(
        toolName: String,
        serverName: String,
        requiresConfirmation: Bool
    ) {
        entries[toolName] = Entry(
            serverName: serverName,
            requiresConfirmation: requiresConfirmation
        )
    }

    public func server(forTool toolName: String) -> String? {
        entries[toolName]?.serverName
    }

    public func requiresConfirmation(toolName: String) -> Bool {
        entries[toolName]?.requiresConfirmation ?? false
    }

    /// Sorted for stability — `toolNames` is consumed by tests + future
    /// HUD tool-list panels where deterministic order matters.
    public var toolNames: [String] {
        entries.keys.sorted()
    }
}
