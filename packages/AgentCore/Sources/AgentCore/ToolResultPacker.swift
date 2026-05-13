import Foundation

/// AGENT-08 8 KB tool-result cap — wire-up between MCP boundary defense and
/// the LLM message history.
///
/// **Why 8 KB?** Opus 4.7 tokenizer produces ~1.35× tokens vs Opus 3.x;
/// 8 KB at the new ratio ≈ 12 K tokens. Three tool calls / turn × 12 K
/// = 36 K tokens — manageable on a 1 M context model but conservative
/// against context blowout. Revisit empirically via DevOverlay's
/// cache-ratio signal in P5+.
///
/// **Where the cap actually fires:** at the MCP dispatcher boundary via
/// `SanitizeForModel.prepareForBoundary(_, capBytes: 8192)` (lives in the
/// JarvisMCP package). By the time bytes reach this packer, they are
/// already sanitized + head-truncated to ≤ 8 KB. `pack(_:)` does NOT cap
/// again — that was the CRIT-2 audit-2026-05-12 double-cap, fixed by
/// closing #21. The packer's job today is reduced to: decode the
/// already-prepared bytes into a `String` for the LLM message history and
/// pass the same bytes through to `ReplayLog` via
/// `ReplayEvent.toolResultFull(toolUseId:bytes:)`. The audit-trail row
/// reflects the boundary-prepared bytes — not the original helper output
/// (per the audit's stated v0.1 acceptance: replay row = 8 KB cap, not the
/// full original blob).
public enum ToolResultPacker {
    /// Cap for model-facing tool_result content in bytes. Kept for the
    /// (informational) `wasCapped` / `omittedByteCount` fields and to
    /// document the contract; the cap itself is enforced at the MCP
    /// dispatcher boundary (`SanitizeForModel.prepareForBoundary`).
    public static let modelFacingCapBytes: Int = 8 * 1024

    /// Result of packing a single tool result.
    public struct Packed: Sendable {
        /// String the orchestrator embeds in the next `LLMMessage` of role
        /// `.tool`. UTF-8 decoded from `fullBytes` as-is — the MCP
        /// dispatcher boundary already applied the 8 KB head-truncate +
        /// the `…[tool-result-truncated at 8192 bytes]` marker.
        public let modelFacing: String

        /// The dispatcher-prepared bytes — destined for
        /// `ReplayEvent.toolResultFull`. After #21 these are the same
        /// bytes the model sees (no double-cap).
        public let fullBytes: Data

        /// True if the dispatcher truncated. Detected by looking at
        /// the input size relative to `modelFacingCapBytes` — informational
        /// only since `pack(_:)` no longer truncates.
        public let wasCapped: Bool

        /// Always zero after #21 — kept for API stability. The dispatcher
        /// strips bytes before the packer sees them; the omitted count is
        /// not knowable here.
        public let omittedByteCount: Int
    }

    /// Pack one tool result. Input bytes have already been sanitized +
    /// 8-KB-head-truncated by `SanitizeForModel.prepareForBoundary` at the
    /// MCP dispatcher boundary; this packer does NOT cap again (per #21
    /// closure). The caller (`AgentOrchestrator`) routes `modelFacing`
    /// through `UntrustedWrapper` before appending to the LLM message
    /// history and emits `fullBytes` to `ReplayLog`.
    public static func pack(_ raw: Data) -> Packed {
        // The boundary cap fires upstream in
        // `SanitizeForModel.prepareForBoundary(_:capBytes:)`. We just
        // decode + pass through. `wasCapped` is reported informationally
        // from the size signal so callers / dashboards that previously
        // read it keep working; `omittedByteCount` is no longer knowable
        // here and is always zero.
        return Packed(
            modelFacing: String(decoding: raw, as: UTF8.self),
            fullBytes: raw,
            wasCapped: raw.count >= modelFacingCapBytes,
            omittedByteCount: 0
        )
    }
}
