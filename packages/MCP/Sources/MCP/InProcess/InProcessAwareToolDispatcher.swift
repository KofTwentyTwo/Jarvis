// InProcessAwareToolDispatcher.swift
//
// Plan 10-02c (B-01b) — composite ToolDispatcher that name-routes either to
// an `InProcessToolRegistry` (memory tools + four self-knowledge tools) or
// to a fallback inner dispatcher (typically `MCPToolDispatcher` backed by
// stdio MCP helpers).
//
// Why this exists:
//   - Plan 10-02b wired tool catalog ENUMERATION so the model receives
//     schemas for both stdio and in-process tools. That fix made the model
//     emit real `tool_use` blocks instead of hallucinating JSON in chat.
//   - But `MCPToolDispatcher` (the previous inner dispatcher) only knows
//     about the 3 stdio tools. When the model dispatched `get_active_audio_route`,
//     the inner dispatcher failed and the failure surfaced as visible chat
//     text ("the audio route tools are erroring out on this end").
//
// Composition shape (post-fix):
//
//   AgentOrchestrator
//     ↓
//   ConfirmingToolDispatcher           (Plan 05-05; outer; confirmation gate, bus emission, observer)
//     ↓
//   InProcessAwareToolDispatcher       (THIS FILE; composite; in-process vs stdio name routing)
//     ↓                ↓
//   InProcessToolRegistry         MCPToolDispatcher  (Plan 05-04; stdio fallthrough)
//                                     ↓
//                                   MCPClient
//
// Confirmation gating preserved: ConfirmingToolDispatcher remains the SINGLE
// outer wrapper. Its `inner.requiresConfirmation(toolName:)` query reaches
// the composite, which checks both the in-process confirmation cache AND
// (via fallthrough) the inner stdio registry. `forget_fact` (the only
// in-process tool with `requiresConfirmation:true` today) routes through the
// same broker as `run_applescript`.
//
// Plan: 10-02c Task 3.

import Foundation
import AgentCore
import AgentOrchestrator

/// Composite ToolDispatcher: name-lookup routes to either the in-process
/// registry or an inner stdio dispatcher.
///
/// - Sync-accessible confirmation lookup: the composite's
///   `requiresConfirmation(toolName:)` reads from a lock-protected
///   `InProcessConfirmationCache` (shared with the registry) for in-process
///   tools, and falls through to the inner dispatcher's confirmation lookup
///   for stdio tools.
///
/// - Tools registered AFTER composite construction are still routable: the
///   composite holds the registry reference (an actor), so its `contains`
///   query against the live registry sees every registration regardless of
///   the install-task ordering.
public actor InProcessAwareToolDispatcher: ToolDispatcher {

    private let inProcessRegistry: InProcessToolRegistry
    private nonisolated let confirmationCache: InProcessConfirmationCache
    private let inner: any ToolDispatcher
    private let observer: (any ToolResultObserver)?

    public init(
        inProcessRegistry: InProcessToolRegistry,
        confirmationCache: InProcessConfirmationCache,
        inner: any ToolDispatcher,
        observer: (any ToolResultObserver)? = nil
    ) {
        self.inProcessRegistry = inProcessRegistry
        self.confirmationCache = confirmationCache
        self.inner = inner
        self.observer = observer
    }

    // MARK: ToolDispatcher conformance

    public func dispatch(toolUse: ToolUseRequest) async throws -> Data {
        // Route by name lookup. The registry's `contains` is async (actor-isolated)
        // — that's fine because dispatch itself is async. Sync confirmation
        // queries hit the lock-protected confirmationCache below.
        if await inProcessRegistry.contains(toolUse.name) {
            // In-process path. Run the tool, then apply the SAME sanitize
            // pipeline as the stdio path (`prepareForBoundary` caps at 8 KB
            // and strips zero-width / bidi-control characters).
            let rawBytes = try await inProcessRegistry.dispatch(
                toolUse.name,
                args: toolUse.argsJSON
            )
            let rawText = String(data: rawBytes, encoding: .utf8) ?? ""
            let prepared = SanitizeForModel.prepareForBoundary(rawText, capBytes: 8192)

            // Observer parity with stdio path: ReplayLog captures both pre-
            // and post-sanitize bytes for every tool call regardless of route.
            if let observer = observer {
                await observer.record(
                    toolUseId: toolUse.id,
                    toolName: toolUse.name,
                    rawBytes: Data(rawText.utf8),
                    sanitizedBytes: Data(prepared.utf8)
                )
            }

            return Data(prepared.utf8)
        }

        // Stdio fallthrough. The inner dispatcher (typically MCPToolDispatcher)
        // already handles its own sanitize + observer pipeline; we don't
        // double-wrap.
        return try await inner.dispatch(toolUse: toolUse)
    }

    public nonisolated func requiresConfirmation(toolName: String) -> Bool {
        // 1. In-process confirmation lookup (sync, lock-protected).
        if confirmationCache.contains(toolName) {
            return true
        }
        // 2. Fall through to the inner stdio dispatcher's lookup.
        // The inner dispatcher returns false for names it doesn't know,
        // which is the correct behavior: an unknown tool can't require
        // confirmation; dispatch will throw later.
        return inner.requiresConfirmation(toolName: toolName)
    }
}
