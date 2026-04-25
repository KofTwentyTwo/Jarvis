// ConfirmingToolDispatcher.swift
//
// Confirmation-gated wrapper around an inner ToolDispatcher. Plan 05-05 Task 3.
//
// Closes:
//   - MCP-04 (full — args-redaction seal pre-approval; native sheet via
//     the ConfirmationPresenter wired through ConfirmationBroker).
//   - SEC-08 (defense-in-depth args masking on the bus before user has
//     approved the tool call).
//   - AGENT-11 final wiring (.timeout outcome translates to a
//     ConfirmationError.timedOut throw and a JarvisLogChannel.mcp WARNING
//     line — synthesized deny per ROADMAP SC-3).
//
// Composition pattern: ConfirmingToolDispatcher *interposes* between the
// AgentOrchestrator and the inner MCPToolDispatcher. Both conform to the
// same `ToolDispatcher` protocol, so Plan 04-04's orchestrator code is
// unchanged.
//
// Bus seal (MCP-04 primary):
//   - For tools whose `requiresConfirmation` is true, the pre-approval
//     bus emission's argsPreview is EXACTLY `{"awaitingApproval":true}`
//     (literal). The raw `argsJSON` never reaches the bus before the user
//     has approved.
//   - Post-approval, a follow-up `updateArgsPreview` carries the
//     sanitized preview (caller-supplied closure produces it from
//     argsJSON; production wiring uses a 256-byte truncating sanitizer).
//   - HUD-side, Plan 03-04's ToolCallCard hides args while
//     `argsPreview === '{"awaitingApproval":true}'` — defense-in-depth
//     for the same invariant.

import Foundation
import AgentCore
import AgentOrchestrator
import Logging
import JarvisLogging

// MARK: - Bus surface

/// Adapter the dispatcher uses to emit the three bus events for a
/// confirmation-gated tool call. Lives in the MCP package so the
/// dispatcher doesn't depend on Bus directly; the App-level wiring
/// implements it on top of the existing `BusOutbound.toolCallStart` /
/// `toolCallEnd` cases.
///
/// CR-03 (REVIEW 05): `toolUseId` is the original String id from
/// Anthropic's `toolu_01ABCD…` / Ollama free-form id formats, NEVER a
/// UUID. The bus's `toolCallStart.id` is `String` per Phase 2's closed
/// schema; the orchestrator's tool-use record and ReplayLog both
/// correlate by this same String id. Synthesizing a UUID here would
/// break audit-trail correlation across bus / replay / orchestrator.
public protocol BusGateway: Sendable {
    /// Pre-approval emission: `argsPreview = "{\"awaitingApproval\":true}"`.
    /// Literal seal — see file-level comment.
    func emitToolCallStart(toolUseId: String, name: String, argsPreview: String) async

    /// Post-approval follow-up carrying the sanitized argsPreview. The
    /// HUD's ToolCallCard reconciles this with the prior toolCallStart by
    /// `toolUseId`.
    func updateArgsPreview(toolUseId: String, name: String, argsPreview: String) async

    /// Emitted on .deny / .timeout / .barge with `ok: false` and a
    /// human-readable reason in `previewOrError`.
    func emitToolCallEnd(toolUseId: String, name: String, ok: Bool, previewOrError: String) async
}

// MARK: - Dispatcher

