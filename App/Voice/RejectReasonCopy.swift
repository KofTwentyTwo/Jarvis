import Foundation
import AgentOrchestrator   // RejectReason

/// Single source of truth for D-10 user-facing copy. `VoiceOrchestratorAdapter`
/// (HUD banner — voice path) and `AppDelegate.handleTextOutcome` (Bus toast —
/// text path) both read from here so the two paths stay byte-identical.
///
/// Phase 9 / Plan 4. D-10 cardinal: never silently drop a user submission —
/// every `SubmitOutcome.rejected` reason MUST surface to the user with the
/// same wording regardless of whether the submission came from voice or text.
enum RejectReasonCopy {
    static func body(for reason: RejectReason) -> String {
        switch reason {
        case .turnInFlight:
            return "Already thinking — wait or say cancel."
        case .providerUnavailable:
            return "Provider unavailable — check Anthropic key or Ollama daemon."
        case .configError:
            return "Config error — see ~/Library/Logs/Jarvis/system.log."
        }
    }
}
