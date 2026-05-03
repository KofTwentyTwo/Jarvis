import Foundation
import Keychain

/// Builder for the `@Sendable () async throws -> String` closure that
/// `AnthropicProvider` consumes for the `x-api-key` header. Lives outside
/// the App target so the contract — *propagate KeychainError, do not
/// silently substitute an empty string* — is unit-testable. Closes the
/// observability gap from the 2026-05-03 audit:
///
///   `AppDelegate.swift:885-887` constructed the provider as
///   `(try? keychainStoreLocal.get(.anthropic)) ?? ""`. A real
///   `KeychainError.itemNotFound` (or `.unexpectedStatus`) was swallowed
///   into the empty string, so the request reached Anthropic with an
///   empty `x-api-key`. Anthropic returned `401: x-api-key header is
///   required` — distinguishable from a stale-key 401 only by reading
///   the response body. The user's chat panel showed only the eventual
///   `streamTruncatedFinal`; the actual root cause was hidden behind
///   two layers of silent fallback.
///
/// With this builder in place, `AnthropicProvider`'s
/// `apiKey = try await apiKeyProvider()` re-throws the keychain error,
/// which becomes `LLMProviderError.transport(description: ...)`. The
/// orchestrator routes it through `OrchestratorEvent.error` →
/// `BusForwarder.drain` → `BusOutbound.submitRejected(reason: "Turn
/// failed: ...")` → JS-side error event in the chat panel.
public enum AnthropicAPIKeyProvider {
    /// Construct an `AnthropicProvider.APIKeyProvider` that reads the API
    /// key from `keychain` for the given `item`. Errors propagate
    /// verbatim; callers must handle them at the provider boundary.
    public static func make(
        keychain: any KeychainStore,
        item: KeychainItem = .anthropic
    ) -> AnthropicProvider.APIKeyProvider {
        return { @Sendable in
            try keychain.get(item)
        }
    }
}
