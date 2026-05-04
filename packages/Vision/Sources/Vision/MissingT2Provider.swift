import Foundation
import AgentCore

/// Track-C 4 — explicit-missing T2 provider.
///
/// Closes vision-audit §3 "T2 is decorative". Before this commit, AppDelegate
/// constructed `VisionRouter(t1Provider: t1, t2Provider: t1, t3Provider: t3)`
/// — `evaluatePostResponse → .escalateToT2 → providerForTier(.t2LocalQuality)`
/// silently re-ran the same low-confidence response on the same T1 model, with
/// no signal to the operator that T2 was never built.
///
/// This conformer is the explicit replacement: T2 escalation now resolves to
/// a provider whose `stream(...)` throws `VisionError.t2ProviderUnavailable`.
/// In practice the orchestrator never reaches this path because callers are
/// expected to gate T2 escalation on `evaluatePostResponse(...,
/// t2Available: false)`, which already returns `.useT1Result` and the T1
/// response is reused without invoking the T2 provider.
///
/// Real T2 wiring (`VllmMlxSidecar` + `VllmMlxProvider` instantiation +
/// codesigning + feature-flag gating) is downstream work. Until then, this
/// type makes the bug fixed by Track-C 4 — silent T1-as-T2 fallback —
/// impossible to regress: a future re-introduction would compile but
/// surface as an explicit, debuggable error at run time.
public struct MissingT2Provider: LLMProvider {
    public init() {}

    public func stream(
        messages: [LLMMessage],
        tools: [ToolSchema],
        toolChoice: ToolChoice,
        model: ModelID,
        maxOutputTokens: Int,
        cacheHints: CacheHints?
    ) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream<LLMEvent, Error> { continuation in
            continuation.finish(throwing: VisionError.t2ProviderUnavailable)
        }
    }

    public func stream(
        messages: [LLMMessage],
        images: [ImageBlock],
        tools: [ToolSchema],
        toolChoice: ToolChoice,
        model: ModelID,
        maxOutputTokens: Int,
        cacheHints: CacheHints?
    ) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream<LLMEvent, Error> { continuation in
            continuation.finish(throwing: VisionError.t2ProviderUnavailable)
        }
    }
}
