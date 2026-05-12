// DevOverlayViewModel.swift
//
// `@Observable` view-model driving DevOverlayView. Holds three slices of
// state:
//
//   1. `snapshot` — DevSnapshot from the orchestrator event pipeline.
//      Single-writer path: `DevOverlayBridge`'s subscriber Task calls
//      `apply(_:)`. `private(set)` on the property enforces the gate by
//      type, not convention (ME-02).
//
//   2. `bootHealth` — last cached BootHealthSnapshot from the orchestrator
//      actor. Updated by `DevOverlayWindow`'s 1 Hz poll.
//
//   3. `hudStateLabel` — string form of the App-side HudState (the App
//      target owns the enum; we accept a closure to avoid the dep).
//
// Single write paths for all three. The UI is read-only.

import Foundation
import Observation
import AgentCore
import AgentOrchestrator

/// View-model for `DevOverlayView`.
///
/// ## Overview
///
/// Holds the three slices listed in the file header. Each slice has its
/// own mutator (`apply`, `updateBootHealth`, `updateHudState`) so the
/// callers stay narrowly typed and the single-writer invariants are
/// inspectable by `grep`.
///
/// ## Threading
///
/// `@MainActor`-isolated. All three mutators must be called on the main
/// actor — the SwiftUI Observation framework re-renders on the actor that
/// wrote the property. Calling from a background context would crash in
/// strict-concurrency mode.
@MainActor
@Observable
public final class DevOverlayViewModel {
    /// DevSnapshot from `DevSnapshotEmitter`. Single-writer: bridge task.
    public private(set) var snapshot: DevSnapshot

    /// Last cached boot-health snapshot. `nil` until the first probe runs.
    public private(set) var bootHealth: BootHealthSnapshot?

    /// Display string for the current HUD state (e.g., "idle", "thinking").
    /// String rather than the enum because `HudState` lives in the App
    /// target, not in any SPM package the overlay can import.
    public private(set) var hudStateLabel: String = "—"

    public init(snapshot: DevSnapshot = .initial) {
        self.snapshot = snapshot
    }

    /// Replace the current snapshot. Called by `DevOverlayBridge`'s
    /// subscriber task on the main actor.
    public func apply(_ newSnapshot: DevSnapshot) {
        self.snapshot = newSnapshot
    }

    /// Replace the cached boot-health snapshot. Called by
    /// `DevOverlayWindow`'s poll loop.
    public func updateBootHealth(_ snap: BootHealthSnapshot?) {
        self.bootHealth = snap
    }

    /// Replace the HUD-state display string.
    public func updateHudState(_ label: String) {
        self.hudStateLabel = label
    }

    /// Reset all three slices. Used by tests and by the app shell when
    /// the orchestrator rebinds (e.g., session switch).
    public func reset() {
        self.snapshot = .initial
        self.bootHealth = nil
        self.hudStateLabel = "—"
    }
}
