import Foundation

/// Stable identifier for one orchestrator turn. Used by Plan 04-04 to
/// correlate replay log entries, DevOverlay traces, and provider events.
public struct TurnID: Sendable, Equatable, Hashable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Generate a fresh TurnID backed by a UUID.
    public static func fresh() -> TurnID {
        TurnID(rawValue: UUID().uuidString)
    }
}
