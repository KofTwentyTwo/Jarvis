import Foundation
import Config

/// Agent-specific read helpers on `PerTurnSnapshot`. Kept in a dedicated
/// file so the Config target stays free of agent concerns.
public extension PerTurnSnapshot {
    /// Tool-call budget per turn. Exhausting it triggers cap-recovery (AGENT-07).
    /// Conservative default; configurable in P5+ via `FeatureFlags`.
    func maxToolCallsPerTurn() -> Int { 10 }

    /// Max output tokens per turn. AGENT-08 rationale — Opus 4.7 tokenizer
    /// produces ~1.35× tokens vs Opus 3.x; 8192 keeps a single response
    /// inside ~12 K Opus 4.7 tokens.
    func maxOutputTokens() -> Int { 8192 }

    /// The resolved provider for this turn.
    var resolvedProvider: ProviderSelection { provider }
}
