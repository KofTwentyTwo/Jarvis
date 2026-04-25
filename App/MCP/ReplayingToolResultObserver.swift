// ReplayingToolResultObserver.swift
//
// Production half of SEC-07 (replay captures both pre- AND post-sanitize
// bytes for every MCP dispatch) and ME-04 (orch→replay 2048-cap channel
// instantiated in production code). Plan 05-05 Task 4.
//
// SEC-07 acceptance: every successful MCP dispatch (the inner
// MCPToolDispatcher fires this observer on success only — error paths are
// recorded by the orchestrator's existing throw path) writes BOTH the
// raw bytes (pre-sanitize) and the sanitized bytes (post-sanitize) to
// the on-disk replay log. The viewer (Phase 8) reconciles the two streams
// for slicing on "did the model ever see content X?".
//
// ME-04 reference: Plan 04-05 deferred the production instantiation of
// the 2048-capacity BoundedAsyncChannel<ReplayEvent> behind the
// orch→replay seam (Plan 04-03 created the primitive; ChannelTopologyTests
// CT2 verified the contract). AppDelegate (Plan 05-05 Task 4) now
// instantiates `BoundedAsyncChannel(capacity: 2048, policy: .dropOldest)`
// in applicationWillFinishLaunching; this observer is the consumer-side
// glue that channel feeds (in production wiring; the resolver returns
// nil pre-orchestrator and the observer logs without writing).

import Foundation
import AgentCore
import Replay
import JarvisMCP
import JarvisLogging
import Logging

/// Records pre-/post-sanitize bytes for every MCP dispatch into the
/// ReplayLog.
///
/// The observer needs a TurnID context to correlate replay rows with the
/// in-flight turn — the orchestrator owns that context, so the observer
/// holds a closure resolver that the orchestrator updates per-turn. In
/// the (current) AppDelegate boot — where AgentOrchestrator wiring lands
/// in Phase 6 voice / Phase 7 follow-ups — the resolver returns nil and
/// the observer logs without writing. The compile-time wiring is in
/// place; future plans flip the resolver to read the orchestrator's
/// active TurnID.
public final class ReplayingToolResultObserver: ToolResultObserver, @unchecked Sendable {

    private let replayLog: ReplayLog
    private let turnIDResolver: @Sendable () async -> TurnID?
    private let logger: Logger

    public init(
        replayLog: ReplayLog,
        turnIDResolver: @escaping @Sendable () async -> TurnID? = { nil }
    ) {
        self.replayLog = replayLog
        self.turnIDResolver = turnIDResolver
        self.logger = Logger(label: JarvisLogChannel.replay.rawValue)
    }

    public func record(
        toolUseId: String,
        toolName: String,
        rawBytes: Data,
        sanitizedBytes: Data
    ) async {
        // Resolve the active TurnID — production orchestrator wiring
        // supplies this; pre-orchestrator boots return nil and the
        // observer logs without writing (ReplayEvent requires a TurnID).
        guard let turnId = await turnIDResolver() else {
            logger.debug("ToolResultObserver invoked without active TurnID — skipping replay write")
            return
        }

        // SEC-07 dual-write — sanitized bytes are the canonical
        // model-facing record; raw bytes ride a marker-suffixed
        // toolUseId so the viewer can pair the two streams without a
        // schema bump (ReplayEvent.toolResultFull is single-bytes per
        // Phase 4's closed schema).
        await replayLog.record(
            .toolResultFull(toolUseId: toolUseId, bytes: sanitizedBytes),
            for: turnId
        )
        await replayLog.record(
            .toolResultFull(toolUseId: "\(toolUseId):raw", bytes: rawBytes),
            for: turnId
        )
    }
}
