import Foundation
import Observation
import AgentCore
import AgentOrchestrator

/// @Observable, @MainActor view-model driving `DevOverlayView`.
///
/// **Single write path:** the DevSnapshot channel subscriber Task (see
/// `DevOverlayBridge`). The UI reads `snapshot` but never mutates it. Keeps
/// the rendering deterministic: whatever `DevSnapshotEmitter` says is the
/// current state is the state the UI renders, with no local drift.
///
/// `@Observable` is macOS 14+ (Observation framework). The DevOverlay package
/// raises its platform floor accordingly; the main app target stays at
/// macOS 13 since DevOverlay is opt-in.
@MainActor
@Observable
public final class DevOverlayViewModel {
    // ME-02: `private(set)` enforces single-write-path by type, not
    // convention. `DevOverlayBridge`'s subscriber Task routes writes
    // through `apply(_:)`. Without this scope restriction any caller
    // could `vm.snapshot = …` directly and break the AGENT-10 invariant.
    public private(set) var snapshot: DevSnapshot

    public init(snapshot: DevSnapshot = .initial) {
        self.snapshot = snapshot
    }

    /// Replace the current snapshot. Called by `DevOverlayBridge`'s subscriber
    /// task on the main actor. The last-5 tool-call ring is maintained by
    /// `DevSnapshotEmitter`, so this method is pure overwrite.
    public func apply(_ newSnapshot: DevSnapshot) {
        self.snapshot = newSnapshot
    }

    /// Reset to `.initial` — used by tests and by the app shell when the
    /// orchestrator rebinds (e.g., session switch).
    public func reset() {
        self.snapshot = .initial
    }
}
