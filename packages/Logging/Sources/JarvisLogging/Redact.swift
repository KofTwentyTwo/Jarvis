import Foundation

public enum Redact {
    /// Compiled once. Alternation branches ordered by specificity so sk-ant- matches
    /// branch 1 before sk- (OpenAI) branch 3.
    ///   1. Anthropic sk-ant-<20+ tokens>
    ///   2. Authorization: Bearer <token>  (case-insensitive)
    ///   3. OpenAI sk-<20+ tokens>
    ///   4. AKIA<16 uppercase alphanumerics>
    ///   5. ghp_<36 alphanumerics>
    private static let pattern: NSRegularExpression = {
        let raw = #"(sk-ant-[A-Za-z0-9_\-]{20,})|((?i:Authorization:\s*Bearer)\s+[A-Za-z0-9_\-\.=]+)|(\bsk-[A-Za-z0-9_\-]{20,})|(AKIA[0-9A-Z]{16})|(ghp_[A-Za-z0-9]{36})"#
        return try! NSRegularExpression(pattern: raw)
    }()

    public static func apply(_ s: String) -> String {
        let ns = s as NSString
        return pattern.stringByReplacingMatches(
            in: s,
            range: NSRange(location: 0, length: ns.length),
            withTemplate: "<redacted>"
        )
    }
}
