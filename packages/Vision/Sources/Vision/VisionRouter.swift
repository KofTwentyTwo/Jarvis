import Foundation
import AgentCore

/// Plan 07-05 / D-16 + D-17 + D-18 — vision-tier routing brain.
///
/// **Cardinal invariants:**
///   1. `route(...)` selects T1 by default and T3 ONLY when `explicitCloudOptIn`
///      is true. T2 is never selected by `route(...)` — it is reachable only
///      via `evaluatePostResponse(...)` after a T1 response has been classified
///      as low-confidence.
///   2. `evaluatePostResponse(...)` returns `.useT1Result`, `.escalateToT2`,
///      or `.escalateToT3` — but the `.escalateToT3` case is NEVER returned.
///      The enum carries it for symmetry but the function body documents the
///      no-auto-cloud invariant via a structural test (
///      `VisionRouterEscalationTests.testEvaluatePostResponseStaysOnT1
///      WhenT2Unavailable`).
///
/// Comment about T3: see `EscalationPhraseDetector.matchesCloudOptIn` — that
/// function is the only signal that flips the router to T3.
public actor VisionRouter {

    public struct RouteDecision: Sendable, Equatable {
        public let tier: VisionTier
        public let modelID: ModelID
    }

    public enum EscalationOutcome: Sendable, Equatable {
        case useT1Result
        case escalateToT2
    }

    private let t1Provider: any LLMProvider
    private let t2Provider: any LLMProvider
    private let t3Provider: any LLMProvider

    public init(
        t1Provider: any LLMProvider,
        t2Provider: any LLMProvider,
        t3Provider: any LLMProvider
    ) {
        self.t1Provider = t1Provider
        self.t2Provider = t2Provider
        self.t3Provider = t3Provider
    }

    /// D-16 deterministic precedence:
    ///   - explicitCloudOptIn → T3 (matchesCloudOptIn was the upstream signal)
    ///   - else → T1
    /// T2 is reached ONLY through `evaluatePostResponse(...)`.
    public func route(
        for image: ImageBlock,
        prompt: String,
        explicitCloudOptIn: Bool
    ) -> RouteDecision {
        if explicitCloudOptIn {
            return RouteDecision(tier: .t3Cloud, modelID: VisionTier.t3Cloud.defaultModelID)
        }
        return RouteDecision(tier: .t1Local, modelID: VisionTier.t1Local.defaultModelID)
    }

    /// D-17 + D-18: evaluate the T1 response and decide whether to keep it
    /// or silently re-run on T2. Auto-cloud (T3) is FORBIDDEN here.
    public func evaluatePostResponse(
        _ t1Response: String,
        config: VisionRouterConfig,
        t2Available: Bool
    ) -> EscalationOutcome {
        let isLowConfidence = VisionEscalationHeuristic.evaluateLowConfidence(t1Response, config: config)
        guard isLowConfidence else { return .useT1Result }
        // Low confidence + T2 available → escalate.
        if t2Available { return .escalateToT2 }
        // Low confidence + T2 unavailable → STAY ON T1.
        // NEVER auto-escalate to cloud (D-18). The user must explicitly
        // opt in via `matchesCloudOptIn` for T3.
        return .useT1Result
    }

    /// Provider accessors — kept internal so the router is the dispatch
    /// surface, not a passthrough.
    public func providerForTier(_ tier: VisionTier) -> any LLMProvider {
        switch tier {
        case .t1Local: return t1Provider
        case .t2LocalQuality: return t2Provider
        case .t3Cloud: return t3Provider
        }
    }
}
