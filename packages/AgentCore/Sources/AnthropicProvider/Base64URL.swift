import Foundation

/// Base64URL encoding helper.
///
/// Standard base64 alphabet with `+→-`, `/→_`, and trailing `=` stripped.
/// Used in Plan 04-04 for `turnNonce` envelope wrapping (SEC-06). Lives
/// here so AgentCore doesn't need a separate utility module; marked
/// `internal` so it's only visible inside `AnthropicProvider` (tests
/// reach in via `@testable import`).
extension Data {
    func base64URLEncodedString() -> String {
        var s = self.base64EncodedString()
        s = s.replacingOccurrences(of: "+", with: "-")
        s = s.replacingOccurrences(of: "/", with: "_")
        while s.hasSuffix("=") { s.removeLast() }
        return s
    }
}
