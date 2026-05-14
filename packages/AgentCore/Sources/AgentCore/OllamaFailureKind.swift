import Foundation
import Config

/// Closed enumeration of detectable failure modes for the local Ollama provider
/// that trigger one-shot escalation to Anthropic Claude Opus 4.7.
///
/// See `docs/superpowers/specs/2026-05-14-local-first-llm-routing-design.md` §2.
///
/// Adding a new case is a breaking change: orchestrator + tests + HUD badge
/// reason mapping all need to be updated together.
public enum OllamaFailureKind: String, Sendable, Codable, Equatable, CaseIterable {
    /// Mid-stream EOF before `messageStop`. Already wired pre-spec.
    case streamTruncated
    /// `tool_calls` payload failed to decode against `ToolUseRequest`.
    case malformedToolCall
    /// Model invoked a tool name not in the registry.
    case unknownTool
    /// `stopReason: .refusal` event observed.
    case refusal
    /// URLSession error before any tokens received.
    case connectionFailure
    /// `messageStop` with zero `textDelta` and zero `toolUseRequested`.
    case emptyResponse
}

/// Recorded once when reactive escalation fires. Emitted to the HUD via
/// `BusOutbound.escalated(...)`.
public struct EscalationDecision: Sendable, Codable, Equatable {
    public let from: ProviderSelection
    public let to: ProviderSelection
    public let reason: OllamaFailureKind
    public let firedAt: Date

    public init(from: ProviderSelection, to: ProviderSelection, reason: OllamaFailureKind, firedAt: Date) {
        self.from = from
        self.to = to
        self.reason = reason
        self.firedAt = firedAt
    }
}
