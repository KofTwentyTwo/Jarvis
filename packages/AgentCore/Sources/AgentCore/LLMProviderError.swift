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

    /// Ollama `/api/chat` emitted a `tool_calls` block whose `arguments`
    /// failed to decode as JSON. Carries a redacted underlying reason for
    /// diagnostics. Surfaces `OllamaFailureKind.malformedToolCall` via
    /// `ollamaFailureKind` so the orchestrator (Task 6) can escalate to
    /// Anthropic. See spec §2.
    case malformedToolCall(reason: String)

    /// Ollama stream terminated with zero text deltas AND zero tool-use
    /// requests — a model-side empty response. Surfaces
    /// `OllamaFailureKind.emptyResponse` so the orchestrator (Task 6) can
    /// escalate to Anthropic. See spec §2.
    case emptyResponse

    /// If this error originated from the local Ollama provider and matches
    /// one of the closed failure kinds the orchestrator escalates on,
    /// return that kind. Non-Ollama-specific errors (`.api`, `.decode`,
    /// `.transport`, `.streamTruncatedFinal`) return `nil`.
    ///
    /// `streamTruncated`, `refusal`, `connectionFailure`, and `unknownTool`
    /// are detected orchestrator-side from `LLMEvent.stopReason`, the
    /// transport-layer `URLSession` error path, and the tool registry —
    /// not from this enum.
    public var ollamaFailureKind: OllamaFailureKind? {
        switch self {
        case .malformedToolCall: return .malformedToolCall
        case .emptyResponse:     return .emptyResponse
        case .api, .decode, .transport, .streamTruncatedFinal: return nil
        }
    }
}
