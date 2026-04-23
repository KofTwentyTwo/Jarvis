import Foundation

/// Errors the bus raises across decode, send, and handshake paths.
///
/// Surfaces:
/// - `.decodeFailed` — inbound JSON failed to decode into a `BusInbound`.
/// - `.bridgeNotReady` — `send(_:)` called before the handshake armed.
/// - `.handshakeMismatch` — `helloAck` returned a version the Swift side
///   does not recognize; both sides recorded for alerting.
/// - `.handshakeTimeout` — the webview failed to send `helloAck` within the
///   2-second window defined by `HandshakeTiming.timeout`.
public enum BusError: Error, Sendable, Equatable {
    case decodeFailed(String)
    case bridgeNotReady
    case handshakeMismatch(swift: String, js: String)
    case handshakeTimeout
}
