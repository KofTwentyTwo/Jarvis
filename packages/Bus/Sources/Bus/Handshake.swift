import Foundation

/// State of the two-way `BUS_PROTOCOL_VERSION` handshake (HUD-05).
///
/// Lifecycle:
///   `.idle` → `.sentHello(deadline:)` → `.armed`
///                                    ↘  `.mismatched(swift:, js:)`
///                                    ↘  `.timedOut`
///                                    ↘  `.loadFailed(reason:)`
///
/// Once the state reaches `.armed`, `.mismatched`, `.timedOut`, or
/// `.loadFailed`, it does not move. Mismatch, timeout, and load-failure are
/// terminal — the HUD bundle must be rebuilt or the navigation error fixed.
///
/// `.loadFailed` covers the bundle-navigation failure path (audit-2026-05-12
/// S1, issue #40): if `index.html`, the JS bundle, or any sub-resource
/// 404s / fails to parse, `didFinish` never fires, so `startHandshake`'s 2s
/// timeout is never armed. `BridgeNavigationDelegate.didFail*` arms route
/// to `WebviewBridge.failHandshake(reason:)` which transitions to this
/// state and surfaces the error to the user.
public enum HandshakeState: Equatable, Sendable {
    case idle
    case sentHello(deadline: Date)
    case armed
    case mismatched(swift: String, js: String)
    case timedOut
    case loadFailed(reason: String)
}

/// Timing parameters for the handshake. 2s is the RESEARCH §HUD-05 budget —
/// webview load including Vite dev-server cold boot has been measured at
/// <500ms on the development host, so 2s is ~4x margin.
public enum HandshakeTiming {
    public static let timeout: Duration = .seconds(2)
}
