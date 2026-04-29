import Foundation
import AgentCore

/// Plan 07-05 / D-16 — three-tier vision routing.
///
/// **CARDINAL INVARIANT:** the only place in `packages/Vision/Sources/Vision`
/// where the literal `"claude-opus-4-7"` model name appears in source. Every
/// other reference to T3 routes through `VisionTier.t3Cloud.defaultModelID`.
/// `VisionRouterCloudOptInGrepTests` enforces this structurally.
public enum VisionTier: Sendable, Equatable {
    /// Default fast tier — Gemma 4 31B Dense via Ollama. Privacy-pure local.
    case t1Local
    /// Quality escalation tier — Qwen 3.5 35B-A3B-VL via vllm-mlx sidecar.
    /// Privacy-pure local. Reached only via the D-17 escalation heuristic.
    case t2LocalQuality
    /// Cloud escape tier — Opus 4.7 via AnthropicProvider. Reached ONLY when
    /// the user types an explicit opt-in phrase (D-18). NEVER automatic.
    case t3Cloud

    /// Tier-to-model mapping. The literal model strings live ONLY here.
    public var defaultModelID: ModelID {
        switch self {
        case .t1Local: return ModelID(rawValue: "gemma4:31b")
        case .t2LocalQuality: return ModelID(rawValue: "Qwen/Qwen3.5-35B-A3B-VL")
        case .t3Cloud: return ModelID(rawValue: "claude-opus-4-7")
        }
    }
}
