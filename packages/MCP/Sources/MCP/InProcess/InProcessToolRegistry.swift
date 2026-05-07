import Foundation
import os.lock
import AgentCore

/// Sync-accessible cache of in-process tool names that require confirmation.
///
/// Plan 10-02c (B-01b): the new `InProcessAwareToolDispatcher` composite
/// must answer `nonisolated func requiresConfirmation(toolName:)` synchronously
/// to satisfy the `ToolDispatcher` protocol contract that the surrounding
/// `ConfirmingToolDispatcher` already calls into. Reading from the actor-bound
/// `InProcessToolRegistry.tools` would require an `await`, which the protocol
/// doesn't allow. This lock-protected `Set<String>` mirrors the registry's
/// confirmation flags and is updated by `register(_:)`.
///
/// Class (not struct) so the registry and the composite share a single
/// reference; class is `@unchecked Sendable` because all mutation is gated
/// by the unfair lock.
public final class InProcessConfirmationCache: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: Set<String>())

    public init() {}

    /// Insert `name` if `requiresConfirmation` is true; otherwise remove it.
    /// Idempotent — registering the same tool twice (re-keying) keeps the
    /// cache consistent with the registry's last-write-wins semantics.
    public func insert(_ name: String, requiresConfirmation: Bool) {
        state.withLock { set in
            if requiresConfirmation {
                set.insert(name)
            } else {
                set.remove(name)
            }
        }
    }

    /// Sync read — used by `InProcessAwareToolDispatcher.requiresConfirmation(toolName:)`
    /// from a `nonisolated` context.
    public func contains(_ name: String) -> Bool {
        state.withLock { $0.contains(name) }
    }

    /// Snapshot for tests.
    public func names() -> Set<String> {
        state.withLock { $0 }
    }
}

/// Holds [String: any InProcessTool] and dispatches CallTool requests by name.
/// AppDelegate (Plan 07-06) builds one and injects it alongside the existing
/// MCPRuntimeWiring helper-spawn registration.
public actor InProcessToolRegistry {

    private var tools: [String: any InProcessTool] = [:]

    /// Plan 10-02c (B-01b): sync-accessible mirror of which registered tools
    /// require confirmation. Shared with `InProcessAwareToolDispatcher` so
    /// its `nonisolated func requiresConfirmation(toolName:)` can answer
    /// synchronously without an actor hop. Updated by `register(_:)`.
    public nonisolated let confirmationCache: InProcessConfirmationCache

    public init() {
        self.confirmationCache = InProcessConfirmationCache()
    }

    public func register(_ tool: any InProcessTool) {
        tools[tool.name] = tool
        // Mirror the confirmation flag into the sync cache so the composite
        // dispatcher can read it from a nonisolated context.
        confirmationCache.insert(tool.name, requiresConfirmation: tool.requiresConfirmation)
    }

    public func registered() -> [any InProcessTool] {
        Array(tools.values)
    }

    public func contains(_ name: String) -> Bool {
        tools[name] != nil
    }

    public func dispatch(_ name: String, args: Data) async throws -> Data {
        guard let tool = tools[name] else {
            throw InProcessToolError.unknownTool(name)
        }
        return try await tool.call(args: args)
    }

    /// Plan 10-02b / B-01: project every registered in-process tool to a
    /// `ToolSchema` (name + human-readable description + JSON-schema bytes)
    /// suitable for the Anthropic / Ollama tools[] payload. Returned in
    /// stable name-sorted order so request bodies are deterministic across
    /// turns (helpful for prompt caching and snapshot tests).
    public func toolSchemas() -> [ToolSchema] {
        tools.values
            .map { tool in
                ToolSchema(
                    name: tool.name,
                    description: tool.toolDescription,
                    inputSchema: tool.schemaJSON
                )
            }
            .sorted { $0.name < $1.name }
    }
}
