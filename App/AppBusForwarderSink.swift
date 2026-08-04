import Foundation
import AgentCore           // EscalationDecision (AgentCore type)
import AgentOrchestrator   // BusForwarder, BusForwarderSink
import Bus                 // OutboundBatcher, BusOutbound, TurnTerminator, EscalationDecision (Bus mirror)
import Config              // ProviderSelection (AgentCore-side)

/// App-side adapter that wires `BusForwarder` (pure logic, lives in
/// AgentOrchestrator for unit-testability) to `OutboundBatcher` (the
/// transport-coalescing actor in the Bus package). The sink's only job is
/// translating the protocol-agnostic `BusForwarder.Terminator` enum into
/// the wire-format `Bus.TurnTerminator` and dispatching across the batcher
/// actor boundary.
///
/// This split is the lesson from the 2026-05-03 INT-3 audit: the bus
/// forwarder lived inline in `AppDelegate.swift` previously, which made it
/// untestable because the App target's xctest harness is upstream-broken
/// on Xcode 26. Every branch now has unit coverage in
/// `BusForwarderTests.swift`; this file is the (small, hard-to-misread)
/// glue layer.
struct AppBusForwarderSink: BusForwarderSink {
    let batcher: OutboundBatcher

    func postToken(_ chunk: String) async {
        await batcher.postToken(chunk)
    }

    func sendTurnStarted(id: UUID) async {
        try? await batcher.flushAndSend(.turnStarted(id: id))
    }

    func sendTurnEnded(id: UUID, terminator: BusForwarder.Terminator) async {
        try? await batcher.flushAndSend(
            .turnEnded(id: id, terminator: Self.wireTerminator(from: terminator))
        )
    }

    func sendSubmitRejected(reason: String) async {
        try? await batcher.flushAndSend(.submitRejected(reason: reason))
    }

    /// Local-first LLM routing Task 7 — translate the AgentCore-side
    /// `EscalationDecision` (which carries `Config.ProviderSelection` +
    /// `AgentCore.OllamaFailureKind`) into the Bus wire-format
    /// `Bus.EscalationDecision` (which mirrors those enums in the
    /// dependency-free bridge layer) and flush as `BusOutbound.escalated`.
    func sendEscalated(decision: AgentCore.EscalationDecision) async {
        let wire = Bus.EscalationDecision(
            from: Self.wireProvider(from: decision.from),
            to: Self.wireProvider(from: decision.to),
            reason: Self.wireFailureKind(from: decision.reason),
            firedAt: decision.firedAt
        )
        try? await batcher.flushAndSend(.escalated(wire))
    }

    /// 1:1 mapping from `BusForwarder.Terminator` (protocol-agnostic, lives
    /// in AgentCore) to `Bus.TurnTerminator` (wire format). Both enums must
    /// stay in sync; the cases are deliberately identical so each call site
    /// either fans out trivially or fails fast at compile time when one
    /// side adds a case.
    static func wireTerminator(from t: BusForwarder.Terminator) -> TurnTerminator {
        switch t {
        case .completed: return .completed
        case .cancelled: return .cancelled
        case .errored: return .errored
        case .superseded: return .superseded
        }
    }

    /// 1:1 mapping from `Config.ProviderSelection` (Swift-side authority) to
    /// `Bus.BusProviderSelection` (wire-format mirror). Bus deliberately
    /// does NOT depend on Config — the exhaustive switch is the
    /// compile-time drift catcher when either enum adds a case.
    static func wireProvider(from p: ProviderSelection) -> BusProviderSelection {
        switch p {
        case .anthropic: return .anthropic
        case .ollama: return .ollama
        }
    }

    /// 1:1 mapping from `AgentCore.OllamaFailureKind` to
    /// `Bus.BusOllamaFailureKind`. Same dependency-isolation rationale as
    /// `wireProvider`.
    static func wireFailureKind(from k: OllamaFailureKind) -> BusOllamaFailureKind {
        switch k {
        case .streamTruncated: return .streamTruncated
        case .malformedToolCall: return .malformedToolCall
        case .unknownTool: return .unknownTool
        case .refusal: return .refusal
        case .connectionFailure: return .connectionFailure
        case .emptyResponse: return .emptyResponse
        }
    }
}
