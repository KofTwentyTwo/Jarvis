import Foundation
import AgentCore

/// Three-case outcome from `submit(_:)` / `cancelAndSubmit(_:)` (AGENT-06).
///
/// - `.ran(turnId:)` — a fresh turn started; events flow on the orchestrator's
///   `events` channel until `.turnEnd` arrives.
/// - `.superseded(priorId:newTurnId:reason:)` — a prior turn was cancelled to
///   make room and a new turn started. Returned only by `cancelAndSubmit(_:)`.
///   Carries both the prior turn's id (for replay-log correlation) and the
///   new turn's id (Phase 9 / Plan 4 / BLOCKER-1: callers append user text
///   to TurnTranscriptStore under the new turn id so MemoryExtractionCoordinator
///   sees non-nil pair text for the superseding turn).
/// - `.rejected(reason:)` — the turn could not start. The most common case in
///   P4 is `.turnInFlight` returned by `submit(_:)` while a turn is running.
public enum SubmitOutcome: Sendable, Equatable {
    case ran(turnId: TurnID)
    case superseded(priorId: TurnID, newTurnId: TurnID, reason: SupersedeReason)
    case rejected(reason: RejectReason)
}

public enum SupersedeReason: Sendable, Equatable {
    case bargedIn
    case userCancelled
}

public enum RejectReason: Sendable, Equatable {
    case turnInFlight
    case providerUnavailable
    case configError
}
