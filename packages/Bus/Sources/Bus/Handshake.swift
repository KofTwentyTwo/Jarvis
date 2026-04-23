import Foundation

/// State of the two-way `BUS_PROTOCOL_VERSION` handshake (HUD-05).
///
/// Lifecycle:
///   `.idle` → `.sentHello(deadline:)` → `.armed`
///                                    ↘  `.mismatched(swift:, js:)`
///                                    ↘  `.timedOut`
///
/// Once the state reaches `.armed`, `.mismatched`, or `.timedOut`, it does
/// not move. Mismatch and timeout are terminal — the HUD bundle must be
/// rebuilt.
public enum HandshakeState: Equatable, Sendable {
    case idle
    case sentHello(deadline: Date)
    case armed
    case mismatched(swift: String, js: String)
    case timedOut
}

/// Timing parameters for the handshake. 2s is the RESEARCH §HUD-05 budget —
/// webview load including Vite dev-server cold boot has been measured at
/// <500ms on the development host, so 2s is ~4x margin.
public enum HandshakeTiming {
    public static let timeout: Duration = .seconds(2)
}
