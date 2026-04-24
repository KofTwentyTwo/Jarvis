import Foundation

/// Tool-call discipline for one LLM turn. Mandatory parameter on
/// `LLMProvider.stream(...)` — there is **no default**.
///
/// Per CLAUDE.md tool-choice discipline: cap-recovery turns must pass
/// `.none` so the model cannot loop on tool calls. The eval harness
/// (Plan 09 hardening) asserts zero `.toolUseRequested` events when
/// `toolChoice == .none`.
///
/// **Provider serialization:**
/// - Anthropic: object on the `tool_choice` field —
///   `.auto` → `{"type":"auto"}`, `.none` → `{"type":"none"}`,
///   `.any` → `{"type":"any"}`, `.tool(name:)` → `{"type":"tool","name":...}`.
/// - Ollama (Plan 04-02): `.none` drops the `tools` array entirely from
///   the request; the other cases include `tools` and let the model decide.
public enum ToolChoice: Sendable, Equatable {
    /// Model decides whether to call a tool. The default behavior in most
    /// agent loops, but explicit here to keep the API call site readable.
    case auto

    /// Tools are listed but the model MUST NOT call any. Used for
    /// cap-recovery turns and final-answer summarization.
    case none

    /// Model MUST call exactly one tool (any tool). Anthropic-only semantics
    /// — Ollama maps this to `.auto` in Plan 04-02.
    case any

    /// Model MUST call this specific tool. Used when the orchestrator wants
    /// to force a tool name (e.g., scripted demo flows).
    case tool(name: String)
}
