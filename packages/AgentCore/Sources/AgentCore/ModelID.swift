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

    /// Local Ollama agent-loop fallback. Q8_0 quantization of the project's
    /// CLAUDE.md known-good tool-calling baseline. Higher fidelity than
    /// the default Q4_K_M; same model family, same tool-call wire format.
    /// Keep this conservative for the agent loop until multi-turn /
    /// cap-recovery / streaming tool-calls are verified on newer models
    /// (see `qwen36` doc).
    public static let qwen25coder32b = ModelID(rawValue: "qwen2.5-coder:32b-instruct-q8_0")

    /// Qwen3.6 (~36B MoE, Q4_K_M, runs comfortably on Apple Silicon Pro/Max).
    ///
    /// **2026-05-11 empirical retest:** Ollama `/api/chat` non-streaming
    /// tool-calling against this model returns a well-formed `tool_calls`
    /// array with clean JSON args — no leaked `<think>` tags clobbering
    /// the response, no malformed parser output. This contradicts the
    /// April 2026 CLAUDE.md note that Qwen3 tool-calling was broken in
    /// Ollama (#14493 / #14601 / #14745); upstream appears to have closed
    /// those issues in the interim.
    ///
    /// **Used as the memory extractor default** (`MemoryExtractor.init`
    /// `model: .qwen36`). The extractor is single-turn, single tool, no
    /// cap recovery — the safest place to test a newer model. If
    /// extraction is stable for a few days of dogfooding, we revisit the
    /// agent-loop fallback.
    public static let qwen36 = ModelID(rawValue: "qwen3.6:latest")
}
