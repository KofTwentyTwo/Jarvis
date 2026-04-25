import Foundation

/// Errors emitted by an `LLMProvider`. All cases are `Sendable` and
/// `Equatable`; the orchestrator (Plan 04-04) maps these to user-visible
/// HUD states.
///
/// **Information disclosure note (T-04-01-01):** `.api(statusCode:body:)`
/// can carry an Anthropic error response that may echo header values
/// (including a malformed `x-api-key`). The provider does NOT log or
/// redact these at the provider layer. The orchestrator applies
/// `JarvisLogging.Redact.apply(...)` to error bodies BEFORE forwarding
/// them to either the bus (`OrchestratorEvent.error`) or the replay log,
/// so credential-shaped substrings never cross the webview trust
/// boundary or land in persistent storage in cleartext. Single redaction
/// site — see `AgentOrchestrator.redact(_:)`.
public enum LLMProviderError: Error, Sendable, Equatable {
    case api(statusCode: Int, body: String)
    case decode(reason: String)
    case transport(description: String)

    /// Final retry budget exhausted — emitted by orchestrator (Plan 04-04)
    /// after stream-truncation retry policy gives up. The provider does
    /// not emit this directly.
    case streamTruncatedFinal
}
