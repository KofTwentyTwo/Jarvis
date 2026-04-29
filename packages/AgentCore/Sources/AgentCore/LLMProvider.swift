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
///
/// **Multimodal extension (Plan 07-05 / D-18):** the new
/// `stream(messages:images:...)` overload carries `[ImageBlock]` for
/// vision-capable providers. The default protocol extension forwards to the
/// existing single-modal stream when `images.isEmpty`, so non-vision
/// conformers (and `MockLLMProvider`) keep compiling unchanged. Conformers
/// that DO speak vision (`AnthropicProvider`, `OllamaProvider`) override the
/// multimodal method with image-aware request-body encoding.
public protocol LLMProvider: Sendable {
    /// Stream a single LLM turn (text-only).
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

    /// Stream a single multimodal LLM turn (text + images).
    ///
    /// Plan 07-05 / D-18. Default implementation forwards to the existing
    /// single-modal `stream(...)` when `images.isEmpty`. Non-overriding
    /// conformers receiving non-empty `images` precondition-fail — the
    /// caller used a vision API on a text-only provider.
    func stream(
        messages: [LLMMessage],
        images: [ImageBlock],
        tools: [ToolSchema],
        toolChoice: ToolChoice,
        model: ModelID,
        maxOutputTokens: Int,
        cacheHints: CacheHints?
    ) -> AsyncThrowingStream<LLMEvent, Error>
}

public extension LLMProvider {
    /// Default multimodal implementation — forwards to single-modal when
    /// `images.isEmpty`. Plan 07-05 / D-18 dispatch contract.
    func stream(
        messages: [LLMMessage],
        images: [ImageBlock],
        tools: [ToolSchema],
        toolChoice: ToolChoice,
        model: ModelID,
        maxOutputTokens: Int,
        cacheHints: CacheHints?
    ) -> AsyncThrowingStream<LLMEvent, Error> {
        precondition(images.isEmpty,
            "LLMProvider conformer \(Self.self) does not implement multimodal stream; do not pass images.")
        return stream(
            messages: messages,
            tools: tools,
            toolChoice: toolChoice,
            model: model,
            maxOutputTokens: maxOutputTokens,
            cacheHints: cacheHints
        )
    }
}
