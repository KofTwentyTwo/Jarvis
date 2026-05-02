import Foundation
import Voice
import AgentCore       // TurnID
import AgentOrchestrator  // AgentOrchestrator, SubmitOutcome, RejectReason, TurnTranscriptStore

/// Production adapter bridging `Voice.VoiceOrchestratorInterface` (the
/// voice-actor side) to `AgentOrchestrator.submit(.voice(text))` /
/// `.cancelAndSubmit(.voice(text))`. Surfaces `SubmitOutcome.rejected`
/// reasons to the HUD banner via `HUDBannerCoordinator` (D-10).
///
/// Phase 9 / Plan 4 / D-09: replaces `NullOrchestratorAdapter`.
/// D-11: `String → TurnInput` conversion lives inside this adapter.
/// BLOCKER-1: appends user-side text to `TurnTranscriptStore` on submit /
/// cancelAndSubmit so `MemoryExtractionCoordinator`'s `lookupTurnContent`
/// (Plan 1) finds non-nil pair text by the time the matching `.turnEnd`
/// reaches its drain.
actor VoiceOrchestratorAdapter: VoiceOrchestratorInterface {
    nonisolated let voiceEvents: AsyncStream<VoiceOrchestratorEvent>
    private nonisolated let eventsCont: AsyncStream<VoiceOrchestratorEvent>.Continuation

    private let orchestrator: AgentOrchestrator
    private let transcriptStore: TurnTranscriptStore?
    nonisolated(unsafe) private weak var bannerCoordinator: HUDBannerCoordinator?

    init(
        orchestrator: AgentOrchestrator,
        transcriptStore: TurnTranscriptStore?,
        bannerCoordinator: HUDBannerCoordinator?
    ) {
        let (stream, cont) = AsyncStream<VoiceOrchestratorEvent>.makeStream()
        self.voiceEvents = stream
        self.eventsCont = cont
        self.orchestrator = orchestrator
        self.transcriptStore = transcriptStore
        self.bannerCoordinator = bannerCoordinator
    }

    func submit(text: String) async {
        let outcome = await orchestrator.submit(.voice(text))
        // BLOCKER-1: user-side append AFTER outcome but BEFORE the turn
        // streams to completion. The matching `.turnEnd` reaches
        // MemoryExtractionCoordinator's drain strictly after this append, so
        // `flushPair(turnId)` will see non-nil user text.
        await appendUserTextIfRunning(outcome, text: text)
        await handleOutcome(outcome)
    }

    func cancelAndSubmit(text: String) async {
        eventsCont.yield(.cancelled)
        let outcome = await orchestrator.cancelAndSubmit(.voice(text))
        await appendUserTextIfRunning(outcome, text: text)
        await handleOutcome(outcome)
    }

    private func appendUserTextIfRunning(_ outcome: SubmitOutcome, text: String) async {
        let turnId: TurnID
        switch outcome {
        case .ran(let id):
            turnId = id
        case .superseded(_, let newId, _):
            turnId = newId
        case .rejected:
            return  // No turn → no transcript entry. flushPair will not be called.
        }
        await transcriptStore?.append(turnId: turnId, role: .user, deltaText: text)
    }

    /// Called by AppDelegate's broadcaster voice subscriber on `.turnEnd`
    /// after gating on `orchestrator.turnSourceWasVoice(turnId)` (BLOCKER-2).
    /// Translates the orchestrator-side terminal event into the
    /// VoiceController-side `.turnEnded(finalText:)` event.
    nonisolated func emitTurnEnded(finalText: String) {
        eventsCont.yield(.turnEnded(finalText: finalText))
    }

    /// Called by AppDelegate's broadcaster voice subscriber on `.error` for
    /// a voice-originated turn (BLOCKER-2 gate). Returns VoiceController to
    /// `.idle` from `.listening` per the Phase 6 state machine.
    nonisolated func emitError() {
        eventsCont.yield(.error)
    }

    private func handleOutcome(_ outcome: SubmitOutcome) async {
        switch outcome {
        case .ran, .superseded:
            return  // success — turnEnded fires via the broadcaster's voice subscriber
        case .rejected(let reason):
            let coord = bannerCoordinator
            let (id, body) = bannerForReason(reason)
            Task { @MainActor in
                coord?.enqueue(BannerContent(
                    id: id,
                    // priority 5: above voice-aec-banner (10) and below
                    // wizard / hard-block banners (1-3). User-visible above
                    // other voice surface but never preempts onboarding.
                    priority: 5,
                    title: "Voice Submission Rejected",
                    body: body,
                    action: nil
                ))
            }
            // D-10 cardinal: also surface on the events stream so
            // VoiceController returns to .idle from .listening — without
            // this, a rejection would silently leave VoiceController in a
            // listening state with no synthesis to play.
            eventsCont.yield(.error)
        }
    }

    private func bannerForReason(_ reason: RejectReason) -> (id: String, body: String) {
        Self.bannerForReason(reason)
    }

    /// Pure mapping from `RejectReason` to (banner id, banner body). Static
    /// so tests can exercise the mapping without a live orchestrator.
    static func bannerForReason(_ reason: RejectReason) -> (id: String, body: String) {
        switch reason {
        case .turnInFlight:
            return ("voice-rejected-turninflight", RejectReasonCopy.body(for: .turnInFlight))
        case .providerUnavailable:
            return ("voice-rejected-provider", RejectReasonCopy.body(for: .providerUnavailable))
        case .configError:
            return ("voice-rejected-config", RejectReasonCopy.body(for: .configError))
        }
    }
}
