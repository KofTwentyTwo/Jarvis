import Foundation
import Voice
import Bus

// MARK: - Placeholder voice adapters (Plan 06-05; replaced by orchestrator wiring)
//
// Extracted out of AppDelegate.swift in Plan 07-06 so the
// scripts/check-presence-vision-isolation.sh Layer 3 gate does not
// false-positive on legacy method-DEFINITION sites. The TTS-related and
// orchestrator-related tokens these adapters carry are the legitimate
// VoiceController integration surface; they have nothing to do with the
// camera-presence subscriber, but the gate cannot tell the difference at
// textual level.
//
// Phase 7 future wiring replaces these with real adapters that translate
// VoiceController callbacks into AgentOrchestrator submit / cancel calls
// and TTSEngineActor synthesize / cancel calls. Until then they no-op.

/// Placeholder orchestrator adapter. Phase 7 wires the real `AgentOrchestrator`.
actor NullOrchestratorAdapter: VoiceOrchestratorInterface {
    nonisolated let voiceEvents: AsyncStream<VoiceOrchestratorEvent>
    private nonisolated let eventsCont: AsyncStream<VoiceOrchestratorEvent>.Continuation

    init() {
        let (stream, cont) = AsyncStream<VoiceOrchestratorEvent>.makeStream()
        voiceEvents = stream
        eventsCont = cont
    }

    func submit(text: String) async {
        // Phase 7: forward to AgentOrchestrator.submit(TurnInput.voice(text))
    }

    func cancelAndSubmit(text: String) async {
        eventsCont.yield(.cancelled)
        // Phase 7: forward to AgentOrchestrator.cancelAndSubmit(TurnInput.voice(text))
    }
}

/// Placeholder TTS adapter. Phase 7 wires the real `TTSEngineActor`.
actor NullTTSAdapter: VoiceTTSInterface {
    var hasSynthInFlight: Bool { false }

    func synthesize(_ text: String) async {
        // Phase 7: forward to TTSEngineActor.synthesize(_:tier:voice:)
    }

    func cancelTTS() async {
        // Phase 7: forward to TTSEngineActor.cancel()
    }
}
