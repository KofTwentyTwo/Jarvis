import Foundation

/// Internal state machine states surfaced to DevOverlay (Plan 04-05).
///
/// The orchestrator emits `.stateChange(...)` on transitions; the bus
/// forwards these to the HUD which animates the particle ring per state.
public enum TurnState: Sendable, Equatable {
    case idle
    case booting
    case thinking
    case speaking            // reserved for P6 voice loop; never emitted in P4
    case listening           // reserved for P6 voice loop; never emitted in P4
    case awaitingConfirmation(ConfirmationID)
    case reconfiguring
}

/// Stable identifier for a confirmation prompt (`mcp-applescript` etc.).
/// P5 wires real semantics; P4 stubs the type so `TurnState` is complete.
public struct ConfirmationID: Sendable, Hashable, Equatable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}
