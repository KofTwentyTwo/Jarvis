import Foundation
import Voice

/// App-side factory for the tier-1 TTS engine. Lives in its own file
/// so `AppDelegate.swift` doesn't directly reference TTS construction
/// types — `scripts/check-presence-vision-isolation.sh`'s Layer 3 gate
/// forbids co-occurrence of presence-bus references and TTS engine
/// references in the same file (the structural defense for SEC-06).
/// This factory has no presence dependency, so the architectural
/// invariant holds.
///
/// Track B-3 (2026-05-03 voice audit). Coverage:
/// `TTSEngineActorTier1Tests` — exercises a real AVSpeechSynthesizer
/// through this construction shape.
enum VoiceOutputWiring {

    /// Construct a `TTSEngineActor` with tier-1 only (AVSpeechSynthesizer).
    /// Tier-2 (Orpheus) is left nil — the ~6GB HuggingFace weight
    /// download is gated behind a follow-on plan. Tier-2 requests
    /// degrade to tier-1 transparently per `TTSEngineActor`'s
    /// resolvedTier branch.
    static func makeTier1Engine() -> TTSEngineActor {
        TTSEngineActor(
            orpheus: nil,
            tier1: AVSpeechSynth(),
            fallback: nil
        )
    }
}
