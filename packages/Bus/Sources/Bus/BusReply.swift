import Foundation

/// Reply shape returned via `WKScriptMessageHandlerWithReply`'s `replyHandler`.
///
/// WebKit requires replies to be plist-serializable (`NSNumber`, `NSString`,
/// `NSArray`, `NSDictionary`, `NSNull`, nested) — arbitrary `Codable` types
/// are rejected at runtime. `asPlist()` produces the accepted dictionary form.
///
/// JS semantics (per HUD-03):
/// - `(value, nil)` → JS-side `Promise.resolve(value)`
/// - `(nil, errorString)` → JS-side `Promise.reject(new Error(errorString))`
public struct BusReply: Sendable, Equatable {
    public let ok: Bool
    /// JSON-encoded payload as a string, or `nil` for success with no body.
    public let value: String?
    public let error: String?

    public init(ok: Bool, value: String? = nil, error: String? = nil) {
        self.ok = ok
        self.value = value
        self.error = error
    }

    /// Canonical empty-success reply.
    public static let success = BusReply(ok: true)

    /// Canonical failure reply. `message` is what the JS `Error.message`
    /// will surface after the promise rejects.
    public static func failure(_ message: String) -> BusReply {
        BusReply(ok: false, error: message)
    }

    /// Plist-serializable dictionary form accepted by
    /// `WKScriptMessageHandlerWithReply.replyHandler`. Strings and booleans
    /// bridge to `NSString` / `NSNumber`; nil slots become `NSNull`.
    public func asPlist() -> [String: Any] {
        if ok {
            return [
                "ok": true,
                "value": (value as Any?) ?? NSNull(),
            ]
        } else {
            return [
                "ok": false,
                "error": error ?? "unknown",
            ]
        }
    }
}
