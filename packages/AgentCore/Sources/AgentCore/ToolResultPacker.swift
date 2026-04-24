import Foundation

/// AGENT-08 8 KB tool-result cap.
///
/// **Why 8 KB?** Opus 4.7 tokenizer produces ~1.35× tokens vs Opus 3.x;
/// 8 KB at the new ratio ≈ 12 K tokens. Three tool calls / turn × 12 K
/// = 36 K tokens — manageable on a 1 M context model but conservative
/// against context blowout. Revisit empirically via DevOverlay's
/// cache-ratio signal in P5+.
///
/// The cap is **model-facing only**. The full blob still flows to
/// `ReplayLog` via `ReplayEvent.toolResultFull(toolUseId:bytes:)` —
/// observability is not lossy (OBS-02).
public enum ToolResultPacker {
    /// Cap for model-facing tool_result content in bytes.
    public static let modelFacingCapBytes: Int = 8 * 1024

    /// Result of packing a single tool result.
    public struct Packed: Sendable {
        /// String the orchestrator embeds in the next `LLMMessage` of role
        /// `.tool`. UTF-8 decoded from the (possibly capped) byte prefix; if
        /// truncated, ends with `\n\n[TRUNCATED: …]` marker text.
        public let modelFacing: String

        /// Original bytes — destined for `ReplayEvent.toolResultFull`.
        public let fullBytes: Data

        /// True if `fullBytes.count > modelFacingCapBytes`.
        public let wasCapped: Bool

        /// Number of bytes omitted from `modelFacing`. Zero when not capped.
        public let omittedByteCount: Int
    }

    /// Pack one tool result. The caller (`AgentOrchestrator`) routes the
    /// `modelFacing` string through `UntrustedWrapper` before appending to
    /// the LLM message history, and emits `fullBytes` to `ReplayLog`.
    public static func pack(_ raw: Data) -> Packed {
        let cap = modelFacingCapBytes
        let capped = raw.prefix(cap)
        let wasCapped = raw.count > capped.count
        let omitted = raw.count - capped.count
        let modelFacing: String
        if wasCapped {
            // String(decoding:as:) replaces invalid bytes with U+FFFD; we may
            // truncate mid-codepoint at the byte boundary, that's acceptable.
            let head = String(decoding: capped, as: UTF8.self)
            modelFacing = head + "\n\n[TRUNCATED: \(omitted) bytes omitted; full blob in replay log]"
        } else {
            modelFacing = String(decoding: capped, as: UTF8.self)
        }
        return Packed(
            modelFacing: modelFacing,
            fullBytes: raw,
            wasCapped: wasCapped,
            omittedByteCount: omitted
        )
    }
}