public actor ConfirmingToolDispatcher: ToolDispatcher {

    private let inner: any ToolDispatcher
    private let broker: ConfirmationBroker
    private let bus: (any BusGateway)?
    private let argsPreviewSanitizer: @Sendable (Data) -> String
    private let timeoutSecondsForLogging: TimeInterval
    private let logWarning: @Sendable (String) -> Void

    /// Default warning emitter — routes to swift-log via
    /// `Logger(label: JarvisLogChannel.mcp.rawValue)`. Tests can pass a
    /// recording closure to assert the WARNING line lands on `.timeout`.
    public static let defaultLogWarning: @Sendable (String) -> Void = { msg in
        var logger = Logger(label: JarvisLogChannel.mcp.rawValue)
        logger[metadataKey: "subsystem"] = "ConfirmingToolDispatcher"
        logger.warning("\(msg)")
    }

    public init(
        inner: any ToolDispatcher,
        broker: ConfirmationBroker,
        bus: (any BusGateway)?,
        argsPreviewSanitizer: @escaping @Sendable (Data) -> String,
        timeoutSecondsForLogging: TimeInterval = 60,
        logWarning: @escaping @Sendable (String) -> Void = ConfirmingToolDispatcher.defaultLogWarning
    ) {
        self.inner = inner
        self.broker = broker
        self.bus = bus
        self.argsPreviewSanitizer = argsPreviewSanitizer
        self.timeoutSecondsForLogging = timeoutSecondsForLogging
        self.logWarning = logWarning
    }

    // MARK: ToolDispatcher conformance

    public func dispatch(toolUse: ToolUseRequest) async throws -> Data {
        // Fast path: tool does not require confirmation. No broker, no
        // awaiting-approval bus emission. Same shape Plan 04-04's
        // orchestrator already exercises.
        guard requiresConfirmation(toolName: toolUse.name) else {
            return try await inner.dispatch(toolUse: toolUse)
        }

        // Step 1 — emit awaiting-approval phase to the bus. Args are SEALED.
        //
        // CR-03 (REVIEW 05): pass the ORIGINAL toolUse.id (Anthropic
        // 'toolu_01ABC…' or Ollama free-form) verbatim to the bus. The bus
        // schema's toolUseId is String (Phase 2 closed schema); the
        // orchestrator's tool-use record and ReplayLog already correlate by
        // this same id. Previously we synthesized a fresh UUID via the SDK
        // which silently produced a fresh UUID on EVERY non-UUID id (i.e.
        // every Anthropic / Ollama call), breaking cross-system correlation.
        //
        // The broker, internally, still keys by UUID — a fresh UUID per
        // call so concurrent requests don't collide. The internal UUID
        // does NOT replace the bus-facing String id.
        let busToolUseId = toolUse.id
        // Internal correlation key for the broker FSM — independent of the
        // bus-facing String id. Fresh UUID per call; concurrent requests
        // get distinct broker entries even when their bus ids collide
        // (e.g. test fixtures using fixed strings).
        let internalCorrelationID = UUID()
        let awaitingPreview = #"{"awaitingApproval":true}"#
        await bus?.emitToolCallStart(
            toolUseId: busToolUseId,
            name: toolUse.name,
            argsPreview: awaitingPreview
        )

        // Step 2 — await broker. Broker keys by UUID internally; this is
        // independent of the bus-facing String id (CR-03).
        let outcome = await broker.request(
            id: internalCorrelationID,
            toolName: toolUse.name,
            argsPreview: awaitingPreview
        )

        // Step 3 — branch on outcome.
        switch outcome {
        case .approve:
            // Emit follow-up argsPreview carrying the sanitized real args.
            let postApprovalPreview = argsPreviewSanitizer(toolUse.argsJSON)
            await bus?.updateArgsPreview(
                toolUseId: busToolUseId,
                name: toolUse.name,
                argsPreview: postApprovalPreview
            )
            // WR-04 (REVIEW 05): on success, emit toolCallEnd(ok: true) so
            // bus consumers (HUD ToolCallCard) transition Running → Completed.
            // Previously the dispatcher only emitted toolCallEnd on failure,
            // leaving HUD stuck on Running until the orchestrator's own
            // toolCardUpdate(.completed) landed (and that surface is wired
            // separately in Phase 4). On dispatch error the result preview
            // carries the error description; the orchestrator's existing
            // throw path still records the throw verbatim.
            do {
                let resultBytes = try await inner.dispatch(toolUse: toolUse)
                let resultPreview = Self.previewForResult(resultBytes)
                await bus?.emitToolCallEnd(
                    toolUseId: busToolUseId,
                    name: toolUse.name,
                    ok: true,
                    previewOrError: resultPreview
                )
                return resultBytes
            } catch {
                await bus?.emitToolCallEnd(
                    toolUseId: busToolUseId,
                    name: toolUse.name,
                    ok: false,
                    previewOrError: String(describing: error)
                )
                throw error
            }

        case .deny:
            await bus?.emitToolCallEnd(
                toolUseId: busToolUseId,
                name: toolUse.name,
                ok: false,
                previewOrError: "denied by user"
            )
            throw ConfirmationError.denied

        case .timeout:
            // AGENT-11: .timeout IS the implementation of "synthesized deny"
            // (ROADMAP SC-3). WARNING log preserves the distinction.
            logWarning(
                "ConfirmingToolDispatcher: timeout awaiting approval for tool "
                + "\(toolUse.name) (toolUseId=\(toolUse.id))"
            )
            await bus?.emitToolCallEnd(
                toolUseId: busToolUseId,
                name: toolUse.name,
                ok: false,
                previewOrError: "approval timed out after \(Int(timeoutSecondsForLogging))s"
            )
            throw ConfirmationError.timedOut(after: timeoutSecondsForLogging)

        case .barge:
            await bus?.emitToolCallEnd(
                toolUseId: busToolUseId,
                name: toolUse.name,
                ok: false,
                previewOrError: "superseded by new turn (barge-in)"
            )
            throw ConfirmationError.barged
        }
    }

    /// 256-byte UTF-8 truncating preview of a successful tool result. Same
    /// shape the production sanitizer in MCPRuntimeWiring uses for
    /// argsPreview, applied to result bytes for the WR-04 toolCallEnd
    /// previewOrError field.
    private static func previewForResult(_ bytes: Data) -> String {
        guard let s = String(data: bytes, encoding: .utf8) else { return "(non-UTF-8 result)" }
        if s.utf8.count <= 256 { return s }
        let head = Data(s.utf8.prefix(256))
        return String(decoding: head, as: UTF8.self) + "…[result-truncated]"
    }

    public nonisolated func requiresConfirmation(toolName: String) -> Bool {
        inner.requiresConfirmation(toolName: toolName)
    }
}
