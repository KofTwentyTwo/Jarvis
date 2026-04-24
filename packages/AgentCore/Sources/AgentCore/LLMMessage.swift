import Foundation

/// One message in an LLM turn's conversation history.
///
/// `untrusted == true` MUST be set by the orchestrator (Plan 04-04) for any
/// message containing `.toolResult` content. The orchestrator wraps tool
/// output in a `turnNonce` envelope (SEC-06) before promoting it to the
/// prompt — this provider does **not** look at `untrusted`; it's a marker
/// for downstream code paths.
public struct LLMMessage: Sendable, Equatable {
    public enum Role: String, Sendable, Equatable {
        case system
        case user
        case assistant
        case tool
    }

    /// One block of message content. Anthropic and Ollama both support
    /// multipart messages; the encoder for each provider knows how to
    /// serialize the three cases.
    public enum ContentBlock: Sendable, Equatable {
        case text(String)
        case toolUse(id: String, name: String, argsJSON: Data)
        case toolResult(toolUseId: String, content: String)
    }

    public let role: Role
    public let content: [ContentBlock]
    public let untrusted: Bool

    public init(role: Role, content: [ContentBlock], untrusted: Bool = false) {
        self.role = role
        self.content = content
        self.untrusted = untrusted
    }
}
