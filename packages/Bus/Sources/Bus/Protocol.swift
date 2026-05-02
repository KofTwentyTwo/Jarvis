import Foundation

/// The wire-format version for the Swift ↔ JS bus. Bumping this rejects any
/// webview bundle that was built against a different constant (HUD-05).
///
/// Versioning policy (per RESEARCH §HUD-05):
/// - `MAJOR` — structural schema change (field renamed, removed, re-typed).
/// - `MINOR` — additive case or field (webview still decodes older shape).
/// - `PATCH` — bugfix / fixture correction with no behavioural change.
///
/// Strict equality is enforced at runtime by the handshake. Additive-only
/// relaxation (match on `MAJOR` alone) is deferred to a later phase.
///
/// Bumped in Plan 07-03 task 3 — additive case `sessionHistory(turns:)` for
/// TEXT-03 chat-panel hydration. The TS mirror in webview/packages/bus must
/// add the matching case before integration goes live (Plan 07-06 closes the
/// loop; check-bus-protocol-version.sh will fail until the TS mirror lands).
///
/// Plan 09-02 — bumped 2.1.0 → 2.2.0 for additive BusInbound case
/// `frameAttachRequested` (HUD camera-icon button → FrameAttachController).
/// MINOR per HUD-05 versioning (additive; older webviews still decode the
/// outbound shape).
public let BUS_PROTOCOL_VERSION: String = "2.2.0"

/// UI states the HUD can occupy. Encoded as its `rawValue` inside
/// `BusOutbound.hudState(_:)` — see `BusOutbound.encode(to:)`.
public enum HudState: String, Codable, Sendable, CaseIterable {
    case idle
    case listening
    case thinking
    case speaking
    case awaitingConfirmation
    case reconfiguring
    case booting
}

/// Terminal reason for a conversation turn. Encoded as its `rawValue` inside
/// `BusOutbound.turnEnded(id:terminator:)`.
public enum TurnTerminator: String, Codable, Sendable, CaseIterable {
    case completed
    case cancelled
    case errored
    case superseded
}

/// Shared JSON coder configuration. Single source of truth for the wire
/// format so `WebviewBridge`, `CodableRoundTripTests`, and any downstream
/// consumers all agree on encoding.
///
/// Notes:
/// - `outputFormatting` is intentionally empty — the wire form is minimal,
///   not pretty-printed or key-sorted. Round-trip tests normalize via
///   `JSONSerialization` to tolerate key-order differences.
/// - `UUID` values are encoded as *lowercase* strings at each call site
///   inside `BusOutbound.encode(to:)` because `JSONEncoder` encodes `UUID`
///   as uppercase by default, which the TS mirror does not emit
///   (Pitfall 6 in RESEARCH §pitfalls).
public enum BusCoder {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = []
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
