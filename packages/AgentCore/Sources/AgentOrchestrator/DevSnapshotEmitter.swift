import Foundation
import AgentCore

/// Bridges the `OrchestratorEvent` stream into a `BoundedAsyncChannel<DevSnapshot>`
/// consumed by the DevOverlay (Plan 04-05, OBS-01).
///
/// **AGENT-10 four-seam invariant** (plan_04-05, §AGENT-10): the output
/// channel has `capacity: 32, policy: .dropOldest`. DevOverlay is
/// observational — stale snapshots are fine; the replay log (OBS-02) is the
/// authoritative record.
///
/// **Single write path into each snapshot.** Every `apply` produces exactly
/// one `output.send(current)`. The last-5 tool-call ring is maintained
/// in-emitter and dedupes on `toolUseId`, so repeated updates for the same
/// tool_use don't flood the DevOverlay with duplicate rows.
///
/// **Lives in `AgentOrchestrator`, not `AgentCore`.** The plan originally
/// placed this file under `packages/AgentCore/Sources/AgentCore/`, but
/// `OrchestratorEvent` lives in the AgentOrchestrator target (Plan 04-04's
/// own Rule 3 deviation for the same dep-cycle reason). Rule 3 applied again
/// here — co-locating the emitter with its input type.
public actor DevSnapshotEmitter {
    /// Bounded observational output. AGENT-10 compliance.
    public let output: BoundedAsyncChannel<DevSnapshot>

    /// Tunable provider/model for the snapshot's header row. Plan 05+ will
    /// wire this through the orchestrator's provider factory; for P4 the
    /// emitter exposes setters so tests and the app shell can populate it.
    public var provider: String
    public var modelId: String

    // Per-turn latency tracking.
    private let clock: ContinuousClock
    private var thinkingStartedAt: ContinuousClock.Instant?
    private var firstTokenAt: ContinuousClock.Instant?

    // Last-5 ring, newest last. Dedupes on toolUseId.
    private var toolCallsRing: [ToolCallRow] = []

    // Current accumulator.
    private var current: DevSnapshot = .initial

    // Optional subscriber task for `subscribe(to:)`.
    private var subscriberTask: Task<Void, Never>?

    public init(
        provider: String = "",
        modelId: String = "",
        capacity: Int = 32,
        clock: ContinuousClock = .continuous
    ) {
        precondition(capacity > 0)
        self.provider = provider
        self.modelId = modelId
        self.clock = clock
        // AGENT-10 — observational seam, drop-oldest policy.
        self.output = BoundedAsyncChannel<DevSnapshot>(capacity: capacity, policy: .dropOldest)
        self.current = DevSnapshot.initial.with(provider: provider, modelId: modelId)
    }

    /// Convenience setter so the app shell / tests can update the header row
    /// without reaching for internal state.
    public func setProvider(provider: String, modelId: String) {
        self.provider = provider
        self.modelId = modelId
        current = current.with(provider: provider, modelId: modelId)
    }

    /// Drive the emitter from a `BoundedAsyncChannel<OrchestratorEvent>`.
    /// The subscriber task is retained on `self`; cancel via `cancel()`.
    public func subscribe(to events: BoundedAsyncChannel<OrchestratorEvent>) {
        subscriberTask?.cancel()
        let task = Task { [weak self] in
            for await event in events {
                if Task.isCancelled { break }
                guard let self = self else { break }
                await self.apply(event)
            }
        }
        subscriberTask = task
    }

    /// Stop consuming the subscribed channel (if any).
    public func cancel() {
        subscriberTask?.cancel()
        subscriberTask = nil
    }

    /// Public driver — accepts one OrchestratorEvent, updates the accumulator,
    /// and sends the new snapshot on the output channel. Tests call this
    /// directly to bypass `subscribe(to:)`.
    public func apply(_ event: OrchestratorEvent) async {
        switch event {
        case .stateChange(let state):
            if state == .thinking, thinkingStartedAt == nil {
                thinkingStartedAt = clock.now
            }
            current = current.with(state: state)

        case .tokenDelta(let turnId, _):
            // First token after .thinking → record TTFB.
            if firstTokenAt == nil, let start = thinkingStartedAt {
                let now = clock.now
                firstTokenAt = now
                let ttfb = Self.millis(from: start, to: now, clock: clock)
                current = current.with(turnId: turnId, ttfbMs: ttfb)
            } else {
                current = current.with(turnId: turnId)
            }

        case .thinkingDelta:
            // Reserved for future DevOverlay rows; not surfaced in P4.
            break

        case .toolCardUpdate(let upd):
            let row = ToolCallRow(
                id: upd.toolUseId,
                name: upd.toolName,
                status: mapStatus(upd.phase),
                durationMs: 0,
                preview: upd.resultPreview,
                error: upd.error
            )
            // Dedupe on toolUseId — latest update wins. Maintains last-5.
            if let idx = toolCallsRing.firstIndex(where: { $0.id == row.id }) {
                toolCallsRing[idx] = row
            } else {
                toolCallsRing.append(row)
            }
            while toolCallsRing.count > 5 {
                toolCallsRing.removeFirst()
            }
            current = current.with(turnId: upd.turnId, toolCalls: toolCallsRing)

        case .usage(let turnId, let usage):
            current = current.with(
                turnId: turnId,
                inputTokens: usage.inputTokens,
                outputTokens: usage.outputTokens,
                cacheCreationInputTokens: usage.cacheCreationInputTokens,
                cacheReadInputTokens: usage.cacheReadInputTokens
            )

        case .turnEnd(let turnId, _):
            let total: Int
            if let start = thinkingStartedAt {
                total = Self.millis(from: start, to: clock.now, clock: clock)
            } else {
                total = current.totalMs
            }
            current = current.with(state: .idle, turnId: turnId, totalMs: total)
            // Reset per-turn latency tracking (idempotent if turnEnd fires twice).
            thinkingStartedAt = nil
            firstTokenAt = nil

        case .error(let turnId, _):
            current = current.with(state: .idle, turnId: turnId)
            thinkingStartedAt = nil
            firstTokenAt = nil
        }
        await output.send(current)
    }

    /// Test hook — read the current accumulator without going through the
    /// output channel. Internal to the target.
    internal func _currentSnapshot() -> DevSnapshot { current }

    private func mapStatus(_ phase: ToolCardUpdate.Phase) -> ToolCallRow.Status {
        switch phase {
        case .pending:           return .pending
        case .running:           return .running
        case .awaitingApproval:  return .awaitingApproval
        case .completed:         return .completed
        case .failed:            return .failed
        }
    }

    /// Milliseconds between two ContinuousClock instants.
    private static func millis(
        from start: ContinuousClock.Instant,
        to end: ContinuousClock.Instant,
        clock: ContinuousClock
    ) -> Int {
        let dur = end - start
        let comps = dur.components
        // `components.seconds` is Int64 seconds, `attoseconds` is Int64
        // attoseconds (1e-18 s). ms = s * 1000 + atto / 1e15.
        let secondsMs = Int(comps.seconds) * 1000
        let attoMs = Int(comps.attoseconds / 1_000_000_000_000_000)
        return secondsMs + attoMs
    }
}
