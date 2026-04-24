import Foundation
import AgentCore

/// Tracks the AGENT-09 stream_truncated retry budget for one logical turn.
///
/// **Bounded at 1.** A second back-to-back truncation in the same logical
/// turn is terminal: orchestrator emits `.error(... .streamTruncatedFinal)`
/// and ends the turn. No exponential backoff, no rolling window — one shot.
struct RetryState: Sendable {
    var budget: Int = 1
    var originalTurnId: TurnID

    init(originalTurnId: TurnID, budget: Int = 1) {
        self.originalTurnId = originalTurnId
        self.budget = budget
    }
}
