import Foundation
import AgentCore

/// Events emitted on `AgentOrchestrator.events` for downstream consumers
/// (Plan 04-05 DevOverlay + Plan 02 bus → webview HUD).
///
/// **SEC-06 invariant:** no case carries the per-turn nonce. Verified by a
/// grep gate in CI: `grep -v '^//' OrchestratorEvent.swift | grep -c 'nonce'`
/// must equal 0. The nonce lives on the actor and in the replay log only.
///
/// `tokenDelta` is lossy under firehose load (the bus channel uses
/// `dropOldest`); `toolCardUpdate` and `turnEnd` are not lossy.
public enum OrchestratorEvent: Sendable {
    case stateChange(TurnState)
    case tokenDelta(turnId: TurnID, text: String)
    case thinkingDelta(turnId: TurnID, text: String)
    case toolCardUpdate(ToolCardUpdate)
    /// Per-turn token/cache accounting. Added in Plan 04-05 so the DevOverlay
    /// (OBS-01) can display running token counts + cache hit ratio without
    /// reading the replay log. Carries `TurnUsage` verbatim from the provider.
    case usage(turnId: TurnID, usage: TurnUsage)
    case turnEnd(turnId: TurnID, stopReason: StopReason)
    case error(turnId: TurnID, error: LLMProviderError)

    /// Local-first LLM routing (Task 6 / spec §2): one-shot reactive
    /// escalation from Ollama → Anthropic fired by the orchestrator when
    /// the local provider emits a `providerError` carrying an
    /// `OllamaFailureKind`. Emitted at most once per logical turn (budget
    /// resets across turns — see `escalatedThisTurn` in `runTurnLoop`).
    /// Task 7 wires this to the HUD badge via `BusOutbound.escalated`.
    case escalated(EscalationDecision)
}

public struct ToolCardUpdate: Sendable {
    public enum Phase: Sendable {
        case pending
        case running
        case awaitingApproval
        case completed
        case failed
    }

    public let turnId: TurnID
    public let toolUseId: String
    public let toolName: String
    public let phase: Phase
    /// Capped at ~200 characters for HUD display. Full bytes go to ReplayLog
    /// via `ReplayEvent.toolResultFull` — never to OrchestratorEvent.
    public let resultPreview: String?
    public let error: String?

    public init(
        turnId: TurnID,
        toolUseId: String,
        toolName: String,
        phase: Phase,
        resultPreview: String?,
        error: String?
    ) {
        self.turnId = turnId
        self.toolUseId = toolUseId
        self.toolName = toolName
        self.phase = phase
        self.resultPreview = resultPreview
        self.error = error
    }
}
