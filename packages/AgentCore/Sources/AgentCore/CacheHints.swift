import Foundation

/// Prompt-cache hints for one LLM turn. Anthropic-specific (Ollama ignores).
///
/// The `extended1h` TTL requires the
/// `anthropic-beta: extended-cache-ttl-2025-04-11` header — silently falls
/// back to 5m without it. `AnthropicProvider` always sends the beta header
/// (AGENT-02 must-have); `CacheHints` controls only the per-block TTL marker.
public struct CacheHints: Sendable, Equatable {
    public enum CacheTTL: Sendable, Equatable {
        /// Default Anthropic ephemeral cache (5 minutes).
        case ephemeral5m

        /// Extended 1-hour TTL.
        ///
        /// **Requires** `anthropic-beta: extended-cache-ttl-2025-04-11`
        /// header — silently falls back to 5m without it. Verify via
        /// DevOverlay watching `cache_creation_input_tokens` vs
        /// `cache_read_input_tokens` per turn.
        case extended1h
    }

    public let systemPromptTTL: CacheTTL

    public init(systemPromptTTL: CacheTTL) {
        self.systemPromptTTL = systemPromptTTL
    }
}
