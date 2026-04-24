import Foundation
import Security

/// Per-turn random nonce used to bracket untrusted tool-result content
/// before it is fed back to the LLM (SEC-06).
///
/// 16 random bytes from `SecRandomCopyBytes`, base64url-encoded → 22 chars
/// typical (no padding). The nonce travels:
/// 1. Into `ReplayLog.startTurn(turnNonce:)` for forensic correlation.
/// 2. Into `UntrustedWrapper(nonce:)` to brackets tool output in the prompt.
///
/// **Security invariant:** the nonce never appears in any
/// `OrchestratorEvent` emitted to the bus / webview. Verified by a grep gate
/// in `OrchestratorEvent.swift`.
public struct TurnNonce: Sendable, Equatable, Hashable {
    public let rawValue: String

    /// Generate a fresh nonce backed by `SecRandomCopyBytes(16)`.
    /// Crashes via `precondition` if the system RNG is unavailable —
    /// without it we cannot honor SEC-06 and continuing is unsafe.
    public static func fresh() -> TurnNonce {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess,
                     "SecRandomCopyBytes failed — cryptographic primitive unavailable")
        return TurnNonce(rawValue: Data(bytes).base64URLEncodedString())
    }

    private init(rawValue: String) { self.rawValue = rawValue }
}
