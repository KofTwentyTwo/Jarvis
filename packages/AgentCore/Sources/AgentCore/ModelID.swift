import Foundation

/// Opaque model identifier. The string is what each provider sends on the
/// wire; we don't enumerate cases because the SDK enum lag is structural
/// (D1 in RESEARCH-DELTAS — `claude-opus-4-7` is the real model ID and
/// URLSession accepts string model IDs).
public struct ModelID: Sendable, RawRepresentable, Equatable, Hashable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Anthropic Opus 4.7 — primary cloud model.
    /// Per RESEARCH-DELTAS D1: `claude-opus-4-7` is the real model ID;
    /// Anthropic SDK enum lag is non-blocking because URLSession accepts
    /// arbitrary string model IDs.
    public static let opus47 = ModelID(rawValue: "claude-opus-4-7")

    /// Local Ollama model — known-good tool-calling baseline per CLAUDE.md
    /// (Qwen3 / Gemma 4 tool-calling broken in Ollama as of April 2026).
    public static let qwen25coder32b = ModelID(rawValue: "qwen2.5-coder:32b")
}
