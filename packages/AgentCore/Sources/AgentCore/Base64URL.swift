import Foundation

/// Base64URL encoding helper.
///
/// Standard base64 alphabet with `+→-`, `/→_`, and trailing `=` stripped.
/// Used in Plan 04-04 for `turnNonce` envelope wrapping (SEC-06). Lives in
/// AgentCore so both `TurnNonce` (here) and `AnthropicProvider` (cache key
/// hashing) share one encoder. Promoted from internal to public on 04-04.
extension Data {
    public func base64URLEncodedString() -> String {
        var s = self.base64EncodedString()
        s = s.replacingOccurrences(of: "+", with: "-")
        s = s.replacingOccurrences(of: "/", with: "_")
        while s.hasSuffix("=") { s.removeLast() }
        return s
    }
}
