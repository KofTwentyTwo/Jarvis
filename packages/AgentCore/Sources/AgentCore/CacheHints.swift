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

    /// Anthropic's prompt cache requires a minimum prompt size before the
    /// `cache_control` marker takes effect. For Opus 4.7 and most current
    /// models the floor is ~1024 tokens. Below the floor, the server can
    /// return 200 OK + immediate-EOF for `extended-cache-ttl` hints — the
    /// documented edge case that produced every `streamTruncatedFinal` in
    /// the 2026-05-03 audit (system prompt was ~10 tokens, cache hint was
    /// emitted unconditionally).
    ///
    /// This helper returns the requested hints only if `systemPromptText`
    /// passes the eligibility threshold (4096 chars ≈ 1024 tokens via the
    /// 4 chars / token rule of thumb for English). Below the threshold,
    /// the answer is `nil` — no cache_control marker is emitted, and the
    /// request body is shape-identical to a no-cache request.
    ///
    /// Once the system prompt grows past the threshold (e.g. memory
    /// hydration adds context, presence enrichment lengthens the prompt)
    /// the hint resumes automatically.
    ///
    /// **Current production state (as of v0.1):** `selfAwarePreamble` is
    /// ~700 chars and the orchestrator is constructed with an `.empty`
    /// initial context, so the threshold is never crossed on a healthy
    /// boot — `eligibleForSystemPrompt` returns `nil` on every turn and
    /// the prompt cache is effectively dormant. This is intentional
    /// cost-acceptance: padding the preamble to ≥4096 chars would
    /// require real prompt-engineering work and risks bleeding
    /// irrelevant context into the model. Cache hits resume naturally
    /// once Memory M-4 (v0.8 milestone) lands `searchFacts`-driven
    /// hydration that grows the prompt past 1024 tokens organically;
    /// see #23 for the audit context. Until then, every turn pays full
    /// input-token cost — a ~30–80% cost reduction is on the table once
    /// M-4 ships.
    public static func eligibleForSystemPrompt(
        _ systemPromptText: String,
        ttl: CacheTTL = .extended1h
    ) -> CacheHints? {
        let MIN_CHARS_FOR_CACHE_BREAKPOINT = 4096
        guard systemPromptText.count >= MIN_CHARS_FOR_CACHE_BREAKPOINT else {
            return nil
        }
        return CacheHints(systemPromptTTL: ttl)
    }
}
