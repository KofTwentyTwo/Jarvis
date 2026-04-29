import Foundation
import AgentCore
import OllamaProvider

/// Plan 07-05 / Task 4 — T2 LLM provider that talks to a vllm-mlx sidecar
/// over its OpenAI-compatible HTTP surface.
///
/// `vllm-mlx` exposes `/v1/chat/completions` (OpenAI-compat) and accepts the
/// same data-URL `image_url` shape that `OllamaProvider.encodeOpenAICompat
/// Multimodal` produces. So `VllmMlxProvider` is a thin actor wrapping an
/// `OllamaProvider(baseURL: vllmMlxURL, useOpenAICompat: true)`.
///
/// Why wrap (instead of just using OllamaProvider directly): VISION-03
/// architectural-guard cleanliness — the Vision package owns its own
/// provider symbol, so a future tracing/decorator layer can be added in
/// `packages/Vision` without reaching back into `packages/AgentCore`.
public actor VllmMlxProvider: LLMProvider {
    private let inner: OllamaProvider

    public init(baseURL: URL, session: URLSession = .shared) {
        self.inner = OllamaProvider(
            baseURL: baseURL,
            session: session,
            useOpenAICompat: true
        )
    }

    public nonisolated func stream(
        messages: [LLMMessage],
        tools: [ToolSchema],
        toolChoice: ToolChoice,
        model: ModelID,
        maxOutputTokens: Int,
        cacheHints: CacheHints?
    ) -> AsyncThrowingStream<LLMEvent, Error> {
        inner.stream(
            messages: messages,
            tools: tools,
            toolChoice: toolChoice,
            model: model,
            maxOutputTokens: maxOutputTokens,
            cacheHints: cacheHints
        )
    }

    public nonisolated func stream(
        messages: [LLMMessage],
        images: [ImageBlock],
        tools: [ToolSchema],
        toolChoice: ToolChoice,
        model: ModelID,
        maxOutputTokens: Int,
        cacheHints: CacheHints?
    ) -> AsyncThrowingStream<LLMEvent, Error> {
        inner.stream(
            messages: messages,
            images: images,
            tools: tools,
            toolChoice: toolChoice,
            model: model,
            maxOutputTokens: maxOutputTokens,
            cacheHints: cacheHints
        )
    }
}
