import Foundation
import AgentCore

/// Public errors surfaced by the replay subsystem. The replay log is best-effort
/// observability: per OBS-02, write failures are logged via the `replay`
/// channel but **must not** propagate into orchestrator turn semantics.
public enum ReplayError: Error, Sendable, Equatable {
    case openFailed(reason: String)
    case schemaMigrationFailed(from: Int, to: Int)
    case writeFailed(reason: String)
    case sessionNotStarted
    case turnAlreadyEnded(TurnID)
    case orphanRecoveryFailed(reason: String)
}
