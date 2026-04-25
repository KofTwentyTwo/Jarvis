// ReplayingToolResultObserver.swift
//
// Production half of SEC-07 (replay captures both pre- AND post-sanitize
// bytes for every MCP dispatch) and ME-04 (orch→replay 2048-cap channel
// instantiated AND wired in production code). Plan 05-05 Task 4 + CR-02
// (REVIEW 05) closure.
//
// SEC-07 acceptance: every successful MCP dispatch (the inner
// MCPToolDispatcher fires this observer on success only — error paths are
// recorded by the orchestrator's existing throw path) sends BOTH the
// raw bytes (pre-sanitize) and the sanitized bytes (post-sanitize) into
// the orch→replay channel. The viewer (Phase 8) reconciles the two
// streams for slicing on "did the model ever see content X?".
//
// CR-02 (REVIEW 05): the observer is now the actual PRODUCER of the
// orch→replay BoundedAsyncChannel<(TurnID, ReplayEvent)>. AppDelegate's
// drain Task is the CONSUMER — it pulls events off the channel and
// calls replayLog.record(...). Previously the observer wrote directly
// to replayLog and the channel had no producer; the channel + drain
// were dead code. Now ME-04's 2048-cap .dropOldest contract is exercised
// in production traffic.

import Foundation
import AgentCore
import Replay
import JarvisMCP
import JarvisLogging
import Logging

/// Records pre-/post-sanitize bytes for every MCP dispatch into the
/// orch→replay BoundedAsyncChannel<ReplayEnvelope>. The drain Task in
/// AppDelegate consumes from this channel and writes to ReplayLog.
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

    private let replayChannel: BoundedAsyncChannel<ReplayEnvelope>
    private let turnIDResolver: @Sendable () async -> TurnID?
    private let logger: Logger

    public init(
        replayChannel: BoundedAsyncChannel<ReplayEnvelope>,
        turnIDResolver: @escaping @Sendable () async -> TurnID? = { nil }
    ) {
        self.replayChannel = replayChannel
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
        //
        // CR-02: send both writes through the orch→replay channel. The
        // drain Task in AppDelegate consumes them and calls
        // replayLog.record(...). The channel's .dropOldest policy means
        // a saturated drain (e.g., catastrophic disk I/O) drops the oldest
        // tokenDelta-class events first; tool-result writes are also
        // .dropOldest under this primitive's contract — which is fine for
        // SEC-07 (the audit trail is best-effort per OBS-02).
        await replayChannel.send(.init(
            turnId: turnId,
            event: .toolResultFull(toolUseId: toolUseId, bytes: sanitizedBytes)
        ))
        await replayChannel.send(.init(
            turnId: turnId,
            event: .toolResultFull(toolUseId: "\(toolUseId):raw", bytes: rawBytes)
        ))
    }
}

/// CR-02 (REVIEW 05): the orch→replay channel now carries
/// (TurnID, ReplayEvent) envelopes so the drain Task knows which turn the
/// event belongs to. ReplayLog.record is keyed by TurnID; without the
/// envelope, the drain would have to re-resolve the TurnID at consume
/// time, which races the orchestrator's per-turn state.
public struct ReplayEnvelope: Sendable {
    public let turnId: TurnID
    public let event: ReplayEvent
    public init(turnId: TurnID, event: ReplayEvent) {
        self.turnId = turnId
        self.event = event
    }
}
