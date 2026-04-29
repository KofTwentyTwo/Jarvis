import Foundation

/// Edge-triggered presence event published on PresenceSignalBus.
///
/// VISION-02 invariant: these are SIGNALS — never triggers. PresenceMonitor
/// emits transitions only on confirmed edge crossings (debounced 2s per
/// D-11). A secondary 5-minute absent threshold elevates a sustained
/// absent state to .absentLongTerm for context-state framing.
public enum PresenceEvent: Sendable, Equatable {
    /// Edge transition to a new presence state. `at` is wall-clock time;
    /// `debounced` is the debounce window that was applied before firing
    /// (constant 2.0 in P7, surfaced here for replay/test introspection).
    case transition(to: Presence, at: Date, debounced: TimeInterval)
}

/// Three presence states used by the monitor.
///
/// .present       — face detected on most recent frames, stable for >=2s
/// .absent        — face NOT detected, stable for >=2s
/// .absentLongTerm — has been .absent for >=5 minutes (D-11 secondary)
/// .unknown       — pre-first-frame state; never published (sentinel only)
public enum Presence: Sendable, Equatable {
    case present
    case absent(since: Date)
    case absentLongTerm(since: Date)
    case unknown
}
