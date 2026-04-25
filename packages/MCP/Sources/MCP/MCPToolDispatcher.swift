// MCPToolDispatcher.swift
//
// Concrete `ToolDispatcher` (declared in AgentOrchestrator) that proxies
// tool invocations to MCPClient, joins all `.text` content blocks into a
// single string, runs the SEC-07 sanitize+headTruncate pipeline, and
// returns the prepared bytes.
//
// What this dispatcher does NOT do:
//
//   - Wrap with the SEC-06 nonce envelope. The orchestrator (Plan 04-04)
//     calls its own wrap step AFTER `dispatch(toolUse:)` returns. Calling
//     a wrap step here would double-wrap and corrupt the nonce-once
//     invariant. Grep gate in plan verification enforces this.
//
//   - Confirmation gating. Plan 05-05's `ConfirmingToolDispatcher`
//     interposes on top of this dispatcher and consults the HUD broker
//     before forwarding to us. We only expose `requiresConfirmation` so
//     the interposer (and the orchestrator's pre-dispatch path) can
//     branch on it.
//
//   - Replay log writes. We expose a `ToolResultObserver` callback that
//     receives both pre-sanitize and post-sanitize bytes; Plan 05-05
//     wires the actual ReplayLog writer in AppDelegate.
//
// Plan: 05-04 Task 3

import Foundation
import AgentCore
import AgentOrchestrator
import MCP

// MARK: - Client abstraction

/// Calling-side surface of `MCPClient` consumed by the dispatcher.
///
/// Extracting a protocol lets unit tests provide an in-memory mock so the
/// dispatcher's sanitize + observer behavior can be exercised without
/// spawning helper subprocesses. Production conformance is the one-liner
/// extension below.
///
/// WR-06 (REVIEW 05): `arguments` is optional matching the SDK signature.
public protocol MCPClientCalling: Sendable {
    func callTool(name: String, arguments: [String: Value]?) async throws -> CallTool.Result
}

extension MCPClient: MCPClientCalling {}

// MARK: - Result observer

/// Receives both pre-sanitize (raw bytes from helper) and post-sanitize
/// (boundary-prepared bytes the orchestrator will see) for replay capture.
///
/// SEC-07 audit-trail requirement: ReplayLog must capture BOTH streams. The
/// dispatcher emits them via this callback; Plan 05-05's app-shell wiring
/// turns the callback into ReplayLog writes.
///
/// The signature deliberately omits the per-turn nonce — that secret stays
/// inside the orchestrator. Observers receive content only, never the
/// envelope identity.
public protocol ToolResultObserver: Sendable {
    func record(
        toolUseId: String,
        toolName: String,
        rawBytes: Data,
        sanitizedBytes: Data
    ) async
}

// MARK: - Dispatcher

public actor MCPToolDispatcher: ToolDispatcher {

    private let client: any MCPClientCalling
    private nonisolated let registrySnapshot: ToolRegistry
    private let observer: (any ToolResultObserver)?

    public init(
        client: any MCPClientCalling,
        registry: ToolRegistry,
        observer: (any ToolResultObserver)? = nil
    ) {
        self.client = client
        // Value-type snapshot — captured at init time so nonisolated reads
        // (the protocol's sync requiresConfirmation) don't need an actor hop.
        self.registrySnapshot = registry
        self.observer = observer
    }

    // MARK: ToolDispatcher conformance

    public func dispatch(toolUse: ToolUseRequest) async throws -> Data {
        // WR-06 (REVIEW 05): pass `nil` (rather than `[:]`) when the
        // model emitted no args, preserving the JSON-RPC distinction
        // between `arguments: null` and `arguments: {}`. Some MCP servers
        // distinguish; the helper bundle today doesn't, but ride the
        // SDK signature for protocol fidelity.
        let arguments: [String: Value]? = toolUse.argsJSON.isEmpty
            ? nil
            : Self.decodeArguments(toolUse.argsJSON)

        // Forward to the real (or mocked) MCP client. Errors propagate.
        let result = try await client.callTool(name: toolUse.name, arguments: arguments)

        // Concatenate all .text content blocks. Other variants (image,
        // audio, resource) are out of scope for v1 — RESEARCH calls them
        // out as future work and the helper bundle today only emits .text.
        let rawText = result.content.compactMap { content -> String? in
            if case let .text(text, _, _) = content { return text }
            return nil
        }.joined(separator: "\n")

        // SEC-07 steps 1+2 (sanitize → headTruncate). Wrap is the
        // orchestrator's job, post-dispatch.
        let prepared = SanitizeForModel.prepareForBoundary(rawText, capBytes: 8192)

        // Replay-capture callback — fires only on success. Errors don't
        // produce post-sanitize bytes; the orchestrator's existing error
        // path records the throw separately.
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

    public nonisolated func requiresConfirmation(toolName: String) -> Bool {
        registrySnapshot.requiresConfirmation(toolName: toolName)
    }

    // MARK: - Argument decoding

    /// Decodes the model-emitted JSON args buffer into the SDK's `Value`
    /// dict. Tolerates empty / malformed input by returning `[:]` — the
    /// helper's `inputSchema` is the second-level guard that catches a
    /// missing required field with a structured `isError: true` response.
    private static func decodeArguments(_ json: Data) -> [String: Value] {
        guard !json.isEmpty else { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            return [:]
        }
        return toMCPValueDict(object)
    }

    private static func toMCPValueDict(_ json: [String: Any]) -> [String: Value] {
        var out: [String: Value] = [:]
        for (k, v) in json {
            out[k] = toMCPValue(v)
        }
        return out
    }

    private static func toMCPValue(_ v: Any) -> Value {
        if let s = v as? String { return .string(s) }
        if let b = v as? Bool { return .bool(b) }
        if let n = v as? Int { return .int(n) }
        if let n = v as? Double { return .double(n) }
        if let arr = v as? [Any] { return .array(arr.map(toMCPValue)) }
        if let dict = v as? [String: Any] { return .object(toMCPValueDict(dict)) }
        return .string(String(describing: v))
    }
}
