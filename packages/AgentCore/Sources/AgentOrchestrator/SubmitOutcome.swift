import Foundation
import AgentCore

/// Three-case outcome from `submit(_:)` / `cancelAndSubmit(_:)` (AGENT-06).
///
/// - `.ran(turnId:)` — a fresh turn started; events flow on the orchestrator's
///   `events` channel until `.turnEnd` arrives.
/// - `.superseded(priorId:reason:)` — a prior turn was cancelled to make room.
///   Returned only by `cancelAndSubmit(_:)`. Carries the prior turn's id so
///   callers can correlate replay-log entries.
/// - `.rejected(reason:)` — the turn could not start. The most common case in
///   P4 is `.turnInFlight` returned by `submit(_:)` while a turn is running.
public enum SubmitOutcome: Sendable, Equatable {
    case ran(turnId: TurnID)
    case superseded(priorId: TurnID, reason: SupersedeReason)
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
