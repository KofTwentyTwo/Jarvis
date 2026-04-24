import Foundation

/// Provider-agnostic streaming contract for LLM backends.
///
/// Both `AnthropicProvider` (Plan 04-01) and `OllamaProvider` (Plan 04-02) conform.
/// The orchestrator (Plan 04-04) selects between them via `ProviderSelection`.
///
/// The returned `AsyncThrowingStream` flows token deltas, tool-use requests,
/// thinking deltas, usage, and the terminal `messageStop`. Cancellation flows
/// through `Task.isCancelled` — the provider task is responsible for closing
/// the underlying transport when the consuming task is cancelled.
public protocol LLMProvider: Sendable {
    /// Stream a single LLM turn.
    ///
    /// - Parameter toolChoice: **Mandatory.** Cap-recovery turns must pass
    ///   `.none` so the model cannot loop on tool calls. Anthropic serializes
    ///   `.none` as `{"type":"none"}`; Ollama drops the `tools` array entirely.
    func stream(
        messages: [LLMMessage],
        tools: [ToolSchema],
        toolChoice: ToolChoice,
        model: ModelID,
        maxOutputTokens: Int,
        cacheHints: CacheHints?
    ) -> AsyncThrowingStream<LLMEvent, Error>
}
