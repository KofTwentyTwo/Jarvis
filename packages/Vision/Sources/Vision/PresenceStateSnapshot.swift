import Foundation

/// Stores the latest PresenceEvent observation for ambient context enrichment.
///
/// VISION-03 boundary: this actor returns ONLY `String?` from
/// `currentEnrichment(now:)`. Never exposes PresenceEvent values, never
/// references the speech-synthesis layer or the agent loop. Consumers in
/// the App / agent layer read the rendered sentence and append it to the
/// system prompt; they have no way to turn presence into a speech-trigger
/// or a turn-trigger.
///
/// D-13: process-wide singleton (mirrors the bus-singleton pattern from
/// Phase 7). The `.shared` instance is what `ContextBuilder.installPresence`
/// writes to and what App-side install code passes to the agent layer.
public actor PresenceStateSnapshot {
    public static let shared = PresenceStateSnapshot()

    private var latest: PresenceEvent?
    private var observedAt: Date?

    public init() {}

    /// Record the latest PresenceEvent + the wall-clock observation time.
    /// Called by `ContextBuilder.installPresence` as it drains
    /// `PresenceSignalBus.stream`.
    public func record(_ event: PresenceEvent) {
        self.latest = event
        self.observedAt = Date()
    }

    /// D-14: returns a plain sentence to append to the system prompt, or
    /// nil to suppress injection entirely.
    ///
    /// Rules:
    /// - .present, observation < 5 seconds → nil (avoid noise on every turn)
    /// - .present, observation ≥ 5 seconds → "User is at the desk."
    /// - .absent(since:), elapsed < 5 minutes (D-11 threshold) → nil
    /// - .absent(since:), elapsed ≥ 5 minutes → "User has been away from the desk for N minutes."
    /// - .absentLongTerm(since:) → "User has been away from the desk for N minutes."
    /// - .unknown → nil
    /// - no event recorded → nil
    public func currentEnrichment(now: Date = Date()) -> String? {
        guard let observedAt = self.observedAt,
              let latest = self.latest else {
            return nil
        }
        guard case let .transition(presence, _, _) = latest else {
            return nil
        }
        let observationAge = now.timeIntervalSince(observedAt)
        switch presence {
        case .present:
            return observationAge < 5 ? nil : "User is at the desk."
        case .absent(let since):
            let elapsedSeconds = now.timeIntervalSince(since)
            let mins = Int(elapsedSeconds / 60)
            return mins >= 5 ? "User has been away from the desk for \(mins) minutes." : nil
        case .absentLongTerm(let since):
            let elapsedSeconds = now.timeIntervalSince(since)
            let mins = Int(elapsedSeconds / 60)
            return "User has been away from the desk for \(mins) minutes."
        case .unknown:
            return nil
        }
    }
}
