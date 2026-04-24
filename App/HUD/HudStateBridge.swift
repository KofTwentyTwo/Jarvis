import Bus

/// Bridges the App-side `HudState` (UI concerns, voiceOverLabel, declaration
/// order tuned for menu-bar icon factory) to the Bus-side `HudState` (wire
/// format). The two enums are kept in lock-step via their shared String
/// rawValues — a drift between them is an internal bug.
///
/// Plan 03-05 wires this helper through `AppDelegate.installBus()`:
///   HudStateCoordinator emits App.HudState → busHudState(from:) → Bus.HudState
///   → WebviewBridge.send(.hudState(...))
///
/// Enum parity is assertion-guarded in Debug and table-enforced by
/// `HudStateCoordinatorBusWiringTests.test_appHudStateRawValueMatchesBusHudState`.
/// The Release fallback to `.idle` prevents a crash if someone ever adds an
/// App-only case without adding it to Bus — the HUD wedges on `.idle` rather
/// than terminating the user's session.
///
/// `@MainActor` is not strictly required (the function is a pure rawValue
/// round-trip), but it matches the caller expectation in
/// `HudStateCoordinator`'s emit closure which is @MainActor-isolated.
@MainActor
public func busHudState(from app: HudState) -> Bus.HudState {
    guard let bus = Bus.HudState(rawValue: app.rawValue) else {
        assertionFailure("HudState rawValue drift: \(app.rawValue) not in Bus.HudState")
        return .idle
    }
    return bus
}
