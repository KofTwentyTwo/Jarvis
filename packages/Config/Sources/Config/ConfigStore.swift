import Foundation

/// Holds the frozen LaunchSnapshot + publishes PerTurnSnapshot updates.
/// File-watcher integration (restart-required banner) is installed by AppDelegate (Plan 03).
public actor ConfigStore {
    public let launch: LaunchSnapshot
    private var current: PerTurnSnapshot
    private var subscribers: [AsyncStream<PerTurnSnapshot>.Continuation] = []

    public init(launch: LaunchSnapshot, initial: PerTurnSnapshot) {
        self.launch = launch
        self.current = initial
    }

    public func perTurn() -> PerTurnSnapshot {
        current
    }

    public func updatePerTurn(_ next: PerTurnSnapshot) {
        current = next
        for s in subscribers { s.yield(next) }
    }

    public func stream() -> AsyncStream<PerTurnSnapshot> {
        AsyncStream { continuation in
            self.subscribers.append(continuation)
            continuation.yield(current)
        }
    }
}
