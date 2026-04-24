import Foundation

/// Wraps attacker-controllable content with a `turnNonce`-bracketed envelope
/// before promoting it into the LLM prompt (SEC-06).
///
/// **Algorithm**:
/// 1. Pre-strip any tag-like substring that matches the regex
///    `</?UNTRUSTED_CONTENT[^>]*>` (replace each occurrence with the literal
///    `[REDACTED_TAG]`). This neutralizes attempts to close our wrapper early.
/// 2. Wrap the (now-clean) content with paired tags carrying the per-turn
///    nonce: `<UNTRUSTED_CONTENT id="<nonce>">…</UNTRUSTED_CONTENT id="<nonce>">`.
///
/// **Case-sensitivity is intentional.** An attacker crafting
/// `<untrusted_content>` (lowercase) cannot close our wrapper because our
/// wrapper emits uppercase. Strip-then-wrap order matters: the strip MUST
/// run before wrapping; reversed order would let attacker tags leak through.
public struct UntrustedWrapper: Sendable {
    public let nonce: TurnNonce

    public init(nonce: TurnNonce) { self.nonce = nonce }

    public func wrap(_ untrusted: String) -> String {
        // 1. Strip tag-like substrings (case-sensitive, exact literal match).
        let pattern = #"</?UNTRUSTED_CONTENT[^>]*>"#
        let stripped = untrusted.replacingOccurrences(
            of: pattern, with: "[REDACTED_TAG]",
            options: .regularExpression
        )
        // 2. Wrap with paired tags carrying the per-turn nonce.
        return """
        <UNTRUSTED_CONTENT id="\(nonce.rawValue)">
        \(stripped)
        </UNTRUSTED_CONTENT id="\(nonce.rawValue)">
        """
    }
}
